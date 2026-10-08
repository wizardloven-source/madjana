#!/usr/bin/env python3
"""deploy_sec002_fix.py — deploy + verify the SEC-002 financial-RLS fix.

Applies `20261002000000_restore_financial_rls.sql` (M8) to a PostgreSQL /
Supabase database and verifies the hole is closed. Read docs/DEPLOYMENT.md
§2 before running anything against production.

Modes
-----
  (default / --precheck-only)  Read-only. Reports WEAK (hole live) vs
                               MANAGER-SCOPED (already fixed) for the six
                               financial tables, plus anon/public grants.
  --apply                       backup -> confirm -> apply the forward
                               migration -> verify. Refuses to re-apply if
                               the database is already MANAGER-SCOPED.
  --verify                      Read-only. Exits non-zero while any of the
                               six tables has a policy that is not
                               manager-gated, or is granted to anon/public,
                               or has an empty predicate.
  --revert                      backup -> confirm -> apply the rollback
                               `20261002000001_rollback_financial_rls.sql`.
                               WARNS: this reopens SEC-002. The verify mode
                               is inverted so it can confirm the revert.

Connection: --connection URL or env SUPABASE_DB_URL / DATABASE_URL.
Safe defaults: every mutating path takes a schema-only pg_dump before
touching anything, and confirmation is required unless --yes is passed.

This tool is the prep for the production deploy. It is deliberately NOT run
inside the repo's CI (no production credentials there).
"""

import argparse
import datetime
import os
import subprocess
import sys

try:
    import psycopg2
except ImportError:  # pragma: no cover - instructions path
    sys.exit(
        "psycopg2 is required. Install it first:\n"
        "    pip install -r supabase\\tests\\requirements.txt"
    )

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIGDIR = os.path.join(ROOT, "supabase", "migrations")
FORWARD = os.path.join(MIGDIR, "20261002000000_restore_financial_rls.sql")
ROLLBACK = os.path.join(MIGDIR, "20261002000001_rollback_financial_rls.sql")

FINANCIAL_TABLES = [
    "payments", "expenses", "revenue",
    "opening_balances", "inventory_items", "stock_adjustments",
]


class DeployError(RuntimeError):
    pass


# ─────────────────────────────────────────────────────────────────────────────
# connection helpers
# ─────────────────────────────────────────────────────────────────────────────
def resolve_connection(arg):
    conn = arg or os.environ.get("SUPABASE_DB_URL") or os.environ.get("DATABASE_URL")
    if not conn:
        raise DeployError(
            "no connection given. Pass --connection, or set SUPABASE_DB_URL / "
            "DATABASE_URL."
        )
    return conn


def connect(conn_str):
    return psycopg2.connect(conn_str, connect_timeout=15)


# ─────────────────────────────────────────────────────────────────────────────
# inspections (read-only)
# ─────────────────────────────────────────────────────────────────────────────
def fetch_policies(cur):
    """Return {table: [dict(policy, cmd, roles, qual, with_check, pred)]}."""
    out = {}
    for tbl in FINANCIAL_TABLES:
        cur.execute("SELECT to_regclass('public.' || %s)", (tbl,))
        if cur.fetchone() is None:
            out[tbl] = None
            continue
        cur.execute(
            "SELECT policyname, cmd, roles::text, "
            "       coalesce(qual, ''), coalesce(with_check, '') "
            "  FROM pg_policies "
            " WHERE schemaname = 'public' AND tablename = %s "
            " ORDER BY cmd, policyname",
            (tbl,),
        )
        rows = cur.fetchall()
        out[tbl] = [
            {
                "policy": r[0], "cmd": r[1], "roles": r[2],
                "qual": r[3], "with_check": r[4],
                "pred": r[4] if r[1].upper() == "INSERT" else (r[3] + " " + r[4]),
            }
            for r in rows
        ]
    return out


def classify(table, policies):
    """Return 'missing' | 'MANAGER-SCOPED' | 'WEAK' | 'UNEXPECTED'."""
    if policies is None:
        return "missing"
    if not policies:
        return "UNEXPECTED (no policies)"
    manager = lambda pred: pred and ("user_manages_farm" in pred or "system_admin" in pred)
    weak = lambda pred: pred and "user_has_farm_access" in pred
    bad_roles = [p for p in policies if "anon" in p["roles"] or "public" in p["roles"]]
    if bad_roles:
        return "UNEXPECTED (anon/public grant)"
    for p in policies:
        if not p["pred"].strip():
            return "UNEXPECTED (empty predicate)"
        if not manager(p["pred"]):
            return "WEAK" if weak(p["pred"]) else "UNEXPECTED (unknown predicate)"
    return "MANAGER-SCOPED"


def force_rls_report(cur):
    rows = []
    for tbl in FINANCIAL_TABLES:
        cur.execute(
            "SELECT relrowsecurity, relforcerowsecurity FROM pg_class "
            "WHERE oid = to_regclass('public.' || %s)",
            (tbl,),
        )
        r = cur.fetchone()
        if r:
            rows.append(f"{tbl}: RLS={'on' if r[0] else 'OFF'} FORCE={'on' if r[1] else 'off'}")
    return rows


def precheck(conn_str):
    with connect(conn_str) as c:
        cur = c.cursor()
        policies = fetch_policies(cur)
        print("state per financial table:")
        states = {}
        for tbl in FINANCIAL_TABLES:
            st = classify(tbl, policies[tbl])
            states[tbl] = st
            print(f"  {tbl:22} {st}")
        for line in force_rls_report(cur):
            print(f"  ({line})")
        print()
        if any(st == "missing" for st in states.values()):
            raise DeployError(
                "one or more financial tables are missing - is this the right "
                "database? init.sql / 20260926000800 must be applied first."
            )
        bad = [t for t, st in states.items()
               if st.startswith("UNEXPECTED")]
        weak = [t for t, st in states.items() if st == "WEAK"]
        if bad:
            raise DeployError(
                f"unexpected policy state on: {', '.join(bad)}. Refusing to "
                "guess; inspect pg_policies by hand first."
            )
        if not weak:
            print("RESULT: all six tables MANAGER-SCOPED - the SEC-002 fix is "
                  "already applied. Nothing to do.")
            return False
        print(f"RESULT: SEC-002 HOLE LIVE on {len(weak)} table(s): "
              f"{', '.join(weak)}. Apply the fix.")
        return True


def verify(conn_str):
    """Hard check identical in spirit to the migration's own verification block."""
    problems = []
    with connect(conn_str) as c:
        cur = c.cursor()
        policies = fetch_policies(cur)
        for tbl in FINANCIAL_TABLES:
            if policies[tbl] is None:
                problems.append(f"{tbl}: table missing")
                continue
            if not policies[tbl]:
                problems.append(f"{tbl}: no policies at all")
                continue
            for p in policies[tbl]:
                pred = p["pred"]
                if not pred.strip():
                    problems.append(f"{tbl}.{p['policy']} ({p['cmd']}): no predicate")
                    continue
                if "user_manages_farm" not in pred and "system_admin" not in pred:
                    problems.append(
                        f"{tbl}.{p['policy']} ({p['cmd']}): not manager-gated: "
                        f"{pred.strip()[:120]}"
                    )
                if "anon" in p["roles"] or "public" in p["roles"]:
                    problems.append(
                        f"{tbl}.{p['policy']}: granted to {p['roles']} "
                        "(must be authenticated only)"
                    )
    if problems:
        print("VERIFY: FAILED")
        for line in problems:
            print(f"  - {line}")
        return False
    print("VERIFY: PASSED - all six financial tables are manager-scoped, "
          "authenticated only.")
    return True


def verify_reverted(conn_str):
    """Confirm the rollback produced the pre-M8 (00800) shape."""
    problems = []
    with connect(conn_str) as c:
        cur = c.cursor()
        policies = fetch_policies(cur)
        for tbl in FINANCIAL_TABLES:
            ps = policies[tbl]
            if ps is None:
                problems.append(f"{tbl}: table missing")
                continue
            if len(ps) != 4:
                problems.append(f"{tbl}: expected 4 policies, found {len(ps)}")
                continue
            for p in ps:
                pred = p["pred"]
                if p["cmd"].upper() == "DELETE":
                    if "user_manages_farm" not in pred:
                        problems.append(
                            f"{tbl}.{p['policy']} (DELETE): expected user_manages_farm"
                        )
                elif "user_has_farm_access" not in pred:
                    problems.append(
                        f"{tbl}.{p['policy']} ({p['cmd']}): expected "
                        "user_has_farm_access"
                    )
                if "anon" in p["roles"] or "public" in p["roles"]:
                    problems.append(f"{tbl}.{p['policy']}: granted to {p['roles']}")
    if problems:
        print("REVERT-VERIFY: FAILED")
        for line in problems:
            print(f"  - {line}")
        return False
    print("REVERT-VERIFY: PASSED - pre-M8 (00800) shape restored.")
    return True


# ─────────────────────────────────────────────────────────────────────────────
# mutating operations
# ─────────────────────────────────────────────────────────────────────────────
def run_sql_file(conn_str, path):
    print(f"running: {os.path.basename(path)}")
    res = subprocess.run(
        ["psql", "-d", conn_str, "-v", "ON_ERROR_STOP=1", "-q", "-f", path],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise DeployError(
            f"psql failed applying {os.path.basename(path)}:\n"
            f"{res.stderr.strip()[-4000:]}"
        )
    print(f"applied: {os.path.basename(path)}")


def backup(conn_str, backup_dir):
    os.makedirs(backup_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    path = os.path.join(backup_dir, f"backup_sec002_{stamp}.sql")
    print(f"backup: pg_dump --schema-only -> {path}")
    res = subprocess.run(
        ["pg_dump", "--schema-only", "-d", conn_str, "-f", path],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise DeployError(f"pg_dump failed:\n{res.stderr.strip()[-2000:]}")
    return path


def confirm(message):
    if "--yes" in sys.argv:
        return True
    try:
        return input(f"{message} [y/N] ").strip().lower() in {"y", "yes"}
    except (EOFError, KeyboardInterrupt):
        return False


def find_migration(path_arg, default, name):
    path = path_arg or default
    if not os.path.isfile(path):
        raise DeployError(f"{name} file not found: {path}")
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--connection", help="postgres URL (or set SUPABASE_DB_URL)")
    ap.add_argument("--precheck-only", action="store_true",
                    help="read-only state report and exit")
    ap.add_argument("--apply", action="store_true",
                    help="backup -> confirm -> apply forward migration -> verify")
    ap.add_argument("--revert", action="store_true",
                    help="backup -> confirm -> apply rollback -> verify-reverted")
    ap.add_argument("--verify", action="store_true",
                    help="read-only hard check of the fixed state")
    ap.add_argument("--migration", default=None, help="forward migration file")
    ap.add_argument("--rollback", default=None, help="rollback migration file")
    ap.add_argument("--backup-dir", default=os.path.join(ROOT, "backups"))
    ap.add_argument("--no-backup", action="store_true", help="skip the pg_dump")
    ap.add_argument("--yes", action="store_true", help="skip all prompts")
    ap.add_argument("--force", action="store_true",
                    help="apply even if precheck says the fix is already live")
    args = ap.parse_args()

    conn_str = resolve_connection(args.connection)

    if args.verify:
        sys.exit(0 if verify(conn_str) else 1)

    weak = precheck(conn_str)  # always report the state first

    if args.precheck_only or not (args.apply or args.revert):
        return

    migration = find_migration(args.migration, FORWARD, "forward migration")
    rollback = find_migration(args.rollback, ROLLBACK, "rollback migration")

    if args.revert:
        print("\nWARNING - this applies the rollback and REOPENS SEC-002: "
              "a worker will again read/write money. This is the emergency "
              "revert, not routine.")
        if not confirm("Continue with the rollback?"):
            print("aborted by user")
            sys.exit(2)
        if not args.no_backup:
            backup(conn_str, args.backup_dir)
        run_sql_file(conn_str, rollback)
        sys.exit(0 if verify_reverted(conn_str) else 1)

    # apply
    if not weak and not args.force:
        print("\nalready manager-scoped - refusing to re-apply. Use --force to "
              "override.")
        sys.exit(0)
    if not confirm("Apply the financial-RLS fix now?"):
        print("aborted by user")
        sys.exit(2)
    if not args.no_backup:
        backup(conn_str, args.backup_dir)
    run_sql_file(conn_str, migration)
    sys.exit(0 if verify(conn_str) else 1)


if __name__ == "__main__":
    try:
        main()
    except DeployError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
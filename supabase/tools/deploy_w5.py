#!/usr/bin/env python3
"""deploy_w5.py - deploy + verify the W5 migrations (M13-M20).

Applies the eight forward migrations of the W5 milestone in the operator's
declared order and then verifies the resulting schema shape against the DB.
Read docs/DEPLOYMENT.md (W5 section) before running anything against
production, especially the M20 note about pg_cron / Edge scheduling.

Modes
-----
  (default / --precheck-only)  Read-only. Reports base prerequisites, then
                               per-migration state (applied / pending).
  --apply                      backup -> confirm -> apply every PENDING
                               migration in order -> verify. Refuses to
                               re-apply if everything is already in place
                               (use --force to run the loop anyway; every
                               migration is re-run safe).
  --verify                     Read-only hard check: every W5 object present.
  --list-migrations            Print the apply order and exit. No connection.

Connection: --connection URL or env SUPABASE_DB_URL / DATABASE_URL.

The W5 apply order (docs/DEPLOYMENT.md W5, EXACT):

     1. 20261003001200_record_lock.sql              (M13)
     2. 20261003001300_worker_requests.sql          (M14)
     3. 20261003001400_invoice_audit.sql            (M15)
     4. 20261003001500_role_permissions.sql         (M16)
     5. 20261003001600_opening_feed_received.sql    (M17)
     6. 20261003001700_farm_id_audit.sql            (M18)
     7. 20261003001800_duplicate_guard.sql          (M19)
     8. 20261003001900_due_payments.sql             (M20)

Rollbacks exist for every milestone (…01_rollback_*.sql) and are NEVER part
of this apply order -- use them by hand, on purpose.

This tool is prep for the production deploy. It is deliberately NOT run
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

# The operator's apply order. Change only with the plan; it is the contract.
ORDERED_W5 = [
    ("M13", "20261003001200_record_lock.sql"),
    ("M14", "20261003001300_worker_requests.sql"),
    ("M15", "20261003001400_invoice_audit.sql"),
    ("M16", "20261003001500_role_permissions.sql"),
    ("M17", "20261003001600_opening_feed_received.sql"),
    ("M18", "20261003001700_farm_id_audit.sql"),
    ("M19", "20261003001800_duplicate_guard.sql"),
    ("M20", "20261003001900_due_payments.sql"),
]

LOCK_GUARD_TABLES = [
    "payments", "expenses", "revenue", "egg_production", "mortality",
    "feed_consumption",
]

DUP_GUARD_TABLES = [
    "expenses", "egg_production", "mortality", "feed_consumption",
    "feed_received", "payments",
]

FARM_AUDIT_TABLES = [
    "payments", "expenses", "revenue", "egg_production", "mortality",
    "feed_consumption", "feed_received", "medications", "egg_dispatch",
    "stock_adjustments", "opening_balances", "flock_movements", "customers",
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
# object probes (read-only)
# ─────────────────────────────────────────────────────────────────────────────
def table_exists(cur, table):
    cur.execute("SELECT to_regclass('public.' || %s)", (table,))
    return cur.fetchone() is not None


def col_exists(cur, table, column):
    cur.execute(
        "SELECT 1 FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'public' AND c.relname = %s "
        "  AND a.attname = %s AND NOT a.attisdropped",
        (table, column),
    )
    return cur.fetchone() is not None


def col_type(cur, table, column):
    cur.execute(
        "SELECT a.atttypid::regtype::text FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'public' AND c.relname = %s "
        "  AND a.attname = %s AND NOT a.attisdropped",
        (table, column),
    )
    row = cur.fetchone()
    return row[0] if row else None


def fn_exists(cur, name, nargs=None, argtypes=None):
    cur.execute(
        "SELECT p.pronargs, "
        "       (SELECT array_agg(format_type(t, NULL) ORDER BY o) "
        "          FROM unnest(p.proargtypes) WITH ORDINALITY AS u(t, o)) "
        "  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        " WHERE n.nspname = 'public' AND p.proname = %s",
        (name,),
    )
    row = cur.fetchone()
    if row is None:
        return False
    if nargs is not None and row[0] != nargs:
        return False
    if argtypes is not None and list(row[1] or []) != argtypes:
        return False
    return True


def fn_is_definer(cur, name):
    cur.execute(
        "SELECT p.prosecdef FROM pg_proc p "
        "JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname = 'public' AND p.proname = %s",
        (name,),
    )
    row = cur.fetchone()
    return bool(row[0]) if row else False


def trg_exists(cur, table, trigger):
    cur.execute(
        "SELECT 1 FROM pg_trigger t "
        "JOIN pg_class c ON c.oid = t.tgrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'public' AND c.relname = %s "
        "  AND t.tgname = %s AND NOT t.tgisinternal",
        (table, trigger),
    )
    return cur.fetchone() is not None


def pol_exists(cur, table, policy):
    cur.execute(
        "SELECT 1 FROM pg_policies "
        "WHERE schemaname = 'public' AND tablename = %s AND policyname = %s",
        (table, policy),
    )
    return cur.fetchone() is not None


def idx_exists(cur, table, index):
    cur.execute(
        "SELECT 1 FROM pg_indexes "
        "WHERE schemaname = 'public' AND tablename = %s AND indexname = %s",
        (table, index),
    )
    return cur.fetchone() is not None


def rls_on(cur, table):
    cur.execute(
        "SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.' || %s)",
        (table,),
    )
    row = cur.fetchone()
    return bool(row[0]) if row else False


def anon_revoked(cur, name, arglist):
    cur.execute(
        "SELECT has_function_privilege('anon', 'public.%s(%s)', 'EXECUTE')"
        % (name, arglist)
    )
    return cur.fetchone()[0] is False


def registry_order(cur, table):
    cur.execute(
        "SELECT sort_order FROM public.sync_table_registry WHERE table_name = %s",
        (table,),
    )
    row = cur.fetchone()
    return row[0] if row else None


# ─────────────────────────────────────────────────────────────────────────────
# curated shape checks per migration
# ─────────────────────────────────────────────────────────────────────────────
def migration_checks():
    """Return {M-label: (description, [(check-label, callable(cur))])}."""
    return {
        "M13": ("record_lock set: hard locks + unlock requests + guards", [
            ("record_lock table", lambda c: table_exists(c, "record_lock")),
            ("record_unlock_requests table", lambda c: table_exists(c, "record_unlock_requests")),
            ("record_lock RLS on", lambda c: rls_on(c, "record_lock")),
            ("record_unlock_requests RLS on", lambda c: rls_on(c, "record_unlock_requests")),
            ("assert_record_not_locked(), DEFINER",
             lambda c: fn_is_definer(c, "assert_record_not_locked")),
            ("6 lock guard triggers",
             lambda c: all(trg_exists(c, t, f"{t}_lock_guard") for t in LOCK_GUARD_TABLES)),
            ("manager_all policy",
             lambda c: pol_exists(c, "record_lock", "record_lock_manager_all")),
            ("unlock select/insert/manage/delete policies",
             lambda c: all(pol_exists(c, "record_unlock_requests", p) for p in (
                 "record_unlock_select", "record_unlock_insert",
                 "record_unlock_manage", "record_unlock_delete"))),
            ("not in sync registry",
             lambda c: registry_order(c, "record_lock") is None
                       and registry_order(c, "record_unlock_requests") is None),
        ]),
        "M14": ("change_requests: synced worker request storage", [
            ("change_requests table", lambda c: table_exists(c, "change_requests")),
            ("change_requests RLS on", lambda c: rls_on(c, "change_requests")),
            ("4 sync/updated_at triggers",
             lambda c: all(trg_exists(c, "change_requests", t) for t in (
                 "change_requests_sync_insert", "change_requests_sync_update",
                 "change_requests_tombstone", "change_requests_updated_at"))),
            ("select/insert/update/delete policies",
             lambda c: all(pol_exists(c, "change_requests", p) for p in (
                 "change_requests_select", "change_requests_insert",
                 "change_requests_update", "change_requests_delete"))),
            ("registry row after flocks",
             lambda c: registry_order(c, "change_requests") is not None
                       and registry_order(c, "change_requests")
                       > registry_order(c, "flocks")),
        ]),
        "M15": ("invoice_audit: egg_dispatch snapshot trail in audit_log", [
            ("trg_audit_invoice(), DEFINER",
             lambda c: fn_is_definer(c, "trg_audit_invoice")),
            ("update trigger",
             lambda c: trg_exists(c, "egg_dispatch", "egg_dispatch_invoice_audit_update")),
            ("delete trigger",
             lambda c: trg_exists(c, "egg_dispatch", "egg_dispatch_invoice_audit_delete")),
        ]),
        "M16": ("role_permissions + user_permissions + has_capability()", [
            ("role_permissions table", lambda c: table_exists(c, "role_permissions")),
            ("user_permissions table", lambda c: table_exists(c, "user_permissions")),
            ("role_permissions RLS on", lambda c: rls_on(c, "role_permissions")),
            ("user_permissions RLS on", lambda c: rls_on(c, "user_permissions")),
            ("has_capability(uuid,text,uuid), DEFINER",
             lambda c: fn_is_definer(c, "has_capability")
                       and fn_exists(c, "has_capability", 3,
                                     ["uuid", "text", "uuid"])),
            ("admin-only policies",
             lambda c: pol_exists(c, "role_permissions", "role_permissions_admin_all")
                       and pol_exists(c, "user_permissions", "user_permissions_admin_all")),
            ("anon cannot execute or read",
             lambda c: anon_revoked(c, "has_capability", "uuid,text,uuid")
                       and not _has_table_priv("anon", "role_permissions", "SELECT")(c)
                       and not _has_table_priv("anon", "user_permissions", "SELECT")(c)),
        ]),
        "M17": ("opening_balances.opening_feed_received_kg numeric(19,4)", [
            ("opening_feed_received_kg column",
             lambda c: col_exists(c, "opening_balances", "opening_feed_received_kg")),
            ("column is numeric",
             lambda c: col_type(c, "opening_balances", "opening_feed_received_kg") == "numeric"),
        ]),
        "M18": ("farm_id_audit ledger + 13 move triggers", [
            ("farm_id_audit table", lambda c: table_exists(c, "farm_id_audit")),
            ("farm_id_audit RLS on", lambda c: rls_on(c, "farm_id_audit")),
            ("trg_farm_id_audit(), DEFINER",
             lambda c: fn_is_definer(c, "trg_farm_id_audit")),
            ("13 farm_id_audit triggers",
             lambda c: all(trg_exists(c, t, f"{t}_farm_id_audit")
                           for t in FARM_AUDIT_TABLES)),
            ("select policy",
             lambda c: pol_exists(c, "farm_id_audit", "farm_id_audit_select")),
        ]),
        "M19": ("duplicate_guard markers + fingerprint gates", [
            ("duplicate_guard table", lambda c: table_exists(c, "duplicate_guard")),
            ("duplicate_guard RLS on", lambda c: rls_on(c, "duplicate_guard")),
            ("dup_fingerprint(text,jsonb)",
             lambda c: fn_exists(c, "dup_fingerprint", 2, ["text", "jsonb"])),
            ("trg_duplicate_guard(), DEFINER",
             lambda c: fn_is_definer(c, "trg_duplicate_guard")),
            ("unique partial index (NOT blocked)",
             lambda c: idx_exists(c, "duplicate_guard", "uq_duplicate_guard_unblocked")),
            ("6 insert gates",
             lambda c: all(trg_exists(c, t, f"{t}_duplicate_guard")
                           for t in DUP_GUARD_TABLES)),
            ("select/unblock/admin policies",
             lambda c: all(pol_exists(c, "duplicate_guard", p) for p in (
                 "duplicate_guard_select", "duplicate_guard_unblock",
                 "duplicate_guard_admin_write", "duplicate_guard_admin_delete"))),
        ]),
        "M20": ("check_due_payments() reminder notifier (cron optional)", [
            ("check_due_payments(), DEFINER",
             lambda c: fn_is_definer(c, "check_due_payments")
                       and fn_exists(c, "check_due_payments", 0)),
            ("anon cannot execute",
             lambda c: anon_revoked(c, "check_due_payments", "")),
        ]),
    }


def _has_table_priv(role, table, priv="SELECT"):
    def probe(cur):
        cur.execute(
            "SELECT has_table_privilege(%s, 'public.' || %s, %s)",
            (role, table, priv),
        )
        return cur.fetchone()[0]
    return probe


# ─────────────────────────────────────────────────────────────────────────────
# base prerequisites (W1-W4 / M8 shape the W5 milestones build on)
# ─────────────────────────────────────────────────────────────────────────────
def base_checks(cur):
    missing = []
    for tbl in ["farms", "users", "flocks", "sync_table_registry", "audit_log",
                "app_notifications", "egg_dispatch", "payments", "customer_debt"]:
        if not table_exists(cur, tbl):
            missing.append(f"table {tbl}")
    for fn in ["user_manages_farm", "is_system_admin", "user_has_farm_access",
               "populate_sync_changes", "sync_tombstone_after_delete",
               "update_updated_at_column"]:
        if not fn_exists(cur, fn):
            missing.append(f"function {fn}()")
    return missing


# ─────────────────────────────────────────────────────────────────────────────
# reports
# ─────────────────────────────────────────────────────────────────────────────
def report_migrations(cur):
    """Print per-migration applied/pending lines. Return (applied, pending)."""
    checks = migration_checks()
    print("migration state (read-only):")
    applied, pending = [], []
    for label, _fname in ORDERED_W5:
        desc, probes = checks[label]
        missing = [ch for ch, probe in probes if not probe(cur)]
        if missing:
            pending.append(label)
            print(f"  {label:3} {_fname.split('_', 1)[1][:44]:<44} PENDING"
                  + (f"  (missing: {', '.join(missing)})" if missing else ""))
        else:
            applied.append(label)
            print(f"  {label:3} {_fname.split('_', 1)[1][:44]:<44} applied")
    return applied, pending


def precheck(conn_str):
    with connect(conn_str) as c:
        cur = c.cursor()
        missing = base_checks(cur)
        if missing:
            raise DeployError(
                "base prerequisites missing - is this the right database? "
                "The W1-W4 chain and M8 must be applied first. Missing: "
                + ", ".join(missing)
            )
        print("BASE: ok - W1-W4 chain + M8 prerequisites present.")
        applied, pending = report_migrations(cur)
        print()
        if not pending:
            print("RESULT: all eight W5 migrations applied.")
            return False
        print(f"RESULT: {len(pending)} pending migration(s): "
              f"{', '.join(pending)}. Apply them.")
        return True


def verify(conn_str):
    problems = []
    with connect(conn_str) as c:
        cur = c.cursor()
        checks = migration_checks()
        for label, _fname in ORDERED_W5:
            desc, probes = checks[label]
            for ch, probe in probes:
                if not probe(cur):
                    problems.append(f"{label} {ch}: missing")
    if problems:
        print("VERIFY: FAILED")
        for line in problems:
            print(f"  - {line}")
        return False
    print("VERIFY: PASSED - all eight W5 migrations are in place.")
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
    path = os.path.join(backup_dir, f"backup_w5_{stamp}.sql")
    print(f"backup: pg_dump --schema=public --no-owner --no-acl -> {path}")
    res = subprocess.run(
        ["pg_dump", "-d", conn_str, "--schema=public", "--no-owner", "--no-acl",
         "-f", path],
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


def list_migrations():
    print("W5 apply order (operator-specified, EXACT):")
    for i, (label, fname) in enumerate(ORDERED_W5, 1):
        path = os.path.join(MIGDIR, fname)
        marker = "OK" if os.path.isfile(path) else "MISSING FILE"
        print(f"  {i:2}. [{label}] {fname}  {marker}")
    bad = [fname for _l, fname in ORDERED_W5 if not os.path.isfile(os.path.join(MIGDIR, fname))]
    if bad:
        raise DeployError("migration file(s) missing: " + ", ".join(bad))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--connection", help="postgres URL (or set SUPABASE_DB_URL)")
    ap.add_argument("--precheck-only", action="store_true",
                    help="read-only state report and exit")
    ap.add_argument("--apply", action="store_true",
                    help="backup -> confirm -> apply pending migrations -> verify")
    ap.add_argument("--verify", action="store_true",
                    help="read-only hard check of the post-W5 state")
    ap.add_argument("--list-migrations", action="store_true",
                    help="print the apply order and exit (no connection)")
    ap.add_argument("--backup-dir", default=os.path.join(ROOT, "backups"))
    ap.add_argument("--no-backup", action="store_true", help="skip the pg_dump")
    ap.add_argument("--yes", action="store_true", help="skip all prompts")
    ap.add_argument("--force", action="store_true",
                    help="re-run every migration even if precheck says all applied")
    args = ap.parse_args()

    if args.list_migrations:
        try:
            list_migrations()
        except DeployError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        return

    conn_str = resolve_connection(args.connection)

    if args.verify:
        sys.exit(0 if verify(conn_str) else 1)

    already = precheck(conn_str)  # always report the state first
    if args.precheck_only or not args.apply:
        return

    if not already and not args.force:
        print("\neverything already in place - refusing to re-apply. Use "
              "--force to run the loop anyway (all migrations are re-run safe).")
        sys.exit(0)

    list_migrations()
    if not confirm("\nApply the pending W5 migrations now?"):
        print("aborted by user")
        sys.exit(2)

    if not args.no_backup:
        backup(conn_str, args.backup_dir)

    checks = migration_checks()
    for label, fname in ORDERED_W5:
        path = os.path.join(MIGDIR, fname)
        if not os.path.isfile(path):
            raise DeployError(f"migration file not found: {path}")
        if not args.force:
            probes = checks[label][1]
            with connect(conn_str) as c:
                if all(p(c) for _ch, p in probes):
                    print(f"skip (already applied): {fname}")
                    continue
        run_sql_file(conn_str, path)

    sys.exit(0 if verify(conn_str) else 1)


if __name__ == "__main__":
    try:
        main()
    except DeployError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
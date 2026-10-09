#!/usr/bin/env python3
"""deploy_w4.py - deploy + verify the W4 migrations (M1-M9) and the GUCs.

Applies the ten forward migrations of the W4 milestone in the operator's
declared order and then verifies the resulting schema shape against the DB.
Read docs/DEPLOYMENT.md (W4 section) before running anything against
production.

Modes
-----
  (default / --precheck-only)  Read-only. Reports base prerequisites, then
                               per-migration state (applied / pending) and
                               the two GUCs (app.pin_secret, app.v1_grace_until).
  --apply                      backup -> confirm -> apply every PENDING
                               migration in order -> set the GUCs -> verify.
                               Refuses to re-apply if everything is already
                               in place (use --force to run the loop anyway;
                               every migration is re-run safe).
  --verify                     Read-only hard check: every W4 object present,
                               GUCs set (secret present, grace in the future),
                               current_schema_version() = 1, financial RLS
                               still manager-scoped. With --drift it also runs
                               verify_schema_drift.py (static; requires
                               json_output.txt to be regenerated first).
  --list-migrations            Print the apply order and exit. No connection.

Connection: --connection URL or env SUPABASE_DB_URL / DATABASE_URL.

The W4 apply order (docs/DEPLOYMENT.md W4, user-specified, EXACT):

    1. 20261003000100_expenses_flock_id.sql           (M1)
    2. 20261003000200_stock_adjustments_flock_id.sql  (M2)
    3. 20261003000300_medications_cost.sql            (M3)
    4. 20261003000400_flock_archived.sql              (M4)
    5. 20261003000500_validate_flock_farm_coverage.sql(M5)
    6. 20261003000600_pin_secret.sql                  (M6a)
    7. 20261003000610_throttle.sql                    (M6b)
    8. 20261003000620_security_alerts.sql             (M6c)
    9. 20261003000700_revenue_worker_id_uuid.sql      (M7)
   10. 20261003000900_app_schema_version.sql          (M9)

(M8 20261002000000_restore_financial_rls.sql is NOT in this list - it was
deployed to production on 2026-10-08; this tool only asserts it is still in
place.)

GUCs (--apply sets these AFTER the migrations):
    ALTER ROLE <role> SET app.pin_secret       = '<secret>'
    ALTER ROLE <role> SET app.v1_grace_until   = <now() + 7 days>

The secret is NEVER read from the repo: provide it with --pin-secret or the
MADJANA_PIN_SECRET environment variable. It is echoed nowhere.

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
ORDERED_W4 = [
    ("M1",  "20261003000100_expenses_flock_id.sql"),
    ("M2",  "20261003000200_stock_adjustments_flock_id.sql"),
    ("M3",  "20261003000300_medications_cost.sql"),
    ("M4",  "20261003000400_flock_archived.sql"),
    ("M5",  "20261003000500_validate_flock_farm_coverage.sql"),
    ("M6a", "20261003000600_pin_secret.sql"),
    ("M6b", "20261003000610_throttle.sql"),
    ("M6c", "20261003000620_security_alerts.sql"),
    ("M7",  "20261003000700_revenue_worker_id_uuid.sql"),
    ("M9",  "20261003000900_app_schema_version.sql"),
]

FINANCIAL_TABLES = [
    "payments", "expenses", "revenue",
    "opening_balances", "inventory_items", "stock_adjustments",
]

DRIFT_TOOL = os.path.join(ROOT, "supabase", "tools", "verify_schema_drift.py")


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


def rls_on(cur, table):
    cur.execute(
        "SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.' || %s)",
        (table,),
    )
    row = cur.fetchone()
    return bool(row[0]) if row else False


def table_exists(cur, table):
    cur.execute("SELECT to_regclass('public.' || %s)", (table,))
    return cur.fetchone() is not None


# ─────────────────────────────────────────────────────────────────────────────
# curated shape checks per migration
# ─────────────────────────────────────────────────────────────────────────────
def migration_checks():
    """Return {M-label: (description, [(check-label, callable(cur))])}."""
    return {
        "M1": ("expenses.flock_id nullable FK", [
            ("expenses.flock_id column", lambda c: col_exists(c, "expenses", "flock_id")),
        ]),
        "M2": ("stock_adjustments.flock_id + unit_price + currency", [
            ("stock_adjustments.flock_id", lambda c: col_exists(c, "stock_adjustments", "flock_id")),
            ("stock_adjustments.unit_price", lambda c: col_exists(c, "stock_adjustments", "unit_price")),
            ("stock_adjustments.currency", lambda c: col_exists(c, "stock_adjustments", "currency")),
            ("farm_id FK is RESTRICT", lambda c: _fk_restrict(c, "stock_adjustments", "farm_id")),
        ]),
        "M3": ("medications cost + currency + inventory_item_id", [
            ("medications.cost", lambda c: col_exists(c, "medications", "cost")),
            ("medications.currency", lambda c: col_exists(c, "medications", "currency")),
            ("medications.inventory_item_id", lambda c: col_exists(c, "medications", "inventory_item_id")),
        ]),
        "M4": ("flocks.archived + guard trigger", [
            ("flocks.archived_at", lambda c: col_exists(c, "flocks", "archived_at")),
            ("trg_guard_flock_archive", lambda c: trg_exists(c, "flocks", "trg_guard_flock_archive")),
        ]),
        "M5": ("stock_adjustments covered by validate_flock_farm", [
            ("require_farm_id()", lambda c: fn_exists(c, "require_farm_id")),
            ("trg_validate_flock_sa", lambda c: trg_exists(c, "stock_adjustments", "trg_validate_flock_sa")),
            ("trg_require_farm_id", lambda c: trg_exists(c, "stock_adjustments", "trg_require_farm_id")),
        ]),
        "M6a": ("PIN secret v2 + record_login_success(uid, pin)", [
            ("app_password_from_pin_v2(text)", lambda c: fn_exists(c, "app_password_from_pin_v2", 1, ["text"])),
            ("record_login_success(uuid, text)", lambda c: fn_exists(c, "record_login_success", 2, ["uuid", "text"])),
            ("4 writers call v2", _writers_on_v2),
        ]),
        "M6b": ("login throttle without client bounds", [
            ("login_throttle table", lambda c: table_exists(c, "login_throttle")),
            ("throttle_exceeded(text)", lambda c: fn_exists(c, "throttle_exceeded", 1)),
            ("record_login_failure(text, text)", lambda c: fn_exists(c, "record_login_failure", 2)),
        ]),
        "M6c": ("security_alerts admin surface", [
            ("security_alerts RLS on", lambda c: rls_on(c, "security_alerts")),
            ("security_alerts_admin_all policy", lambda c: pol_exists(c, "security_alerts", "security_alerts_admin_all")),
            ("get_unresolved_security_alerts()", lambda c: fn_exists(c, "get_unresolved_security_alerts", 0)),
            ("acknowledge_security_alert(uuid)", lambda c: fn_exists(c, "acknowledge_security_alert", 1)),
            ("resolve_security_alert(uuid)", lambda c: fn_exists(c, "resolve_security_alert", 1)),
        ]),
        "M7": ("revenue.worker_id uuid + FK + index", [
            ("revenue.worker_id is uuid", lambda c: col_type(c, "revenue", "worker_id") == "uuid"),
            ("revenue_worker_id_fkey", _revenue_worker_fkey),
            ("idx_revenue_worker", lambda c: idx_exists(c, "revenue", "idx_revenue_worker")),
        ]),
        "M9": ("app_schema_version + current_schema_version()", [
            ("app_schema_version table", lambda c: table_exists(c, "app_schema_version")),
            ("current_schema_version()", lambda c: fn_exists(c, "current_schema_version", 0)),
            ("version row = 1", _schema_version_is_one),
            ("anon cannot execute", _version_anon_revoked),
        ]),
    }


def _fk_restrict(cur, table, column):
    cur.execute(
        "SELECT confdeltype FROM pg_constraint "
        "WHERE conrelid = to_regclass('public.' || %s) "
        "  AND contype = 'f' AND conkey = ARRAY[ "
        "      (SELECT attnum FROM pg_attribute "
        "        WHERE attrelid = to_regclass('public.' || %s) AND attname = %s) ]",
        (table, table, column),
    )
    rows = [r[0] for r in cur.fetchall()]
    return rows and rows == ["r"]


def _writers_on_v2(cur):
    cur.execute(
        "SELECT count(*) FROM pg_proc p "
        "JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname = 'public' AND p.prokind = 'f' "
        "  AND p.proname IN ('admin_create_user', 'create_farm_with_manager', "
        "                    'admin_reset_pin', 'bootstrap_create_farm_and_manager') "
        "  AND strpos(p.prosrc, 'public.app_password_from_pin_v2(') > 0",
    )
    return cur.fetchone()[0] == 4


def _revenue_worker_fkey(cur):
    cur.execute(
        "SELECT 1 FROM pg_constraint "
        "WHERE conname = 'revenue_worker_id_fkey' "
        "  AND conrelid = to_regclass('public.revenue') AND contype = 'f'",
    )
    return cur.fetchone() is not None


def _schema_version_is_one(cur):
    try:
        cur.execute("SELECT current_schema_version()")
        return cur.fetchone()[0] == 1
    except psycopg2.Error:
        return False


def _version_anon_revoked(cur):
    cur.execute(
        "SELECT has_function_privilege('anon', 'public.current_schema_version()', 'EXECUTE')"
    )
    return cur.fetchone()[0] is False


# ─────────────────────────────────────────────────────────────────────────────
# base prerequisites (pre-M8 production shape)
# ─────────────────────────────────────────────────────────────────────────────
def base_checks(cur):
    missing = []
    for tbl in FINANCIAL_TABLES:
        if not table_exists(cur, tbl):
            missing.append(f"financial table {tbl}")
    if not fn_exists(cur, "user_manages_farm"):
        missing.append("function user_manages_farm()")
    if not fn_exists(cur, "validate_flock_farm"):
        missing.append("function validate_flock_farm()")
    if not table_exists(cur, "users"):
        missing.append("table users")
    return missing


# ─────────────────────────────────────────────────────────────────────────────
# GUCs
# ─────────────────────────────────────────────────────────────────────────────
def guc_report(cur):
    """Return a dict of human-readable GUC status for display."""
    cur.execute("SELECT current_setting('app.pin_secret', true)")
    secret = cur.fetchone()[0] or ""
    cur.execute("SELECT current_setting('app.v1_grace_until', true)")
    grace = (cur.fetchone()[0] or "").strip()

    grace_state = "unset"
    if grace:
        try:
            cur.execute("SELECT %s::timestamptz > now()", (grace,))
            grace_state = "future" if cur.fetchone()[0] else "expired"
        except psycopg2.Error:
            grace_state = "invalid"

    return {
        "pin_secret_set": bool(secret),
        "pin_secret_len": len(secret),
        "grace": grace_state,
    }


def set_gucs(conn_str, role, secret):
    import datetime as _dt
    with connect(conn_str) as c:
        cur = c.cursor()
        cur.execute("ALTER ROLE %s SET app.pin_secret = %%s" % _quote_ident(role), (secret,))
        grace = (_dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=7)).isoformat(" ", "seconds")
        cur.execute("ALTER ROLE %s SET app.v1_grace_until = %%s" % _quote_ident(role), (grace,))
        print(f"GUCs: ALTER ROLE {role} SET app.pin_secret = '***' ({len(secret)} chars)")
        print(f"GUCs: ALTER ROLE {role} SET app.v1_grace_until = {grace}")


def _quote_ident(name):
    return '"' + name.replace('"', '""') + '"'


# ─────────────────────────────────────────────────────────────────────────────
# reports
# ─────────────────────────────────────────────────────────────────────────────
def report_migrations(cur):
    """Print per-migration applied/pending lines. Return (applied, pending)."""
    checks = migration_checks()
    print("migration state (read-only):")
    applied, pending = [], []
    for label, _fname in ORDERED_W4:
        desc, probes = checks[label]
        missing = [ch for ch, probe in probes if not probe(cur)]
        if missing:
            pending.append(label)
            print(f"  {label:3} {_fname.split('_', 1)[1][:46]:<46} PENDING"
                  + (f"  (missing: {', '.join(missing)})" if missing else ""))
        else:
            applied.append(label)
            print(f"  {label:3} {_fname.split('_', 1)[1][:46]:<46} applied")
    return applied, pending


# ─────────────────────────────────────────────────────────────────────────────
# modes
# ─────────────────────────────────────────────────────────────────────────────
def precheck(conn_str):
    with connect(conn_str) as c:
        cur = c.cursor()
        missing = base_checks(cur)
        if missing:
            raise DeployError(
                "base prerequisites missing - is this the right database? "
                "init.sql / 20260926* / 20261002000000 (M8) must be applied "
                "first. Missing: " + ", ".join(missing)
            )
        print("BASE: ok - financial tables + user_manages_farm/validate_flock_farm present.")
        applied, pending = report_migrations(cur)
        gucs = guc_report(cur)
        print(f"GUCs: app.pin_secret      {'SET (' + str(gucs['pin_secret_len']) + ' chars)' if gucs['pin_secret_set'] else 'NOT SET (logins/writers fail closed)'}")
        print(f"GUCs: app.v1_grace_until  {gucs['grace']}")
        print()
        if not pending:
            print("RESULT: all ten W4 migrations applied.")
            return False
        print(f"RESULT: {len(pending)} pending migration(s): "
              f"{', '.join(pending)}. Apply them.")
        return True


def verify(conn_str):
    problems = []
    with connect(conn_str) as c:
        cur = c.cursor()
        for tbl in FINANCIAL_TABLES:
            if not table_exists(cur, tbl):
                problems.append(f"{tbl}: table missing")
        checks = migration_checks()
        for label, _fname in ORDERED_W4:
            desc, probes = checks[label]
            for ch, probe in probes:
                if not probe(cur):
                    problems.append(f"{label} {ch}: missing")
        gucs = guc_report(cur)
        if not gucs["pin_secret_set"]:
            problems.append("GUC app.pin_secret is NOT set (logins/writers fail closed)")
        if gucs["grace"] != "future":
            problems.append(f"GUC app.v1_grace_until is {gucs['grace']} (must be future)")
    if problems:
        print("VERIFY: FAILED")
        for line in problems:
            print(f"  - {line}")
        return False
    print("VERIFY: PASSED - all ten W4 migrations, both GUCs, and M8 "
          "financial RLS are in place.")
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
    path = os.path.join(backup_dir, f"backup_w4_{stamp}.sql")
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


def resolve_secret(args):
    secret = args.pin_secret or os.environ.get("MADJANA_PIN_SECRET")
    if not secret:
        raise DeployError(
            "app.pin_secret was not given. Pass --pin-secret or set the "
            "MADJANA_PIN_SECRET environment variable as the safer option "
            "(the value is never echoed, only its length; do not commit it)."
        )
    return secret


def list_migrations():
    print("W4 apply order (operator-specified, EXACT):")
    for i, (label, fname) in enumerate(ORDERED_W4, 1):
        path = os.path.join(MIGDIR, fname)
        marker = "OK" if os.path.isfile(path) else "MISSING FILE"
        print(f"  {i:2}. [{label}] {fname}  {marker}")
    bad = [fname for _l, fname in ORDERED_W4 if not os.path.isfile(os.path.join(MIGDIR, fname))]
    if bad:
        raise DeployError("migration file(s) missing: " + ", ".join(bad))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--connection", help="postgres URL (or set SUPABASE_DB_URL)")
    ap.add_argument("--precheck-only", action="store_true",
                    help="read-only state report and exit")
    ap.add_argument("--apply", action="store_true",
                    help="backup -> confirm -> apply pending migrations -> GUCs -> verify")
    ap.add_argument("--verify", action="store_true",
                    help="read-only hard check of the post-W4 state")
    ap.add_argument("--drift", action="store_true",
                    help="verify + run verify_schema_drift.py (implies "
                         "--verify; requires json_output.txt regenerated first)")
    ap.add_argument("--list-migrations", action="store_true",
                    help="print the apply order and exit (no connection)")
    ap.add_argument("--pin-secret", default=None,
                    help="app.pin_secret value (or set MADJANA_PIN_SECRET). "
                         "Never committed; echoed only as length.")
    ap.add_argument("--role", default="postgres",
                    help="role for the GUC ALTER ROLE statements (default postgres)")
    ap.add_argument("--backup-dir", default=os.path.join(ROOT, "backups"))
    ap.add_argument("--no-backup", action="store_true", help="skip the pg_dump")
    ap.add_argument("--skip-gucs", action="store_true",
                    help="apply migrations only, do not set the GUCs")
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

    if args.drift:
        args.verify = True

    if args.verify:
        ok = verify(conn_str)
        if ok and args.drift:
            ok = run_drift_check()
        sys.exit(0 if ok else 1)

    already = precheck(conn_str)  # always report the state first
    if args.precheck_only or not args.apply:
        return

    if not already and not args.force:
        print("\neverything already in place - refusing to re-apply. Use "
              "--force to run the loop anyway (all migrations are re-run safe).")
        sys.exit(0)

    list_migrations()
    if not confirm("\nApply the pending W4 migrations now?"):
        print("aborted by user")
        sys.exit(2)

    if not args.no_backup:
        backup(conn_str, args.backup_dir)

    checks = migration_checks()
    for label, fname in ORDERED_W4:
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

    if not args.skip_gucs:
        if not confirm("\nSet the GUCs (app.pin_secret, app.v1_grace_until)? "
                       "This does NOT run if --skip-gucs was passed."):
            print("GUCs not set - migration M6a will fail closed until you set "
                  "app.pin_secret manually.")
        else:
            set_gucs(conn_str, args.role, resolve_secret(args))

    sys.exit(0 if verify(conn_str) else 1)


def run_drift_check():
    if not os.path.isfile(DRIFT_TOOL):
        raise DeployError(f"drift tool not found: {DRIFT_TOOL}")
    print("running verify_schema_drift.py (static; json_output.txt must have "
          "been regenerated from production)")
    res = subprocess.run([sys.executable, DRIFT_TOOL, "--json"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print("DRIFT: FAILED - json_output.txt does not match the W4 schema. "
              "Regenerate it from production, then re-run.")
        print(res.stdout[-2000:])
        return False
    print("DRIFT: PASSED - json_output.txt matches.")
    return True


if __name__ == "__main__":
    try:
        main()
    except DeployError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
#!/usr/bin/env python3
"""Run every check against the LOCAL test database. Never touches Supabase.

    python supabase/tests/run_all.py            # full: rebuild + all suites
    python supabase/tests/run_all.py --no-build # reuse the existing madjana_test

Steps:
  1. build       -- rebuild madjana_test from shim + base schema + migrations
  2. structural  -- verify_test_db.py, object/RLS/contract shape
  3. behavioural -- test_sync_farm_id.py, sync_records_batch farm resolution
  3b. repair     -- test_flock_rehome.py, the 019d8bee re-home migration
  4. regression  -- the two SQL suites, via psql as test_runner (non-superuser,
                    so RLS actually applies; the local `postgres` role has
                    BYPASSRLS and would report every isolation test as a pass)
"""
import io
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

# psql resolution order: explicit override -> PATH -> the local Windows install.
# The Windows path is the LAST fallback, not the only option: hardcoding it as
# the sole candidate made this script impossible to run on Linux/macOS, which
# is what CI (ubuntu-latest) needs. shutil.which("psql") resolves on the
# runners, and on this Windows box psql is not on PATH, so local behaviour is
# unchanged.
PSQL = (os.environ.get("PSQL_BIN")
        or shutil.which("psql")
        or r"C:\Program Files\PostgreSQL\15\bin\psql.exe")

# Connection target. Defaults match the Docker/local test database exactly
# (127.0.0.1:5433/madjana_test); the env overrides exist so CI can move the
# port when 5433 is already taken on a shared runner, without editing code.
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5433")
DB = os.environ.get("PGDATABASE", "madjana_test")

# The SQL suites are Stage-authored scripts: they raise on the first failed
# assertion, so a non-zero exit plus no FAIL notice means everything passed.
SQL_SUITES = [
    ("4a. P0 isolation + sync", "p0_isolation_and_sync_test.sql"),
    ("4b. revenue sync regression", "revenue_sync_regression_test.sql"),
    ("4c. P0 financial RLS guard", "p0_financial_rls_guard_test.sql"),
    ("4d. W0.1 recovered tables", "w0_1_missing_tables_test.sql"),
    ("4e. P0 expenses.flock_id", "p0_expenses_flock_test.sql"),
    ("4f. P0 medications.cost", "p0_medications_cost_test.sql"),
    ("4g. P0 flocks.archived", "p0_flock_archived_test.sql"),
    ("4h. M5 flock/farm guard coverage", "p0_validate_flock_farm_coverage_test.sql"),
    ("4i. M6a PIN secret v2", "p0_pin_secret_test.sql"),
    ("4j. M6 deploy simulation (M6a+M6b)", "p0_deploy_m6_test.sql"),
    ("4k. M6b login throttle", "p0_throttle_test.sql"),
    ("4l. M6c security alerts RLS + admin surface", "p0_security_alerts_rls_test.sql"),
    ("4m. M7 revenue.worker_id uuid", "p0_revenue_worker_id_test.sql"),
    ("4n. M9 schema version marker", "p0_schema_version_test.sql"),
    ("4o. M10 catch/error contract", "p0_catch_test.sql"),
    ("4p. W5-M13 record lock", "p0_record_lock_test.sql"),
    ("4q. W5-M14 worker change requests", "p0_worker_requests_test.sql"),
    ("4r. W5-M15 invoice audit trail", "p0_invoice_audit_test.sql"),
    ("4s. W5-M16 role permissions", "p0_role_permissions_test.sql"),
    ("4t. W5-M17 opening feed received", "p0_opening_feed_received_test.sql"),
    ("4u. W5-M18 farm_id audit ledger", "p0_farm_id_audit_test.sql"),
    ("4v. W5-M19 duplicate guard", "p0_duplicate_guard_test.sql"),
    ("4w. W5-M20 due payments", "p0_due_payments_test.sql"),
]


def run(title, script, allow_fail=False):
    print("\n" + "=" * 70)
    print(f"  {title}")
    print("=" * 70)
    r = subprocess.run([PY, os.path.join(HERE, script)],
                       capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = io.StringIO()
    out.write(r.stdout or "")
    if r.stderr.strip():
        out.write("\n[stderr]\n" + r.stderr)
    body = out.getvalue()
    # only echo the interesting lines; the suites print a line per assertion
    for line in body.splitlines():
        low = line.lower()
        if ("fail" in low or "error" in low or "warn" in low
                or "passed" in low or "tables" in low
                or "functions" in low or "policies" in low
                or line.startswith("=") and len(line) > 20):
            print(line)
    if r.returncode != 0:
        print(f"\n  >> {title}: EXIT {r.returncode}")
        if not allow_fail:
            print("\n--- full output ---")
            print(body)
    return r.returncode


def run_sql(title, filename):
    """Run one .sql suite through psql as test_runner and count its notices."""
    print("\n" + "=" * 70)
    print(f"  {title}")
    print("=" * 70)
    r = subprocess.run(
        [PSQL, "-h", HOST, "-p", PORT, "-U", "postgres",
         "-d", DB, "-w", "-q",
         "-c", "SET ROLE test_runner",
         "-f", os.path.join(HERE, filename)],
        capture_output=True, text=True, encoding="utf-8", errors="replace")

    body = (r.stdout or "") + (r.stderr or "")
    passed = len(re.findall(r"NOTICE:\s+PASS", body))
    # psql prefixes every server message with "psql:<file>:<line>:", and wraps
    # long notices, so match on the message body rather than a fixed prefix.
    failures = [ln for ln in body.splitlines()
                if re.search(r"(NOTICE|ERROR):\s+FAIL|ERROR:", ln)]

    for line in body.splitlines():
        if re.search(r"NOTICE:\s+PASS", line) or failures and line in failures:
            print(line)

    if failures or r.returncode != 0:
        print(f"\n  >> {title}: {len(failures)} failure line(s), "
              f"EXIT {r.returncode}")
        print("\n--- full output ---")
        print(body)
        return 1

    print(f"  {passed} assertions passed, 0 failed")
    return 0


def main():
    # Windows console code pages (cp1256/cp1252) cannot encode every
    # character the suites emit -- a single '⇒' in a NOTICE line crashed
    # this script mid-run on the dev box while CI (UTF-8) was fine.
    # Reconfigure before any print; 'replace' keeps a truncated line
    # readable rather than fatal.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass  # Python <3.7 or a stream that forbids reconfigure

    no_build = "--no-build" in sys.argv
    if not no_build:
        run("1. build test database", "build_test_db.py")
    else:
        print("\n(skipping build; reusing existing madjana_test)")

    rc1 = run("2. structural verification", "verify_test_db.py")
    rc2 = run("3. behavioural suite", "test_sync_farm_id.py")
    rc3 = run("3b. flock rehome repair", "test_flock_rehome.py")

    rcs = []
    for title, filename in SQL_SUITES:
        rcs.append(run_sql(title, filename))

    print("\n" + "=" * 70)
    ok = rc1 == 0 and rc2 == 0 and rc3 == 0 and all(rc == 0 for rc in rcs)
    print(f"structural rc={rc1}   behavioural rc={rc2}   "
          f"rehome rc={rc3}   sql rc={rcs}   -> "
          + ("ALL GREEN" if ok else "FAILURES ABOVE"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
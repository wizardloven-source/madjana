#!/usr/bin/env python3
"""Run every check against the LOCAL test database. Never touches Supabase.

    python supabase/tests/run_all.py            # full: rebuild + all suites
    python supabase/tests/run_all.py --no-build # reuse the existing madjana_test

Steps:
  1. build       -- rebuild madjana_test from shim + base schema + migrations
  2. structural  -- verify_test_db.py, object/RLS/contract shape
  3. behavioural -- test_sync_farm_id.py, sync_records_batch farm resolution
  4. regression  -- the two SQL suites, via psql as test_runner (non-superuser,
                    so RLS actually applies; the local `postgres` role has
                    BYPASSRLS and would report every isolation test as a pass)
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
PSQL = r"C:\Program Files\PostgreSQL\15\bin\psql.exe"

# The SQL suites are Stage-authored scripts: they raise on the first failed
# assertion, so a non-zero exit plus no FAIL notice means everything passed.
SQL_SUITES = [
    ("4a. P0 isolation + sync", "p0_isolation_and_sync_test.sql"),
    ("4b. revenue sync regression", "revenue_sync_regression_test.sql"),
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
        [PSQL, "-h", "127.0.0.1", "-p", "5433", "-U", "postgres",
         "-d", "madjana_test", "-w", "-q",
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
    no_build = "--no-build" in sys.argv
    if not no_build:
        run("1. build test database", "build_test_db.py")
    else:
        print("\n(skipping build; reusing existing madjana_test)")

    rc1 = run("2. structural verification", "verify_test_db.py")
    rc2 = run("3. behavioural suite", "test_sync_farm_id.py")

    rcs = []
    for title, filename in SQL_SUITES:
        rcs.append(run_sql(title, filename))

    print("\n" + "=" * 70)
    ok = rc1 == 0 and rc2 == 0 and all(rc == 0 for rc in rcs)
    print(f"structural rc={rc1}   behavioural rc={rc2}   "
          f"sql rc={rcs}   -> "
          + ("ALL GREEN" if ok else "FAILURES ABOVE"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
#!/usr/bin/env python3
"""Rebuild madjana_test from scratch: shim -> base schema -> migrations.

    python supabase/tests/build_test_db.py

Drops and recreates the database every run, so there is never any doubt about
what state is being tested.

Statements are executed one at a time and committed as they succeed, because a
multi-statement string is one implicit transaction server-side: one failure
would discard everything before it. That matters here -- the base snapshots
ALTER/GRANT tables roughly a thousand lines before they CREATE them.
"""
import io
import os
import re
import sys

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sqlsplit import split_statements, strip_tx  # noqa: E402

HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = int(os.environ.get("PGPORT", "5433"))
USER = "postgres"
DB = os.environ.get("PGDATABASE", "madjana_test")

# Derive the repo root from this file's own location instead of hardcoding
# "C:\Users\MTC\Desktop\madjana". The hardcoded copy made this script run only
# on one developer's machine: on the CI runner (ubuntu-latest) that path does
# not exist, so every file below resolved to nothing.
#   <repo>/supabase/tests/build_test_db.py -> SUPABASE = <repo>/supabase
SUPABASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(SUPABASE)
SHIM = os.path.join(SUPABASE, "tests", "supabase_test_shim.sql")
GRANTS = os.path.join(SUPABASE, "tests", "test_grants.sql")
FIXTURES = os.path.join(SUPABASE, "tests", "local_fixtures.sql")
# init.sql, not schema_production.sql: they are near-identical snapshots, and
# neither is a valid from-scratch bootstrap (see module docstring in sqlsplit).
BASE = os.path.join(SUPABASE, "init.sql")
MIGDIR = os.path.join(SUPABASE, "migrations")


def apply_file(cur, path, label, verbose_errors=12):
    """Execute every statement, keeping what succeeds. Returns (ok, failures)."""
    text = io.open(path, encoding="utf-8-sig", errors="replace").read()
    stmts = split_statements(strip_tx(text))
    failures = []
    for stmt in stmts:
        try:
            cur.execute(stmt)
            cur.connection.commit()
        except Exception as e:
            cur.connection.rollback()
            lines = str(e).strip().splitlines()
            failures.append((stmt, lines[0] if lines else type(e).__name__))

    total = len(stmts)
    if not failures:
        print(f"  OK    {label}  ({total} statements, 0 errors)")
        return True, failures

    print(f"  WARN  {label}  ({total} statements, {len(failures)} errors)")
    for stmt, err in failures[:verbose_errors]:
        head = " ".join(stmt.split())[:110]
        print(f"          {err}")
        print(f"            > {head}")
    if len(failures) > verbose_errors:
        print(f"          ... and {len(failures) - verbose_errors} more")
    return False, failures


def build(verbose=True, quiet_ok=True):
    """Drop, recreate, and populate the test database.

    Returns the list of (file, errors) that failed to apply cleanly. An empty
    list means shim + all numbered migrations applied without error. The base
    snapshot's pass-1 errors are tolerated by design (see run the comment below).
    """
    def say(*a):
        if verbose:
            print(*a)

    say(f"rebuilding {DB} on {HOST}:{PORT}\n")

    a = psycopg2.connect(host=HOST, port=PORT, user=USER, dbname="postgres",
                         password="", sslmode="disable")
    a.autocommit = True
    ac = a.cursor()
    ac.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
               "WHERE datname=%s AND pid <> pg_backend_pid()", (DB,))
    ac.execute(f'DROP DATABASE IF EXISTS "{DB}"')
    ac.execute(f'CREATE DATABASE "{DB}"')
    a.close()
    say("database recreated")

    conn = psycopg2.connect(host=HOST, port=PORT, user=USER, dbname=DB,
                            password="", sslmode="disable")
    conn.autocommit = False
    cur = conn.cursor()

    say("\nshim:")
    _, shim_fail = apply_file(cur, SHIM, "supabase_test_shim.sql",
                              verbose_errors=12 if verbose else 0)

    say("\nbase schema:")
    _, base_fail = apply_file(cur, BASE, "init.sql (pass 1)",
                              verbose_errors=12 if verbose else 0)
    # Pass 2. The snapshot ALTERs/GRANTs some tables (sync_conflicts) about a
    # thousand lines before it CREATEs them, so those statements fail on pass 1
    # and leave the RLS/grant silently missing. Now that the tables exist, a
    # second pass applies them. Pass 2's error count is the meaningful signal.
    _, base_fail2 = apply_file(cur, BASE, "init.sql (pass 2)",
                               verbose_errors=12 if verbose else 0)

    say("\nmigrations:")
    mig_fail = []
    for name in sorted(os.listdir(MIGDIR)):
        if not name.endswith(".sql"):
            continue
        if not re.match(r"^\d{14}_", name):
            say(f"  skip  {name}  (not part of the numbered chain)")
            continue
        # ── rollbacks are NOT part of the forward chain ──
        # They carry the same 14-digit timestamp prefix so they sort next to
        # the migration they undo, but running one here would UNDO the
        # migration beside it. W0.1 shipped both and the build therefore
        # created flock_movements, then immediately dropped it again.
        if "rollback" in name:
            say(f"  skip  {name}  (rollback, not a forward migration)")
            continue
        _, fails = apply_file(cur, os.path.join(MIGDIR, name), name,
                              verbose_errors=4 if verbose else 0)
        if fails:
            mig_fail.append((name, fails))

    say("\ngrants:")
    _, grant_fail = apply_file(cur, GRANTS, "test_grants.sql",
                               verbose_errors=12 if verbose else 0)

    # Committed, unlike everything else here: the two SQL regression tests are
    # written against these hardcoded uuids and expect them to already exist.
    say("\nfixtures:")
    _, fixture_fail = apply_file(cur, FIXTURES, "local_fixtures.sql",
                                 verbose_errors=12 if verbose else 0)

    if quiet_ok and verbose:
        print("\n" + "=" * 62)
    cur.execute("SELECT count(*) FROM pg_tables WHERE schemaname='public'")
    ntab = cur.fetchone()[0]
    cur.execute("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                   WHERE n.nspname='public'""")
    nfun = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM pg_policies WHERE schemaname='public'")
    npol = cur.fetchone()[0]
    say(f"public tables  : {ntab}")
    say(f"public functions: {nfun}")
    say(f"RLS policies    : {npol}")

    hard = []
    if shim_fail:
        hard.append(("supabase_test_shim.sql", shim_fail))
    if grant_fail:
        hard.append(("test_grants.sql", grant_fail))
    if fixture_fail:
        hard.append(("local_fixtures.sql", fixture_fail))
    if base_fail2:
        hard.append((f"{os.path.basename(BASE)} (pass 2)", base_fail2))
    hard.extend(mig_fail)

    if hard and verbose:
        print(f"\n{len(hard)} FILE(S) WITH ERRORS:")
        for name, fails in hard:
            print(f"  - {name}: {len(fails)} error(s)")
            # The first few statements matter most: they are what tells you
            # whether a dependency is missing (function not created yet,
            # table not in the snapshot) or whether the statement itself is
            # wrong. Print them even when not verbose, so a CI failure is
            # diagnosable from the step log without downloading the archive.
            for stmt, err in fails[:5]:
                head = " ".join(stmt.split())[:140]
                print(f"        {err}")
                print(f"        > {head}")
            if len(fails) > 5:
                print(f"        ... and {len(fails) - 5} more")
        if base_fail:
            print(f"  (pass 1 of the base snapshot also had {len(base_fail)} "
                  f"errors, all forward references resolved by pass 2)")
    conn.close()
    return hard


def connect():
    """Open a connection to the test database, rebuilding it if it is absent.

    The local PG 15 instance has been observed dropping and recreating this
    database underneath us (it matches the earlier 0xC0000142 backend crashes),
    so callers should not assume the database is already there.
    """
    for attempt in (1, 2):
        try:
            conn = psycopg2.connect(host=HOST, port=PORT, user=USER, dbname=DB,
                                    password="", sslmode="disable")
            cur = conn.cursor()
            cur.execute("SELECT count(*) FROM pg_tables WHERE schemaname='public'")
            ntab = cur.fetchone()[0]
            conn.rollback()
            if ntab > 0:
                return conn
            print(f"  {DB} present but empty ({ntab} tables) -> rebuilding")
        except psycopg2.OperationalError as e:
            print(f"  cannot open {DB}: {str(e).strip().splitlines()[0]}")
        if attempt == 1:
            print("  rebuilding ...")
            build(verbose=True)
    raise SystemExit("could not obtain a usable madjana_test database")


def main():
    hard = build(verbose=True)
    return 1 if hard else 0


if __name__ == "__main__":
    sys.exit(main())
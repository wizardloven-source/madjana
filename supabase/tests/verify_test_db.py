#!/usr/bin/env python3
"""Verify the rebuilt madjana_test matches the shape the app and Edge expect.

Checks structural preconditions only -- no feature behaviour. If this passes,
build_test_db.py has produced a database good enough to run the sync suite on.
"""
import os
import re
import sys

import psycopg2

HOST, PORT, USER, DB = "127.0.0.1", 5433, "postgres", "madjana_test"

# tables the client and Edge read/write, by purpose
CORE_TABLES = {
    "farms": "farm records",
    "users": "app user profile",
    "user_farms": "farm membership (the 00800/00801 authorization subject)",
    "flocks": "flock registry",
    "sync_table_registry": "which tables are publishable to sync",
    "sync_changes": "append-only change log",
    "sync_conflicts": "conflict store",
    "sync_checkpoint": "per-table sync cursor",
    "inventory_items": "farm item registry (00800 flock scoping)",
    "inventory_transactions": "movements (00800 resolves farm via item)",
    "feed_consumption": "feed usage, bag-weight trigger",
    "egg_production": "production records",
    "egg_dispatch": "dispatch records",
    "revenue": "revenue records",
    "expenses": "expenses",
    "customers": "customers",
    "app_settings": "key/value settings",
}
OPTIONAL_TABLES = {
    "suppliers": "purchases",
    "purchases": "purchases",
    "payments": "customer payments",
    "customer_debt": "debt ledger",
}

FUNCS = [
    ("sync_records_batch", "00801 subject under test"),
    ("current_user_farm_id", "entry guard, single active farm"),
    ("current_user_farm_ids", "all farms for the caller"),
    ("is_system_admin", "system admin check"),
    ("has_system_admin", "system admin flag"),
    ("user_has_farm_access", "membership read check"),
    ("user_manages_farm", "manager role check"),
    ("validate_flock_farm", "flock/farm consistency"),
    ("inventory_items_flock_same_farm", "00800 inventory scoping"),
]

PASS, FAIL = "PASS", "FAIL"
results = []


def check(label, ok, detail=""):
    results.append((label, ok, detail))
    print(f"  {PASS if ok else FAIL}  {label}" + (f"  -- {detail}" if detail else ""))


def main():
    conn = psycopg2.connect(host=HOST, port=PORT, user=USER, dbname=DB,
                            password="", sslmode="disable")
    cur = conn.cursor()

    print("tables:")
    existing = set()
    cur.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
    for (t,) in cur.fetchall():
        existing.add(t)
    for t, why in CORE_TABLES.items():
        check(f"public.{t}  ({why})", t in existing)
    missing_opt = [t for t in OPTIONAL_TABLES if t not in existing]
    if missing_opt:
        print(f"  note: optional tables absent: {', '.join(sorted(missing_opt))}")

    print("\nRLS:")
    cur.execute("""SELECT c.relname FROM pg_class c
                   JOIN pg_namespace n ON n.oid=c.relnamespace
                   WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity""")
    rls_on = {r[0] for r in cur.fetchall()}
    for t in ("sync_changes", "sync_conflicts", "sync_checkpoint",
              "inventory_transactions", "inventory_items", "user_farms"):
        check(f"RLS enabled on public.{t}", t in rls_on)

    cur.execute("SELECT count(*) FROM pg_policies WHERE schemaname='public'")
    npol = cur.fetchone()[0]
    check("public RLS policies exist", npol > 0, f"{npol} policies")

    print("\nfunctions:")
    cur.execute("""SELECT proname FROM pg_proc p JOIN pg_namespace n
                   ON n.oid=p.pronamespace WHERE n.nspname='public'""")
    fns = {r[0] for r in cur.fetchall()}
    for f, why in FUNCS:
        check(f"public.{f}()  ({why})", f in fns)

    print("\n00801 contract:")
    cur.execute("""SELECT pg_get_functiondef(p.oid) FROM pg_proc p
                   JOIN pg_namespace n ON n.oid=p.pronamespace
                   WHERE n.nspname='public' AND p.proname='sync_records_batch'""")
    (defn,) = cur.fetchone()
    # comments are preserved by pg_get_functiondef, so strip them before any
    # assertion about what the function actually *executes*
    code = "\n".join(l.split("--")[0] for l in defn.splitlines())

    for needle, desc in (
        ("v_rec->>'farm_id'", "reads envelope farm_id"),
        ("v_data->>'farm_id'", "reads payload farm_id"),
        ("farm_id_source", "reports the source"),
        ("existing_row", "existing-row fallback for update/delete"),
    ):
        check(f"sync_records_batch: {desc}", needle in code)

    # payload must be resolved before envelope so a stale envelope cannot
    # override the farm the client explicitly bound the record to
    i_payload = code.find("v_data->>'farm_id'")
    i_env = code.find("v_rec->>'farm_id'")
    check("payload farm_id resolved before envelope", -1 < i_payload < i_env,
          f"payload@{i_payload} envelope@{i_env}")

    # THE assertion that matters: current_user_farm_id() may be called exactly
    # once, at function entry, as a guard. A second call inside the per-record
    # resolver would be the misfiling vulnerability this migration closes.
    n_cuf = code.count("current_user_farm_id")
    check("current_user_farm_id() called at most once (entry guard only)",
          n_cuf <= 1, f"{n_cuf} executable occurrence(s)")

    # ...and that one call must be the v_active_farm guard, not the resolver
    guard = "v_active_farm := current_user_farm_id()"
    check("the single call is the v_active_farm entry guard", guard in code)

    # the resolver itself must be exactly payload -> envelope
    resolver = re.search(
        r"v_farm\s*:=\s*COALESCE\((.*?)\);", code, re.S)
    check("per-record resolver is payload -> envelope only",
          bool(resolver)
          and "v_data->>'farm_id'" in resolver.group(1)
          and "v_rec->>'farm_id'" in resolver.group(1)
          and "current_user_farm_id" not in resolver.group(1))

    print("\nfeed bag-weight guard:")
    cur.execute("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n
                   ON n.oid=p.pronamespace WHERE n.nspname='public'
                   AND p.proname='trg_feed_consumption_bag_weight'
                   AND p.prokind='f'
                   AND pg_get_functiondef(p.oid) LIKE '%FEED_BAG_WEIGHT_MISMATCH%'""")
    check("trg_feed_consumption_bag_weight() raises FEED_BAG_WEIGHT_MISMATCH",
          cur.fetchone()[0] == 1)
    cur.execute("""SELECT count(*) FROM pg_trigger
                   WHERE tgname='feed_consumption_bag_weight' AND NOT tgisinternal""")
    check("trigger attached to feed_consumption", cur.fetchone()[0] == 1)

    print("\nstorage shim:")
    cur.execute("SELECT count(*) FROM pg_policies WHERE schemaname='storage'")
    ns = cur.fetchone()[0]
    check("storage farm-scoped policies", ns >= 3, f"{ns} policies")
    cur.execute("SELECT storage.foldername('farms/abc/mortality/x.jpg')")
    check("storage.foldername drops filename",
          cur.fetchone()[0] == ["farms", "abc", "mortality"])

    print("\nextensions:")
    cur.execute("SELECT count(*) FROM pg_extension WHERE extname='pgcrypto'")
    check("pgcrypto installed", cur.fetchone()[0] == 1)

    conn.close()

    failed = [r for r in results if not r[1]]
    print("\n" + "=" * 62)
    print(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    for label, _, detail in failed:
        print(f"  FAIL {label} {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

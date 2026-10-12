#!/usr/bin/env python3
"""W6 rollback cycles: apply -> rollback -> re-apply, three times, plus a
consolidated-rollback parity pass.

Proves that every W6 rollback (M25..M21, M1b) and the consolidated
`20261003002450_rollback_w6_all.sql` are idempotent and exactly invert the
forward migrations, and that re-applying the forward files restores the full
W6 shape (six tables, nine functions, the 24-policy RLS matrix, and
revenue.flock_id).

Runs against the LOCAL test database only -- madjana_test on 127.0.0.1:5433,
as the owning `postgres` role (ROLLBACKs need DDL rights; the SQL suites run as
test_runner instead). Never connects to Supabase.

    python supabase/tests/test_w6_rollback_cycles.py
"""
import os
import sys

import psycopg2

HERE = os.path.dirname(os.path.abspath(__file__))
SUPABASE = os.path.dirname(HERE)
MIGDIR = os.path.join(SUPABASE, "migrations")

sys.path.insert(0, HERE)
from build_test_db import apply_file  # noqa: E402

HOST, PORT, USER, DB = "127.0.0.1", 5433, "postgres", "madjana_test"

# Forward, in apply order.
FORWARD = [
    "20261003000150_revenue_flock_id.sql",
    "20261003002000_m21_partners_user_roles.sql",
    "20261003002100_m22_profit_distributions.sql",
    "20261003002200_m23_partner_withdrawals_partner_audit.sql",
    "20261003002300_m24_partner_functions.sql",
    "20261003002400_m25_partner_rls.sql",
]

# Per-milestone rollbacks, in the exact reverse order (canonical path).
RB_SEPARATE = [
    "20261003002401_rollback_m25_partner_rls.sql",
    "20261003002301_rollback_m24_partner_functions.sql",
    "20261003002201_rollback_m23_partner_withdrawals_partner_audit.sql",
    "20261003002101_rollback_m22_profit_distributions.sql",
    "20261003002001_rollback_m21_partners_user_roles.sql",
    "20261003000151_rollback_revenue_flock_id.sql",
]

RB_CONSOLIDATED = ["20261003002450_rollback_w6_all.sql"]

W6_TABLES = ["partners", "user_roles", "profit_distributions",
             "profit_distribution_details", "partner_withdrawals", "partner_audit"]
W6_FUNCS = ["partner_net_profit", "partner_pending_withdrawal", "partner_summary",
            "approve_withdrawal", "calculate_profit_distribution",
            "record_partner_audit", "guard_withdrawal_status",
            "validate_partner_withdrawal", "partner_in_manager_farm"]
EXPECTED_POLICIES = {
    "partners": 4, "user_roles": 4, "profit_distributions": 4,
    "profit_distribution_details": 4, "partner_withdrawals": 5, "partner_audit": 3,
}

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    line = ("  PASS  " if cond else "  FAIL  ") + name
    if detail and not cond:
        line += "\n         -> " + str(detail)
    print(line)


def probe(cur):
    cur.execute("""SELECT count(*) FROM pg_class c
                     JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname='public' AND c.relname = ANY(%s)""", (W6_TABLES,))
    n_tables = cur.fetchone()[0]

    cur.execute("""SELECT count(DISTINCT p.proname) FROM pg_proc p
                     JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname = ANY(%s)""", (W6_FUNCS,))
    n_funcs = cur.fetchone()[0]

    cur.execute("""SELECT count(*) FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='revenue'
                      AND column_name='flock_id'""")
    has_flock = cur.fetchone()[0] == 1

    cur.execute("""SELECT c.relname, count(p.policyname)
                     FROM pg_class c
                     JOIN pg_namespace n ON n.oid = c.relnamespace
                     LEFT JOIN pg_policies p
                            ON p.schemaname='public' AND p.tablename = c.relname
                    WHERE n.nspname='public' AND c.relname = ANY(%s)
                    GROUP BY c.relname""", (W6_TABLES,))
    pol = {row[0]: row[1] for row in cur.fetchall()}
    return n_tables, n_funcs, has_flock, pol


def apply_many(cur, filenames):
    """Apply each file statement-by-statement; return the number of failures."""
    failures = 0
    for name in filenames:
        ok, fails = apply_file(cur, os.path.join(MIGDIR, name), name, verbose_errors=3)
        if not ok:
            failures += len(fails)
    return failures


def forward_ok(cur):
    n_tables, n_funcs, has_flock, pol = probe(cur)
    problems = []
    if n_tables != 6:
        problems.append(f"tables={n_tables}/6")
    if n_funcs != 9:
        problems.append(f"functions={n_funcs}/9")
    if not has_flock:
        problems.append("revenue.flock_id missing")
    if pol != EXPECTED_POLICIES:
        problems.append(f"policies={pol} expected {EXPECTED_POLICIES}")
    return problems


def torn_down_ok(cur):
    n_tables, n_funcs, has_flock, pol = probe(cur)
    problems = []
    if n_tables != 0:
        problems.append(f"{n_tables} W6 table(s) still present")
    if n_funcs != 0:
        problems.append(f"{n_funcs} W6 function(s) still present")
    if has_flock:
        problems.append("revenue.flock_id still present")
    if sum(pol.values()) != 0:
        problems.append(f"W6 policies still present: {pol}")
    return problems


def main():
    conn = psycopg2.connect(host=HOST, port=PORT, user=USER, dbname=DB,
                            password="", sslmode="disable")
    cur = conn.cursor()
    try:
        cycles = [("separate", RB_SEPARATE)] * 3 + [("consolidated", RB_CONSOLIDATED)]
        for i, (kind, rb_files) in enumerate(cycles, 1):
            tag = f"cycle{i}[{kind}]"

            before = forward_ok(cur)
            check(f"{tag} forward state before teardown", not before, "; ".join(before))
            if before:
                break  # nothing to roll back: abandon rather than cascade noise

            fails = apply_many(cur, rb_files)
            check(f"{tag} rollback files applied with 0 errors", fails == 0,
                  f"{fails} statement failure(s)")
            down = torn_down_ok(cur)
            check(f"{tag} W6 torn down", not down, "; ".join(down))

            fails = apply_many(cur, FORWARD)
            check(f"{tag} forward files re-applied with 0 errors", fails == 0,
                  f"{fails} statement failure(s)")
            after = forward_ok(cur)
            check(f"{tag} W6 shape restored", not after, "; ".join(after))
    finally:
        conn.close()

    print(f"\n  {len(PASS)} passed, {len(FAIL)} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

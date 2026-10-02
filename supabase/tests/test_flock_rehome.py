#!/usr/bin/env python3
"""Regression suite for UPGRADE_move_flock_019d8bee_to_nadeem.sql.

Seeds the exact production ids involved in the reported misfiling
(المدجنة -> نديم بركات), runs the repair migration inside one transaction,
and asserts:

  * the flock itself moved to نديم بركات;
  * every operational record of that flock (egg_production, mortality,
    feed_consumption, feed_received, medications, opening_balances) moved;
  * customer-coupled rows (egg_dispatch / dispatch_requests) moved only when
    the customer belongs to نديم; global and المدجنة customers stayed put
    (validate_dispatch_refs rejects anything else);
  * sync_changes (UPDATE) were pushed for the moved rows, and one audit_log
    entry was written;
  * a second run is a no-op (idempotent).

Runs against the LOCAL test database only -- madjana_test on 127.0.0.1:5433.
Never connects to Supabase. Everything rolls back.

    python supabase/tests/test_flock_rehome.py
"""
import io
import os
import sys

import psycopg2

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MIG = os.path.join(ROOT, "supabase", "migrations",
                   "UPGRADE_move_flock_019d8bee_to_nadeem.sql")

HOST, PORT, USER, DB = "127.0.0.1", 5433, "postgres", "madjana_test"

FROM = "12141b73-ebee-4ab0-be31-80195b759303"   # المدجنة
TO = "ea124a67-e18f-4694-841e-e704356ffe4b"     # نديم بركات
FLOCK = "019d8bee-4b97-4fb5-b27c-9bc822443df0"
DEV = "repair-019d8bee-to-nadeem"
WORKER = "00000000-0000-0000-0000-00000000000b"

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    line = ("  PASS  " if cond else "  FAIL  ") + name
    if detail and not cond:
        line += "\n         -> " + str(detail)
    print(line)


SEED = f"""
INSERT INTO public.farms (id, name, feed_bag_weight_kg, eggs_per_carton, eggs_per_tray)
VALUES ('{FROM}', 'المدجنة', 50, 30, 360),
       ('{TO}', 'نديم بركات', 50, 30, 360)
ON CONFLICT (id) DO NOTHING;

-- ensure a worker exists for the NOT NULL FKs (idempotent; fixtures also add one)
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('{WORKER}', 'worker_a@test.local',
        '{{"role":"worker","full_name":"Test Worker A","farm_id":"00000000-0000-0000-0000-000000000001"}}')
ON CONFLICT (id) DO NOTHING;

-- customers: global + المدجنة-local + نديم-local
INSERT INTO public.customers (id, farm_id, name, phone, is_global) VALUES
  ('c1111111-0000-0000-0000-000000000001', '{FROM}', 'Global Cust', '0900', true),
  ('c1111111-0000-0000-0000-000000000002', '{FROM}', 'From Cust',   '0901', false),
  ('c1111111-0000-0000-0000-000000000003', '{TO}',   'To Cust',     '0902', false)
ON CONFLICT (id) DO NOTHING;
-- customers_scope_guard (BEFORE INSERT) forces is_global=false; fix after insert
UPDATE public.customers SET is_global = true
 WHERE id = 'c1111111-0000-0000-0000-000000000001';

INSERT INTO public.flocks (id, farm_id, breed, start_date, initial_count, current_count, status, sections_count)
VALUES ('{FLOCK}', '{FROM}', 'بياض كبير', CURRENT_DATE - 30, 1250, 1021, 'active', 1);

INSERT INTO public.egg_production (id, farm_id, flock_id, date, cartons, trays, loose_eggs, worker_id)
VALUES ('e1111111-0000-0000-0000-000000000001', '{FROM}', '{FLOCK}',
        CURRENT_DATE, 10, 5, 3, '{WORKER}');
INSERT INTO public.mortality (id, farm_id, flock_id, date, count, reason, worker_id)
VALUES ('11111111-0000-0000-0000-0000000000a1', '{FROM}', '{FLOCK}',
        CURRENT_DATE, 5, 'unknown', '{WORKER}');
INSERT INTO public.feed_consumption (id, farm_id, flock_id, date, entry_mode, quantity_kg, worker_id)
VALUES ('11111111-0000-0000-0000-0000000000a2', '{FROM}', '{FLOCK}',
        CURRENT_DATE, 'kg', 100, '{WORKER}');
INSERT INTO public.feed_received (id, farm_id, flock_id, date, entry_mode, quantity, quantity_kg, feed_type, worker_id)
VALUES ('11111111-0000-0000-0000-0000000000a3', '{FROM}', '{FLOCK}',
        CURRENT_DATE, 'kg', 100, 100, 'layer', '{WORKER}');
INSERT INTO public.medications (id, farm_id, flock_id, date, type, medicine_name, dosage, administration_route, worker_id)
VALUES ('11111111-0000-0000-0000-0000000000a4', '{FROM}', '{FLOCK}',
        CURRENT_DATE, 'vitamin', 'Vit', '1ml', 'water', '{WORKER}');
INSERT INTO public.opening_balances (id, farm_id, flock_id, initial_birds)
VALUES ('11111111-0000-0000-0000-0000000000a5', '{FROM}', '{FLOCK}', 1250);

-- egg_dispatch: global + from-local stay, to-local moves
INSERT INTO public.egg_dispatch (id, farm_id, flock_id, date, customer_id, cartons, trays, worker_id)
VALUES ('11111111-0000-0000-0000-0000000000b1', '{FROM}', '{FLOCK}', CURRENT_DATE,
        'c1111111-0000-0000-0000-000000000001', 2, 0, '{WORKER}'),
       ('11111111-0000-0000-0000-0000000000b2', '{FROM}', '{FLOCK}', CURRENT_DATE,
        'c1111111-0000-0000-0000-000000000002', 2, 0, '{WORKER}'),
       ('11111111-0000-0000-0000-0000000000b3', '{FROM}', '{FLOCK}', CURRENT_DATE,
        'c1111111-0000-0000-0000-000000000003', 2, 0, '{WORKER}');

-- dispatch_requests: global + from-local stay, NULL customer moves
INSERT INTO public.dispatch_requests (id, farm_id, flock_id, customer_id, cartons, trays)
VALUES ('11111111-0000-0000-0000-0000000000c1', '{FROM}', '{FLOCK}',
        'c1111111-0000-0000-0000-000000000001', 1, 0),
       ('11111111-0000-0000-0000-0000000000c2', '{FROM}', '{FLOCK}',
        'c1111111-0000-0000-0000-000000000002', 1, 0),
       ('11111111-0000-0000-0000-0000000000c4', '{FROM}', '{FLOCK}', NULL, 1, 0);
"""


def scalar(cur, sql, args=None):
    cur.execute(sql, args)
    row = cur.fetchone()
    return row[0] if row else None


def main():
    with io.open(MIG, encoding="utf-8") as fh:
        migration = fh.read()

    conn = psycopg2.connect(host=HOST, port=PORT, user=USER, dbname=DB,
                            password="", sslmode="disable")
    cur = conn.cursor()
    try:
        cur.execute(SEED)
        cur.execute(migration)

        check("flock moved to Nadeem",
              scalar(cur, "SELECT farm_id FROM public.flocks WHERE id=%s", (FLOCK,)) == TO)

        stayed = scalar(cur, f"""
            SELECT count(*) FROM (
                SELECT farm_id FROM public.egg_production   WHERE flock_id='{FLOCK}' AND farm_id<>'{TO}'
                UNION ALL SELECT farm_id FROM public.mortality        WHERE flock_id='{FLOCK}' AND farm_id<>'{TO}'
                UNION ALL SELECT farm_id FROM public.feed_consumption WHERE flock_id='{FLOCK}' AND farm_id<>'{TO}'
                UNION ALL SELECT farm_id FROM public.feed_received    WHERE flock_id='{FLOCK}' AND farm_id<>'{TO}'
                UNION ALL SELECT farm_id FROM public.medications      WHERE flock_id='{FLOCK}' AND farm_id<>'{TO}'
                UNION ALL SELECT farm_id FROM public.opening_balances WHERE flock_id='{FLOCK}' AND farm_id<>'{TO}'
            ) z
        """)
        check("all operational records moved", stayed == 0, f"{stayed} did not move")

        for row_id, moved in (("b1", False), ("b2", False), ("b3", True)):
            farm = scalar(cur, "SELECT farm_id FROM public.egg_dispatch WHERE id=%s",
                          (f"11111111-0000-0000-0000-0000000000{row_id}",))
            check(f"egg_dispatch {row_id} {'moved' if moved else 'stayed'}",
                  (farm == TO) == moved, farm)

        for row_id, moved in (("c1", False), ("c2", False), ("c4", True)):
            farm = scalar(cur, "SELECT farm_id FROM public.dispatch_requests WHERE id=%s",
                          (f"11111111-0000-0000-0000-0000000000{row_id}",))
            check(f"dispatch_requests {row_id} {'moved' if moved else 'stayed'}",
                  (farm == TO) == moved, farm)

        n_changes = scalar(cur, "SELECT count(*) FROM public.sync_changes WHERE farm_id=%s AND device_id=%s",
                           (TO, DEV))
        check("sync_changes pushed (9)", n_changes == 9, n_changes)

        check("audit_log entry written",
              scalar(cur, "SELECT count(*) FROM public.audit_log WHERE table_name='flocks' AND record_id=%s AND device_id=%s",
                     (FLOCK, DEV)) == 1)

        # idempotency: second run must be a no-op
        cur.execute(migration)
        n_after = scalar(cur, "SELECT count(*) FROM public.sync_changes WHERE farm_id=%s AND device_id=%s",
                         (TO, DEV))
        check("re-run is idempotent", n_after == 9, n_after)
        check("flock still Nadeem after re-run",
              scalar(cur, "SELECT farm_id FROM public.flocks WHERE id=%s", (FLOCK,)) == TO)
    finally:
        conn.rollback()
        conn.close()

    print(f"\n  {len(PASS)} passed, {len(FAIL)} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

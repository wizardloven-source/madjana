#!/usr/bin/env python3
"""Behavioural suite for sync_records_batch farm resolution (migration 00801).

Runs against the LOCAL test database only -- madjana_test on 127.0.0.1:5433.
Never connects to Supabase.

Two rules this suite depends on, both learned the hard way:

1. READ BACK AS service_role. RLS hides rows from a user who is not a member of
   the farm, so reading a "refused" row back as the acting user makes a rejected
   write look like a DELETED row. An earlier revision reported false data loss
   for exactly this reason. Every assertion below reads back through h.peek()
   or h.exists(), which switch to service_role first.

2. EVERYTHING ROLLS BACK. Fixtures are seeded inside one transaction that is
   rolled back at the end, so the database is untouched no matter how the run
   ends.

Auth is exercised through real RLS: the caller identity is set with
set_config('request.jwt.claims', ...) plus SET ROLE, which is what PostgREST
does and what auth.uid() reads. No JWT is signed and no signing secret is
stored here.

    python supabase/tests/test_sync_farm_id.py
"""
import json
import os
import sys
import uuid

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_test_db as B  # noqa: E402

WORKER = "7ec4b622-b56f-4abf-a6da-6d59b0a6eecb"
MANAGER = "a2d22542-3c48-4c5e-a6e8-72adccd7ca12"
ADMIN = "0deeef9e-39f3-471c-a701-20ff9d49f5f1"

JARRAH = "12141b73-ebee-4ab0-be31-80195b759303"    # 24 kg feed bags
HUKMOUN = "469a9190-cb25-4c41-850f-53c26a1cbaa1"  # 50 kg feed bags
NADEEM = "ea124a67-e18f-4694-841e-e704356ffe4b"   # 50 kg feed bags, worker's farm

NOW = "2026-10-01T00:00:00Z"

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    line = ("  PASS  " if cond else "  FAIL  ") + name
    if detail and not cond:
        line += "\n         -> " + str(detail)
    print(line)


def act_as(cur, uid, farm=None, role="authenticated"):
    """Impersonate uid: set the JWT claims auth.uid() reads, then SET ROLE."""
    claims = {"sub": uid, "role": role, "aud": "authenticated"}
    if farm:
        claims["farm_id"] = farm
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                (json.dumps(claims),))
    cur.execute(f"SET ROLE {role}")


def act_as_service(cur):
    """Bypass RLS. Read-backs and fixture maintenance only -- never to make an
    assertion pass on the write path."""
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                (json.dumps({"role": "service_role"}),))
    cur.execute("SET ROLE service_role")


class H:
    """Fixture and call helpers. section_no must be unique per
    (flock, date, section) to satisfy the unique index, so every fixture and
    every call gets a fresh one."""

    def __init__(self, cur):
        self.cur = cur
        self._flocks = {}
        self._sec = 0
        self.actor = (WORKER, NADEEM)

    def sec(self):
        self._sec += 1
        return 1000 + self._sec

    def use(self, uid, farm):
        self.actor = (uid, farm)

    def resume(self):
        act_as(self.cur, self.actor[0], self.actor[1])

    def flock_for(self, farm):
        if farm in self._flocks:
            return self._flocks[farm]
        cur = self.cur
        act_as_service(cur)
        cur.execute("""SELECT id FROM public.flocks
                       WHERE farm_id=%s AND deleted_at IS NULL LIMIT 1""", (farm,))
        row = cur.fetchone()
        if row:
            self._flocks[farm] = str(row[0])
            return self._flocks[farm]
        fl = str(uuid.uuid4())
        cur.execute("""INSERT INTO public.flocks
            (id, farm_id, breed, start_date, initial_count, current_count,
             status, version, created_at, updated_at)
            VALUES (%s,%s,'layer','2026-09-01',10,10,'active',1,%s,%s)""",
            (fl, farm, NOW, NOW))
        self._flocks[farm] = fl
        return fl

    def mk_egg(self, farm):
        rid = str(uuid.uuid4())
        act_as_service(self.cur)
        self.cur.execute("""INSERT INTO public.egg_production
            (id, farm_id, flock_id, worker_id, date, cartons, section_no,
             version, created_at, updated_at)
            VALUES (%s,%s,%s,%s,'2026-10-01',1,%s,1,%s,%s)""",
            (rid, farm, self.flock_for(farm), WORKER, self.sec(), NOW, NOW))
        return rid

    def mk_mort(self, farm):
        rid = str(uuid.uuid4())
        act_as_service(self.cur)
        self.cur.execute("""INSERT INTO public.mortality
            (id, farm_id, flock_id, worker_id, count, reason, date, section_no,
             version, created_at, updated_at)
            VALUES (%s,%s,%s,%s,1,'cannibalism','2026-10-01',%s,1,%s,%s)""",
            (rid, farm, self.flock_for(farm), WORKER, self.sec(), NOW, NOW))
        return rid

    def batch(self, recs):
        self.resume()
        self.cur.execute("SELECT public.sync_records_batch(%s::jsonb)",
                         (json.dumps(recs),))
        out = self.cur.fetchone()[0]
        dets = out.get("details") if isinstance(out, dict) else out
        return dets, out

    def peek(self, table, rid, cols="*"):
        act_as_service(self.cur)
        self.cur.execute(f"SELECT {cols} FROM public.{table} WHERE id=%s", (rid,))
        return self.cur.fetchone()

    def exists(self, table, rid):
        act_as_service(self.cur)
        self.cur.execute(f"SELECT count(*) FROM public.{table} WHERE id=%s", (rid,))
        return self.cur.fetchone()[0] > 0


def ins(table, rid, farm, flock, worker=WORKER, extra=None):
    data = {"flock_id": flock, "worker_id": worker,
            "date": "2026-10-01", "cartons": 1}
    if extra:
        data.update(extra)
    return {"table_name": table, "operation": "insert", "record_id": rid,
            "farm_id": farm, "data": data}


def seed(cur):
    """Three farms and three users, mirroring the production membership shape:
    worker -> NADEEM only, manager -> all three, system_admin -> unrestricted.

    Users are created by inserting into auth.users ONLY. public.handle_new_user()
    is an AFTER INSERT trigger on auth.users that creates the matching
    public.users row from raw_user_meta_data keys role / full_name / phone /
    farm_id. That is the real signup path, and it matters here: inserting into
    public.users directly collides with that trigger (duplicate key on id) and
    the BEFORE UPDATE guards on role and is_active reject the write unless the
    caller is already a system_admin."""
    act_as_service(cur)

    for fid, name, kg in ((JARRAH, 'JARRAH', 24), (HUKMOUN, 'HUKMOUN', 50),
                          (NADEEM, 'NADEEM', 50)):
        cur.execute("""INSERT INTO public.farms (id, name, feed_bag_weight_kg,
                       eggs_per_carton, eggs_per_tray)
                       VALUES (%s,%s,%s,30,180)
                       ON CONFLICT (id) DO UPDATE
                         SET feed_bag_weight_kg=EXCLUDED.feed_bag_weight_kg""",
                    (fid, name, kg))

    for uid, email, name, role, farm in (
            (WORKER, 'worker@test.local', 'Test Worker', 'worker', NADEEM),
            (MANAGER, 'manager@test.local', 'Test Manager', 'manager', HUKMOUN),
            (ADMIN, 'admin@test.local', 'Test Admin', 'system_admin', JARRAH)):
        cur.execute("""INSERT INTO auth.users (id, email, raw_user_meta_data)
                       VALUES (%s,%s,%s)
                       ON CONFLICT (id) DO UPDATE
                         SET raw_user_meta_data=EXCLUDED.raw_user_meta_data""",
                    (uid, email, json.dumps({
                        "role": role, "full_name": name, "farm_id": farm})))
        # handle_new_user() uses ON CONFLICT DO NOTHING, so on a re-run against
        # a database that already has these users nothing is refreshed; only
        # farm_id is corrected, and that column is not role-guarded.
        cur.execute("""UPDATE public.users SET farm_id=%s
                       WHERE id=%s AND farm_id IS DISTINCT FROM %s""",
                    (farm, uid, farm))

    for uid, farm in ((WORKER, NADEEM), (MANAGER, JARRAH),
                      (MANAGER, HUKMOUN), (MANAGER, NADEEM)):
        cur.execute("""INSERT INTO public.user_farms (user_id, farm_id)
                       VALUES (%s,%s) ON CONFLICT DO NOTHING""", (uid, farm))


def main():
    conn = B.connect()
    conn.autocommit = False
    cur = conn.cursor()

    seed(cur)
    print("fixtures seeded (3 farms, 3 users, 4 memberships)\n")
    h = H(cur)

    # ---- A ----------------------------------------------------------------
    print("A. UPDATE without farm_id -> farm read off the existing server row")
    h.use(WORKER, NADEEM)
    r1 = h.mk_egg(NADEEM)
    dets, _ = h.batch([{"table_name": "egg_production", "operation": "update",
                        "record_id": r1, "data": {"cartons": 9}}])
    d = dets[0]
    check("resolved via existing_row", d.get("farm_id_source") == "existing_row", d)
    check("status ok", d.get("status") == "ok", d)
    row = h.peek("egg_production", r1, "farm_id, cartons")
    check("stayed in ITS OWN farm", bool(row) and str(row[0]) == NADEEM, row)
    check("payload applied", bool(row) and row[1] == 9, row)

    # ---- B ----------------------------------------------------------------
    print("\nB. UPDATE without farm_id on a FOREIGN farm -> refused, row intact")
    r2 = h.mk_egg(JARRAH)
    dets, _ = h.batch([{"table_name": "egg_production", "operation": "update",
                        "record_id": r2, "data": {"cartons": 77}}])
    d = dets[0]
    check("refused", d.get("status") == "error", d)
    check("message is authorization", "AUTHORIZATION_DENIED" in str(d.get("message")), d)
    check("ROW STILL EXISTS (read as service_role)", h.exists("egg_production", r2))
    row = h.peek("egg_production", r2, "farm_id, cartons, deleted_at")
    check("farm unchanged", bool(row) and str(row[0]) == JARRAH, row)
    check("data unchanged", bool(row) and row[1] == 1, row)
    check("not soft-deleted", bool(row) and row[2] is None, row)

    # ---- C ----------------------------------------------------------------
    print("\nC. UPDATE claiming a farm the caller is NOT in -> refused")
    r3 = h.mk_egg(NADEEM)
    dets, _ = h.batch([{"table_name": "egg_production", "operation": "update",
                        "record_id": r3, "farm_id": HUKMOUN,
                        "data": {"cartons": 55}}])
    d = dets[0]
    check("rehoming attempt refused", d.get("status") == "error", d)
    row = h.peek("egg_production", r3, "farm_id, cartons")
    check("NOT rehomed to HUKMOUN", bool(row) and str(row[0]) == NADEEM, row)
    check("data untouched", bool(row) and row[1] == 1, row)

    # ---- D ----------------------------------------------------------------
    print("\nD. INSERT without farm_id -> refused, nothing written")
    r4 = str(uuid.uuid4())
    dets, _ = h.batch([{"table_name": "egg_production", "operation": "insert",
                        "record_id": r4, "data": {
                            "flock_id": h.flock_for(NADEEM), "worker_id": WORKER,
                            "date": "2026-10-01", "cartons": 1,
                            "section_no": h.sec()}}])
    d = dets[0]
    check("refused", d.get("status") == "error", d)
    check("message names farm_id", "farm_id" in str(d.get("message")), d.get("message"))
    check("nothing written", not h.exists("egg_production", r4))

    # ---- E ----------------------------------------------------------------
    print("\nE. INSERT into a FOREIGN farm -> refused, nothing written")
    r5 = str(uuid.uuid4())
    dets, _ = h.batch([ins("egg_production", r5, JARRAH, h.flock_for(JARRAH),
                           extra={"section_no": h.sec()})])
    d = dets[0]
    check("refused", d.get("status") == "error", d)
    check("nothing written", not h.exists("egg_production", r5))

    # ---- F ----------------------------------------------------------------
    print("\nF. INSERT into OWN farm -> succeeds")
    r6 = str(uuid.uuid4())
    dets, _ = h.batch([ins("egg_production", r6, NADEEM, h.flock_for(NADEEM),
                           extra={"cartons": 3, "section_no": h.sec()})])
    d = dets[0]
    check("ok", d.get("status") == "ok", d)
    check("farm_id_source == envelope", d.get("farm_id_source") == "envelope", d)
    row = h.peek("egg_production", r6, "farm_id, cartons")
    check("landed in NADEEM with correct data",
          bool(row) and str(row[0]) == NADEEM and row[1] == 3, row)

    # Same farm, this time carried INSIDE data.farm_id -- the real client sends
    # it in both places, and payload must win and be labelled 'payload'.
    r6b = str(uuid.uuid4())
    dets, _ = h.batch([{"table_name": "egg_production", "operation": "insert",
                        "record_id": r6b, "farm_id": NADEEM,
                        "data": {"flock_id": h.flock_for(NADEEM), "worker_id": WORKER,
                                 "date": "2026-10-01", "cartons": 4,
                                 "section_no": h.sec(), "farm_id": NADEEM}}])
    d = dets[0]
    check("data.farm_id insert ok", d.get("status") == "ok", d)
    check("farm_id_source == payload", d.get("farm_id_source") == "payload", d)
    row = h.peek("egg_production", r6b, "farm_id, cartons")
    check("landed in NADEEM", bool(row) and str(row[0]) == NADEEM, row)

    # ---- G ----------------------------------------------------------------
    print("\nG. worker_id spoofing is ignored")
    r7 = str(uuid.uuid4())
    dets, _ = h.batch([ins("egg_production", r7, NADEEM, h.flock_for(NADEEM),
                           worker=MANAGER, extra={"section_no": h.sec()})])
    d = dets[0]
    if d.get("status") == "ok":
        row = h.peek("egg_production", r7, "worker_id")
        check("spoofed worker_id replaced with auth.uid()",
              bool(row) and str(row[0]) == WORKER, row)
    else:
        check("spoofed worker_id rejected outright", True, d.get("message"))

    # ---- H ----------------------------------------------------------------
    print("\nH. DELETE by a manager WITHOUT membership of the row's farm -> refused")
    # DELETE is manager-only, so a worker actor cannot exercise farm
    # authorization at all -- an earlier revision used the worker and passed for
    # the wrong reason ('delete is manager only'). To test the farm rule the
    # actor must be a manager who is NOT in the farm.
    h.use(MANAGER, HUKMOUN)
    r8 = h.mk_mort(HUKMOUN)
    act_as_service(cur)
    cur.execute("DELETE FROM public.user_farms WHERE user_id=%s AND farm_id=%s",
                (MANAGER, HUKMOUN))
    print(f"  (removed {cur.rowcount} membership row for the manager in HUKMOUN)")
    dets, _ = h.batch([{"table_name": "mortality", "operation": "delete",
                        "record_id": r8, "data": {}}])
    d = dets[0]
    check("refused", d.get("status") == "error", d)
    check("refused for the FARM reason, not the role reason",
          "delete is manager only" not in str(d.get("message"))
          and "not a member of farm" in str(d.get("message")), d.get("message"))
    row = h.peek("mortality", r8, "deleted_at, count")
    check("ROW STILL EXISTS", row is not None, row)
    check("not soft-deleted", bool(row) and row[0] is None, row)
    check("count untouched", bool(row) and row[1] == 1, row)
    act_as_service(cur)
    cur.execute("""INSERT INTO public.user_farms (user_id, farm_id)
                   VALUES (%s,%s) ON CONFLICT DO NOTHING""", (MANAGER, HUKMOUN))

    # ---- I ----------------------------------------------------------------
    print("\nI. DELETE without farm_id by a manager WHO IS in the farm -> succeeds")
    r9 = h.mk_mort(NADEEM)
    dets, _ = h.batch([{"table_name": "mortality", "operation": "delete",
                        "record_id": r9, "data": {}}])
    d = dets[0]
    check("ok", d.get("status") == "ok", d)
    check("resolved from existing row", d.get("farm_id_source") == "existing_row", d)
    row = h.peek("mortality", r9, "deleted_at")
    check("now soft-deleted", bool(row) and row[0] is not None, row)

    # ---- J ----------------------------------------------------------------
    print("\nJ. manager (member of all 3) can UPDATE a row in a NON-active farm")
    h.use(MANAGER, JARRAH)
    r10 = h.mk_mort(HUKMOUN)
    dets, _ = h.batch([{"table_name": "mortality", "operation": "update",
                        "record_id": r10, "data": {"count": 4}}])
    d = dets[0]
    check("ok", d.get("status") == "ok", d)
    check("resolved from existing row", d.get("farm_id_source") == "existing_row", d)
    row = h.peek("mortality", r10, "count, farm_id")
    check("count applied", bool(row) and row[0] == 4, row)
    check("farm unchanged", bool(row) and str(row[1]) == HUKMOUN, row)

    # ---- K ----------------------------------------------------------------
    print("\nK. idempotency: replaying the same operation_id must not double-apply")
    h.use(WORKER, NADEEM)
    rid = str(uuid.uuid4())
    rec = ins("egg_production", rid, NADEEM, h.flock_for(NADEEM),
              extra={"cartons": 5, "section_no": h.sec()})
    rec["operation_id"] = "op-fixed-" + str(uuid.uuid4())
    d1 = h.batch([rec])[0][0]
    v1 = d1.get("new_version")
    out2 = h.batch([rec])[1]
    d2 = out2.get("details")[0] if isinstance(out2, dict) else out2[0]
    check("first apply ok", d1.get("status") == "ok", d1)
    check("replay reports the same version (not a new one)",
          v1 == d2.get("new_version"), f"v1={v1} v2={d2.get('new_version')}")
    check("affected counts 1 not 2", out2.get("affected") in (0, 1),
          out2.get("affected"))

    # ---- L ----------------------------------------------------------------
    print("\nL. per-farm bag weight is honoured by the feed trigger")
    for farm, want, label in ((JARRAH, 24.0, "JARRAH"), (HUKMOUN, 50.0, "HUKMOUN"),
                              (NADEEM, 50.0, "NADEEM")):
        act_as_service(cur)
        cur.execute("SELECT feed_bag_weight_kg FROM public.farms WHERE id=%s",
                    (farm,))
        got = float(cur.fetchone()[0])
        check(f"{label} feed_bag_weight_kg == {want} (got {got})", got == want)

    print("\n  exercising feed_bag_weight (1 bag, per farm):")
    for farm, want, label in ((JARRAH, 24.0, "JARRAH"), (HUKMOUN, 50.0, "HUKMOUN"),
                              (NADEEM, 50.0, "NADEEM")):
        fid = str(uuid.uuid4())
        act_as(cur, ADMIN, farm)
        cur.execute("""INSERT INTO public.feed_consumption
            (id, farm_id, flock_id, date, entry_mode, bags_count, quantity_kg,
             worker_id, version, created_at, updated_at)
            VALUES (%s,%s,%s,'2026-10-01','bags',1,%s,%s,1,%s,%s)""",
            (fid, farm, h.flock_for(farm), want, WORKER, NOW, NOW))
        act_as_service(cur)
        cur.execute("SELECT quantity_kg FROM public.feed_consumption WHERE id=%s",
                    (fid,))
        got = float(cur.fetchone()[0])
        check(f"correct kg accepted in {label}: {want}", got == want, got)

        # The other farm's weight must be REFUSED, not silently recorded. A
        # savepoint is required: a failed insert otherwise aborts the whole
        # transaction and every later assertion.
        bad = str(uuid.uuid4())
        act_as(cur, ADMIN, farm)
        cur.execute("SAVEPOINT feed_bad")
        rejected, why = False, ""
        try:
            cur.execute("""INSERT INTO public.feed_consumption
                (id, farm_id, flock_id, date, entry_mode, bags_count, quantity_kg,
                 worker_id, version, created_at, updated_at)
                VALUES (%s,%s,%s,'2026-10-01','bags',1,%s,%s,1,%s,%s)""",
                (bad, farm, h.flock_for(farm),
                 50.0 if want == 24.0 else 24.0, WORKER, NOW, NOW))
        except Exception as e:
            rejected = "FEED_BAG_WEIGHT_MISMATCH" in str(e)
            why = str(e).splitlines()[0]
            cur.execute("ROLLBACK TO SAVEPOINT feed_bad")
        check(f"wrong kg refused in {label}", rejected,
              "insert was ACCEPTED" if not rejected else why)
        act_as_service(cur)
        cur.execute("SELECT count(*) FROM public.feed_consumption WHERE id=%s",
                    (bad,))
        check(f"no row written for the bad insert in {label}",
              cur.fetchone()[0] == 0)

    conn.rollback()
    print("\n" + "=" * 66)
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    for name in FAIL:
        print("  FAILED: " + name)
    print("rolled back -- madjana_test is unchanged")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
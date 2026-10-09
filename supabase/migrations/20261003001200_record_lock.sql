-- ============================================================================
-- M13: record_lock — hard server-side record locks + unlock requests
-- ============================================================================
-- WHY
--   The farm closes "book" days: financial records (payments, expenses,
--   revenue) get a night audit, and egg_production / mortality /
--   feed_consumption get a 48-hour production lock while the day's numbers
--   are verified. Nothing in the DB stopped a manager (or a sync batch, or a
--   support edit) from mutating a record while that check runs.
--
--   M13 adds a hard lock: WHILE a record_lock row for
--   (table_name, record_id) is open (locked_until > now()), every UPDATE and
--   every DELETE on that row FAILS server-side with a clear Arabic message —
--   from any path: worker app, manager app, sync_records_batch, or direct
--   SQL. The lock MUST fail closed rather than silently allow, because these
--   are exactly the records a copied/duplicated edit would corrupt.
--
--   record_unlock_requests is the escape hatch: a worker who cannot edit a
--   locked record files a request that the manager approves/rejects. No
--   request = the lock stands until locked_until expires.
--
-- SCOPE
--   * creates record_lock + record_unlock_requests (server-side, NOT in
--     sync_table_registry — locks are control state, never replicated)
--   * installs ONE trigger function + ONE BEFORE UPDATE OR DELETE trigger on
--     the six lockable tables: payments, expenses, revenue,
--     egg_production, mortality, feed_consumption
--   * does NOT touch those tables' data or existing RLS
--
-- SECURITY NOTES
--   * assert_record_not_locked() is SECURITY DEFINER **on purpose**: a worker
--     cannot read record_lock (manager/admin only), yet a worker's UPDATE on
--     a locked row must still be refused. Reading the lock list under the
--     caller's RLS would make the block invisible to exactly the session that
--     needs to hit it.
--   * RLS: managers + system_admin may read/write locks; every farm member
--     may file an unlock request and read their own; only managers/admin may
--     decide.
--   * FKs: farm_id -> farms RESTRICT; user references SET NULL; no CASCADE.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) record_lock ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.record_lock (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name   text NOT NULL
                 CHECK (table_name IN
                        ('payments','expenses','revenue',
                         'egg_production','mortality','feed_consumption')),
    record_id    uuid NOT NULL,
    farm_id      uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    locked_by    uuid REFERENCES public.users(id) ON DELETE SET NULL,
    locked_at    timestamptz NOT NULL DEFAULT now(),
    locked_until timestamptz NOT NULL,
    lock_type    text NOT NULL DEFAULT 'financial'
                 CHECK (lock_type IN ('financial','production')),
    reason       text,
    UNIQUE (table_name, record_id)
);

CREATE INDEX IF NOT EXISTS idx_record_lock_lookup
    ON public.record_lock (table_name, record_id, farm_id);

-- ── 2) record_unlock_requests ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.record_unlock_requests (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id         uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    lock_id         uuid NOT NULL REFERENCES public.record_lock(id) ON DELETE RESTRICT,
    requested_by    uuid REFERENCES public.users(id) ON DELETE SET NULL,
    requested_at    timestamptz NOT NULL DEFAULT now(),
    reason          text,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','rejected')),
    reviewed_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
    reviewed_at     timestamptz,
    rejection_reason text
);

CREATE INDEX IF NOT EXISTS idx_record_unlock_lookup
    ON public.record_unlock_requests (status, farm_id);

-- ── 3) the hard-block trigger function ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assert_record_not_locked()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m13$
DECLARE
    v_record_uuid uuid;
    v_farm_uuid   uuid;
    v_until       timestamptz;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_record_uuid := OLD.id;
        v_farm_uuid   := OLD.farm_id;
    ELSE
        v_record_uuid := NEW.id;
        v_farm_uuid   := NEW.farm_id;
    END IF;

    SELECT rl.locked_until
      INTO v_until
      FROM public.record_lock rl
     WHERE rl.table_name    = TG_TABLE_NAME
       AND rl.record_id     = v_record_uuid
       AND rl.farm_id       = v_farm_uuid
       AND rl.locked_until  > now()
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'RECORD_LOCKED: سجل % في جدول % محمي بقفل حتى %. اطلب فتحا من المدير.',
            v_record_uuid, TG_TABLE_NAME, v_until;
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$m13$;

-- ── 4) one guard trigger per lockable table ──────────────────────────────────
DROP TRIGGER IF EXISTS payments_lock_guard ON public.payments;
CREATE TRIGGER payments_lock_guard
    BEFORE UPDATE OR DELETE ON public.payments
    FOR EACH ROW EXECUTE FUNCTION public.assert_record_not_locked();

DROP TRIGGER IF EXISTS expenses_lock_guard ON public.expenses;
CREATE TRIGGER expenses_lock_guard
    BEFORE UPDATE OR DELETE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.assert_record_not_locked();

DROP TRIGGER IF EXISTS revenue_lock_guard ON public.revenue;
CREATE TRIGGER revenue_lock_guard
    BEFORE UPDATE OR DELETE ON public.revenue
    FOR EACH ROW EXECUTE FUNCTION public.assert_record_not_locked();

DROP TRIGGER IF EXISTS egg_production_lock_guard ON public.egg_production;
CREATE TRIGGER egg_production_lock_guard
    BEFORE UPDATE OR DELETE ON public.egg_production
    FOR EACH ROW EXECUTE FUNCTION public.assert_record_not_locked();

DROP TRIGGER IF EXISTS mortality_lock_guard ON public.mortality;
CREATE TRIGGER mortality_lock_guard
    BEFORE UPDATE OR DELETE ON public.mortality
    FOR EACH ROW EXECUTE FUNCTION public.assert_record_not_locked();

DROP TRIGGER IF EXISTS feed_consumption_lock_guard ON public.feed_consumption;
CREATE TRIGGER feed_consumption_lock_guard
    BEFORE UPDATE OR DELETE ON public.feed_consumption
    FOR EACH ROW EXECUTE FUNCTION public.assert_record_not_locked();

-- ── 5) RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE public.record_lock ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS record_lock_manager_all ON public.record_lock;
CREATE POLICY record_lock_manager_all ON public.record_lock
    FOR ALL
    USING (public.user_manages_farm(farm_id) OR public.is_system_admin())
    WITH CHECK (public.user_manages_farm(farm_id) OR public.is_system_admin());

ALTER TABLE public.record_unlock_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS record_unlock_select ON public.record_unlock_requests;
CREATE POLICY record_unlock_select ON public.record_unlock_requests
    FOR SELECT
    USING (public.user_manages_farm(farm_id)
           OR public.is_system_admin()
           OR requested_by = auth.uid());

DROP POLICY IF EXISTS record_unlock_insert ON public.record_unlock_requests;
CREATE POLICY record_unlock_insert ON public.record_unlock_requests
    FOR INSERT
    WITH CHECK (public.user_has_farm_access(farm_id));

DROP POLICY IF EXISTS record_unlock_manage ON public.record_unlock_requests;
CREATE POLICY record_unlock_manage ON public.record_unlock_requests
    FOR UPDATE
    USING (public.user_manages_farm(farm_id) OR public.is_system_admin());

DROP POLICY IF EXISTS record_unlock_delete ON public.record_unlock_requests;
CREATE POLICY record_unlock_delete ON public.record_unlock_requests
    FOR DELETE
    USING (public.is_system_admin());

-- ── 6) grants: authenticated carries SELECT/INSERT/UPDATE/DELETE, RLS gates ──
REVOKE ALL ON TABLE public.record_lock FROM PUBLIC;
REVOKE ALL ON TABLE public.record_lock FROM anon;
REVOKE ALL ON TABLE public.record_lock FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.record_lock TO authenticated;

REVOKE ALL ON TABLE public.record_unlock_requests FROM PUBLIC;
REVOKE ALL ON TABLE public.record_unlock_requests FROM anon;
REVOKE ALL ON TABLE public.record_unlock_requests FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.record_unlock_requests TO authenticated;

REVOKE EXECUTE ON FUNCTION public.assert_record_not_locked() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_record_not_locked() TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m13$
DECLARE
    v_n    int;
    v_gaps int;
    v_rls  boolean;
BEGIN
    SELECT count(*) INTO v_n FROM pg_policies p
     WHERE p.schemaname='public' AND p.tablename IN ('record_lock','record_unlock_requests');
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FAIL: expected 5 RLS policies on record_lock set, found %', v_n;
    END IF;

    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='record_lock';
    IF NOT v_rls THEN
        RAISE EXCEPTION 'FAIL: record_lock RLS not enabled';
    END IF;

    -- six guard triggers on the six lockable tables
    SELECT count(*) INTO v_n
      FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public'
       AND t.tgname IN ('payments_lock_guard','expenses_lock_guard',
                        'revenue_lock_guard','egg_production_lock_guard',
                        'mortality_lock_guard','feed_consumption_lock_guard')
       AND NOT t.tgisinternal;
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'FAIL: expected 6 lock guard triggers, found %', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname='assert_record_not_locked' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: assert_record_not_locked not SECURITY DEFINER';
    END IF;

    -- tables are not in the sync registry (control state)
    SELECT count(*) INTO v_n FROM public.sync_table_registry
     WHERE table_name IN ('record_lock','record_unlock_requests');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: record_lock tables must not be synced (found % rows)', v_n;
    END IF;

    -- FK rules: farm_id RESTRICT, user refs never CASCADE
    SELECT count(*) INTO v_gaps FROM (
        SELECT conname FROM pg_constraint
         WHERE conrelid IN ('public.record_lock'::regclass,
                            'public.record_unlock_requests'::regclass)
           AND contype='f' AND confdeltype='c'
    ) x;
    IF v_gaps <> 0 THEN
        RAISE EXCEPTION 'FAIL: FK with ON DELETE CASCADE on record_lock set';
    END IF;

    RAISE NOTICE 'OK: M13 verified - locks, unlock requests, guard triggers, grants live';
END;
$m13$;
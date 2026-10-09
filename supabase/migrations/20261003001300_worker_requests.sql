-- ============================================================================
-- M14: change_requests — worker requests that only a manager may approve
-- ============================================================================
-- WHY
--   Workers record daily operations but financial decisions (a new expense,
--   editing/deleting a record, adjusting a dispatch, an adjustment invoice)
--   belong to the manager. Today a worker who sees a mistake has no sanctioned
--   path to propose a fix: the app either hides the controls or the worker
--   edits with no approval trail. M14 gives the DB the missing contract:
--
--     change_requests (named from the role it plays in the work order below;
--     the audit doc calls it "الطلبات" / C.4.1) is a SYNCED table:
--       * the worker INSERTs a request on device (offline-safe) with the
--         proposed payload; version + sync_status + the four sync triggers
--         make it reach the farm like every other table.
--       * the manager reads the farm's requests, then UPDATEs status to
--         approved/rejected with a note. W6 wires the "apply on approve"
--         side; M14 ships the storage + permission layer only.
--
-- SCOPE
--   * creates change_requests + sync plumbing (registry row, four triggers)
--   * RLS: every farm member may read; a member may INSERT only their own;
--     only managers/system_admin may UPDATE (decide) or DELETE.
--   * does NOT touch dispatch_requests (the app's current delivery carrier);
--     the two coexist — W6 switches the app over.
--
-- SECURITY NOTES
--   * requested_by is forced to auth.uid() by the INSERT policy (WITH CHECK),
--     so a member can never file a request in someone else's name.
--   * farm_id->farms RESTRICT, flock_id->flocks RESTRICT, user refs SET NULL.
--   * sync_status CHECK mirrors every production synced table.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) the table ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.change_requests (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id          uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    flock_id         uuid REFERENCES public.flocks(id) ON DELETE RESTRICT,
    kind             text NOT NULL
                     CHECK (kind IN ('expense','edit_record','delete_record',
                                     'dispatch_adjust','adjustment_invoice')),
    status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','approved','rejected')),
    requested_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
    payload          jsonb NOT NULL,
    original_snapshot jsonb,
    reason           text,
    decided_by       uuid REFERENCES public.users(id) ON DELETE SET NULL,
    decided_at       timestamptz,
    decision_note    text,
    version          bigint NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,
    sync_status      text NOT NULL DEFAULT 'pending'
                     CHECK (sync_status IN ('pending','synced','dirty','syncing','error'))
);

CREATE INDEX IF NOT EXISTS idx_change_requests_farm_status
    ON public.change_requests (farm_id, status);
CREATE INDEX IF NOT EXISTS idx_change_requests_requested_by
    ON public.change_requests (requested_by, status);

-- ── 2) sync plumbing ─────────────────────────────────────────────────────────
INSERT INTO public.sync_table_registry (table_name, sort_order) VALUES
    ('change_requests', 210)
ON CONFLICT (table_name) DO UPDATE
    SET sort_order = EXCLUDED.sort_order
    WHERE sync_table_registry.sort_order IS DISTINCT FROM EXCLUDED.sort_order;

DROP TRIGGER IF EXISTS change_requests_sync_insert ON public.change_requests;
CREATE TRIGGER change_requests_sync_insert
    AFTER INSERT ON public.change_requests
    FOR EACH ROW EXECUTE FUNCTION public.populate_sync_changes();

DROP TRIGGER IF EXISTS change_requests_sync_update ON public.change_requests;
CREATE TRIGGER change_requests_sync_update
    AFTER UPDATE ON public.change_requests
    FOR EACH ROW EXECUTE FUNCTION public.populate_sync_changes();

DROP TRIGGER IF EXISTS change_requests_tombstone ON public.change_requests;
CREATE TRIGGER change_requests_tombstone
    AFTER DELETE ON public.change_requests
    FOR EACH ROW EXECUTE FUNCTION public.sync_tombstone_after_delete();

DROP TRIGGER IF EXISTS change_requests_updated_at ON public.change_requests;
CREATE TRIGGER change_requests_updated_at
    BEFORE UPDATE ON public.change_requests
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ── 3) RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE public.change_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS change_requests_select ON public.change_requests;
CREATE POLICY change_requests_select ON public.change_requests
    FOR SELECT
    USING (public.user_has_farm_access(farm_id));

DROP POLICY IF EXISTS change_requests_insert ON public.change_requests;
CREATE POLICY change_requests_insert ON public.change_requests
    FOR INSERT
    WITH CHECK (public.user_has_farm_access(farm_id)
                AND requested_by = auth.uid());

DROP POLICY IF EXISTS change_requests_update ON public.change_requests;
CREATE POLICY change_requests_update ON public.change_requests
    FOR UPDATE
    USING (public.user_manages_farm(farm_id) OR public.is_system_admin());

DROP POLICY IF EXISTS change_requests_delete ON public.change_requests;
CREATE POLICY change_requests_delete ON public.change_requests
    FOR DELETE
    USING (public.user_manages_farm(farm_id) OR public.is_system_admin());

-- ── 4) grants ────────────────────────────────────────────────────────────────
REVOKE ALL ON TABLE public.change_requests FROM PUBLIC;
REVOKE ALL ON TABLE public.change_requests FROM anon;
REVOKE ALL ON TABLE public.change_requests FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.change_requests TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m14$
DECLARE
    v_n      int;
    v_order  int;
    v_trg    int;
BEGIN
    -- registry row present and after its parent (flocks)
    SELECT count(*) INTO v_n FROM public.sync_table_registry
     WHERE table_name = 'change_requests';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: change_requests missing from sync_table_registry';
    END IF;

    SELECT sort_order INTO v_order FROM public.sync_table_registry
     WHERE table_name='change_requests';
    IF v_order < (SELECT sort_order FROM public.sync_table_registry WHERE table_name='flocks') THEN
        RAISE EXCEPTION 'FAIL: change_requests ordered before its parent flocks';
    END IF;

    -- the four sync triggers
    SELECT count(*) INTO v_trg
      FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='change_requests'
       AND t.tgname IN ('change_requests_sync_insert','change_requests_sync_update',
                        'change_requests_tombstone','change_requests_updated_at')
       AND NOT t.tgisinternal;
    IF v_trg <> 4 THEN
        RAISE EXCEPTION 'FAIL: expected 4 change_requests sync triggers, found %', v_trg;
    END IF;

    -- the four RLS policies
    SELECT count(*) INTO v_n FROM pg_policies p
     WHERE p.schemaname='public' AND p.tablename='change_requests';
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FAIL: expected 4 change_requests policies, found %', v_n;
    END IF;

    -- FK rules: no CASCADE anywhere
    SELECT count(*) INTO v_n FROM pg_constraint
     WHERE conrelid='public.change_requests'::regclass
       AND contype='f' AND confdeltype='c';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: change_requests has a CASCADE FK';
    END IF;

    RAISE NOTICE 'OK: M14 verified - change_requests table, sync, RLS, grants live';
END;
$m14$;
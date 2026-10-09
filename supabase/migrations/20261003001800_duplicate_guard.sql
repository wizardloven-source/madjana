-- ============================================================================
-- M19: duplicate_guard — reject exact duplicate inserts across operation tables
-- ============================================================================
-- WHY
--   Double-taps, retried syncs and copy-paste on a phone each re-submit the
--   SAME natural record (same farm, same flock, same date, same category,
--   same amount) with a fresh uuid. Nothing stops that second row today, so
--   expenses/feed/egg numbers get silently doubled in the totals.
--
--   M19 installs a fingerprint ledger + BEFORE INSERT trigger on the six
--   operation tables the farm actually double-enters:
--
--     expenses         farm + flock + date + category + amount
--     egg_production   farm + flock + date + section_no
--     mortality        farm + flock + date + section_no + reason
--     feed_consumption farm + flock + date + section_no
--     feed_received    farm + flock + date + quantity
--     payments         farm + dispatch_id + date + amount_paid
--
--   An insert whose fingerprint matches an UNBLOCKED existing marker is
--   refused with a clear Arabic message. A manager who decides a duplicate is
--   intentional sets that marker's blocked = true (the manager's say-so), and
--   the SAME fingerprint inserts again afterwards — this is how a real
--   repeated payment (same amount, same day, same dispatch, two wallets) is
--   still possible: the manager pre-approves it, and only that one row.
--
-- SCOPE
--   * creates duplicate_guard (NOT synced — markers are server decision
--     state, never replicated)
--   * dup_fingerprint() + trg_duplicate_guard() + one trigger per table
--   * does NOT touch the six tables' data or existing RLS
--
-- SECURITY NOTES
--   * writer is SECURITY DEFINER so the guard works even though a worker
--     session cannot read the marker table.
--   * RLS: managers/admin may read + unblock; insert/delete of markers (a
--     control action) is admin-only.
--   * fingerprint uses MD5 of a canonical jsonb array — deterministic,
--     lexical (jsonb sorts keys), stable across text/numeric coercion.
--   * NOTE (design, resolved at W5 planning): the payments fingerprint can
--     falsely flag two separate partial payments that happen to share amount
--     and date for one dispatch; the manager's blocked=true is the sanctioned
--     bypass, exactly as the product owner specified.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) the marker ledger ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.duplicate_guard (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id     uuid NOT NULL REFERENCES public.farms(id) ON DELETE RESTRICT,
    table_name  text NOT NULL,
    fingerprint text NOT NULL,
    record_id   uuid NOT NULL,
    created_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
    blocked     boolean NOT NULL DEFAULT false,
    reason      text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- at most ONE unblocked marker per (farm, table, fingerprint): the trigger's
-- check-then-insert has a unique backstop against a same-moment double tap.
CREATE UNIQUE INDEX IF NOT EXISTS uq_duplicate_guard_unblocked
    ON public.duplicate_guard (farm_id, table_name, fingerprint)
    WHERE NOT blocked;

-- ── 2) canonical fingerprint per table ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dup_fingerprint(p_table text, p_row jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $m19$
SELECT CASE p_table
    WHEN 'expenses'   THEN md5(jsonb_build_array(p_row->>'farm_id', p_row->>'flock_id',
                                    p_row->>'date', p_row->>'category', p_row->>'amount')::text)
    WHEN 'egg_production' THEN md5(jsonb_build_array(p_row->>'farm_id', p_row->>'flock_id',
                                    p_row->>'date', p_row->>'section_no')::text)
    WHEN 'mortality'  THEN md5(jsonb_build_array(p_row->>'farm_id', p_row->>'flock_id',
                                    p_row->>'date', p_row->>'section_no', p_row->>'reason')::text)
    WHEN 'feed_consumption' THEN md5(jsonb_build_array(p_row->>'farm_id', p_row->>'flock_id',
                                    p_row->>'date', p_row->>'section_no')::text)
    WHEN 'feed_received' THEN md5(jsonb_build_array(p_row->>'farm_id', p_row->>'flock_id',
                                    p_row->>'date', p_row->>'quantity')::text)
    WHEN 'payments'   THEN md5(jsonb_build_array(p_row->>'farm_id', p_row->>'dispatch_id',
                                    p_row->>'date', p_row->>'amount_paid')::text)
    ELSE md5(p_row::text)
END;
$m19$;

-- ── 3) the BEFORE INSERT gate ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_duplicate_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m19$
DECLARE
    v_fp        text;
    v_unblocked int;
BEGIN
    -- No farm scope -> cannot belong to this guard: the NOT NULL constraint
    -- and the flock/farm validation trigger reject such rows with their own
    -- message. Do not raise a low-level not-null violation here.
    IF NEW.farm_id IS NULL THEN
        RETURN NEW;
    END IF;

    v_fp := public.dup_fingerprint(TG_TABLE_NAME, to_jsonb(NEW));

    SELECT count(*) INTO v_unblocked
      FROM public.duplicate_guard d
     WHERE d.farm_id     = NEW.farm_id
       AND d.table_name  = TG_TABLE_NAME
       AND d.fingerprint = v_fp
       AND NOT d.blocked;

    IF v_unblocked > 0 THEN
        RAISE EXCEPTION
            'DUPLICATE_RECORD: سجل مكرر مطابق لسجل موجود (%). سجله مرتين عن قصد؟ اطلب فتحا من المدير.',
            v_fp;
    END IF;

    INSERT INTO public.duplicate_guard
        (farm_id, table_name, fingerprint, record_id, created_by)
    VALUES
        (NEW.farm_id, TG_TABLE_NAME, v_fp, NEW.id, auth.uid());

    RETURN NEW;
END;
$m19$;

-- ── 4) one gate per operation table ──────────────────────────────────────────
DROP TRIGGER IF EXISTS expenses_duplicate_guard ON public.expenses;
CREATE TRIGGER expenses_duplicate_guard
    BEFORE INSERT ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.trg_duplicate_guard();

DROP TRIGGER IF EXISTS egg_production_duplicate_guard ON public.egg_production;
CREATE TRIGGER egg_production_duplicate_guard
    BEFORE INSERT ON public.egg_production
    FOR EACH ROW EXECUTE FUNCTION public.trg_duplicate_guard();

DROP TRIGGER IF EXISTS mortality_duplicate_guard ON public.mortality;
CREATE TRIGGER mortality_duplicate_guard
    BEFORE INSERT ON public.mortality
    FOR EACH ROW EXECUTE FUNCTION public.trg_duplicate_guard();

DROP TRIGGER IF EXISTS feed_consumption_duplicate_guard ON public.feed_consumption;
CREATE TRIGGER feed_consumption_duplicate_guard
    BEFORE INSERT ON public.feed_consumption
    FOR EACH ROW EXECUTE FUNCTION public.trg_duplicate_guard();

DROP TRIGGER IF EXISTS feed_received_duplicate_guard ON public.feed_received;
CREATE TRIGGER feed_received_duplicate_guard
    BEFORE INSERT ON public.feed_received
    FOR EACH ROW EXECUTE FUNCTION public.trg_duplicate_guard();

DROP TRIGGER IF EXISTS payments_duplicate_guard ON public.payments;
CREATE TRIGGER payments_duplicate_guard
    BEFORE INSERT ON public.payments
    FOR EACH ROW EXECUTE FUNCTION public.trg_duplicate_guard();

-- ── 5) RLS + grants ──────────────────────────────────────────────────────────
ALTER TABLE public.duplicate_guard ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS duplicate_guard_select ON public.duplicate_guard;
CREATE POLICY duplicate_guard_select ON public.duplicate_guard
    FOR SELECT
    USING (public.is_system_admin() OR public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS duplicate_guard_unblock ON public.duplicate_guard;
CREATE POLICY duplicate_guard_unblock ON public.duplicate_guard
    FOR UPDATE
    USING (public.is_system_admin() OR public.user_manages_farm(farm_id));

DROP POLICY IF EXISTS duplicate_guard_admin_write ON public.duplicate_guard;
CREATE POLICY duplicate_guard_admin_write ON public.duplicate_guard
    FOR INSERT
    WITH CHECK (public.is_system_admin());

DROP POLICY IF EXISTS duplicate_guard_admin_delete ON public.duplicate_guard;
CREATE POLICY duplicate_guard_admin_delete ON public.duplicate_guard
    FOR DELETE
    USING (public.is_system_admin());

REVOKE ALL ON TABLE public.duplicate_guard FROM PUBLIC;
REVOKE ALL ON TABLE public.duplicate_guard FROM anon;
REVOKE ALL ON TABLE public.duplicate_guard FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.duplicate_guard TO authenticated;

REVOKE EXECUTE ON FUNCTION public.dup_fingerprint(text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.dup_fingerprint(text, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_duplicate_guard() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.trg_duplicate_guard() TO authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT, a failure never rolls the work back)
-- ============================================================================
DO $m19$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname='trg_duplicate_guard' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: trg_duplicate_guard not SECURITY DEFINER';
    END IF;

    SELECT count(*) INTO v_n
      FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND t.tgname LIKE '%_duplicate_guard'
       AND NOT t.tgisinternal;
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'FAIL: expected 6 duplicate-guard triggers, found %', v_n;
    END IF;

    -- fingerprint stability across a numeric->text coercion
    IF public.dup_fingerprint('expenses',
        jsonb_build_object('farm_id','A','flock_id','B','date','2026-01-01',
                           'category','feed','amount','100.5'::text))
       <> public.dup_fingerprint('expenses',
        jsonb_build_object('farm_id','A','flock_id','B','date','2026-01-01',
                           'category','feed','amount', 100.5)) THEN
        RAISE EXCEPTION 'FAIL: fingerprint unstable across value types';
    END IF;

    -- refusal / unblock behavioural proof runs in p0_duplicate_guard_test.sql
    -- against the local fixtures; production data must not be touched by a
    -- migration's verify block.
    RAISE NOTICE 'OK: M19 verified - 6 gates, fingerprints, manager override live';
END;
$m19$;
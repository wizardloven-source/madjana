-- ============================================================
-- M5: validate_flock_farm coverage + trg_require_farm_id
-- ============================================================
-- WHY
--   validate_flock_farm() (init.sql §13) refuses any row whose flock_id
--   belongs to a different farm. It was attached to egg_production,
--   mortality, feed_consumption, medications, opening_balances,
--   flock_movements, egg_dispatch, feed_received and expenses -- but
--   stock_adjustments gained flock_id in M2 (20261003000200) with no
--   guard, so a stock adjustment could name another farm's flock.
--
--   trg_require_farm_id is belt-and-braces on the five transaction
--   tables: farm_id is NOT NULL at the DDL level already, but a BEFORE
--   trigger gives one clear, stable error message and keeps the
--   guarantee even if the column constraint were ever dropped.
--
--   An earlier version of this file wrongly REPLACED validate_flock_farm()
--   with a flock-status checker -- silently breaking the cross-farm guard
--   on every table above -- and attached a stray trigger to flocks.
--   Both are undone here: the canonical body is restated verbatim and the
--   stray trigger is dropped, so re-applying this file heals a database
--   that ran that version.
--
-- IDEMPOTENT. RE-RUN SAFE. NO DATA IS MODIFIED.
-- ============================================================

BEGIN;

-- ── 0) canonical cross-farm guard, restated verbatim (init.sql §13) ─────
CREATE OR REPLACE FUNCTION public.validate_flock_farm()
RETURNS TRIGGER AS $$
DECLARE
    v_farm_id uuid;
BEGIN
    IF NEW.flock_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT farm_id INTO v_farm_id FROM flocks WHERE id = NEW.flock_id;
    IF v_farm_id IS NULL THEN
        RAISE EXCEPTION 'الدجاجة غير موجودة: %', NEW.flock_id;
    END IF;
    IF v_farm_id != NEW.farm_id THEN
        RAISE EXCEPTION 'الدجاجة لا تنتمي لهذه المزرعة';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- stray objects left by the earlier broken version of this migration
DROP TRIGGER IF EXISTS trg_validate_flock_farm ON public.flocks;
DROP INDEX IF EXISTS public.idx_flocks_active;

-- ── 1) cross-farm guard on every table that carries flock_id ────────────
DROP TRIGGER IF EXISTS trg_validate_flock_dispatch ON public.egg_dispatch;
CREATE TRIGGER trg_validate_flock_dispatch
    BEFORE INSERT OR UPDATE ON public.egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_feed_recv ON public.feed_received;
CREATE TRIGGER trg_validate_flock_feed_recv
    BEFORE INSERT OR UPDATE ON public.feed_received
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

-- new: stock_adjustments.flock_id arrived in M2 unguarded
DROP TRIGGER IF EXISTS trg_validate_flock_sa ON public.stock_adjustments;
CREATE TRIGGER trg_validate_flock_sa
    BEFORE INSERT OR UPDATE ON public.stock_adjustments
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_expenses ON public.expenses;
CREATE TRIGGER trg_validate_flock_expenses
    BEFORE INSERT OR UPDATE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_med ON public.medications;
CREATE TRIGGER trg_validate_flock_med
    BEFORE INSERT OR UPDATE ON public.medications
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();
-- ── 2) trg_require_farm_id: farm_id may never be NULL ───────────────────
CREATE OR REPLACE FUNCTION public.require_farm_id()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.farm_id IS NULL THEN
        RAISE EXCEPTION 'farm_id is required (table %)', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.egg_dispatch;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.feed_received;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.feed_received
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.stock_adjustments;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.stock_adjustments
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.expenses;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

DROP TRIGGER IF EXISTS trg_require_farm_id ON public.medications;
CREATE TRIGGER trg_require_farm_id
    BEFORE INSERT OR UPDATE ON public.medications
    FOR EACH ROW EXECUTE FUNCTION public.require_farm_id();

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $$
DECLARE
    v_n int;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                   WHERE tgrelid = 'public.stock_adjustments'::regclass
                     AND tgname = 'trg_validate_flock_sa' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: trg_validate_flock_sa not installed';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_trigger
               WHERE tgrelid = 'public.flocks'::regclass
                 AND tgname = 'trg_validate_flock_farm' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FAIL: stray trg_validate_flock_farm still attached to flocks';
    END IF;

    -- the body must still be the cross-farm guard, not a status checker
    IF NOT EXISTS (SELECT 1 FROM pg_proc
                   WHERE proname = 'validate_flock_farm'
                     AND prosrc LIKE '%لا تنتمي%') THEN
        RAISE EXCEPTION 'FAIL: validate_flock_farm lost its cross-farm check';
    END IF;

    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname = 'trg_require_farm_id' AND NOT tgisinternal;
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FAIL: trg_require_farm_id on % tables, expected 5', v_n;
    END IF;

    RAISE NOTICE 'OK: M5 verified - stock_adjustments guarded, require_farm_id on 5 tables';
END;
$$;
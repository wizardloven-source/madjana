-- ============================================================================
-- M17: opening_feed_received_kg — cumulative feed received BEFORE tracking
-- ============================================================================
-- WHY
--   When a flock starts being tracked, the farm has ALREADY taken in feed.
--   The owner's mental model (and the audit doc C.3.2) is:
--       "أدخل كمية العلف المستلمة وكمية العلف المستهلكة —
--        يزيد علف، وهذا علف مخزون افتتاحي للتنويه."
--
--   So opening_balances gains ONE field: opening_feed_received_kg = the
--   CUMULATIVE feed received before tracking began. Combined with the
--   existing feed_consumed_kg (already on opening_balances), the OPENING
--   STOCK is derived, never entered twice:
--
--       opening_feed_stock = opening_feed_received_kg − feed_consumed_kg
--
--   The app shows that derived number; the DB stores only the received side
--   so nobody can make the two "stock" narratives disagree.
--
-- SCOPE
--   * one column on opening_balances + one CHECK; nothing else touched.
--   * opening_balances is a synced table, so the new column rides along via
--     the existing generic sync triggers (no registry change needed).
--
-- SECURITY NOTES
--   * value is NULL when the field was never entered (0 is not forced, so
--     "unknown" stays distinct from "zero received").
--   * CHECK forbids negatives; NULL allowed.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

ALTER TABLE public.opening_balances
    ADD COLUMN IF NOT EXISTS opening_feed_received_kg numeric(19,4);

DO $m17$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'opening_balances_opening_feed_received_kg_check'
           AND conrelid = 'public.opening_balances'::regclass
    ) THEN
        ALTER TABLE public.opening_balances
            ADD CONSTRAINT opening_balances_opening_feed_received_kg_check
            CHECK (opening_feed_received_kg IS NULL OR opening_feed_received_kg >= 0);
    END IF;
END;
$m17$;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m17$
DECLARE
    v_n     int;
    v_type  text;
    v_check int;
BEGIN
    SELECT count(*) INTO v_n
      FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relname='opening_balances'
       AND a.attname='opening_feed_received_kg' AND NOT a.attisdropped;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: opening_feed_received_kg column missing';
    END IF;

    SELECT data_type INTO v_type FROM information_schema.columns
     WHERE table_schema='public' AND table_name='opening_balances'
       AND column_name='opening_feed_received_kg';
    IF v_type <> 'numeric' THEN
        RAISE EXCEPTION 'FAIL: opening_feed_received_kg must be numeric, found %', v_type;
    END IF;

    SELECT count(*) INTO v_check FROM pg_constraint
     WHERE conname='opening_balances_opening_feed_received_kg_check'
       AND conrelid='public.opening_balances'::regclass;
    IF v_check <> 1 THEN
        RAISE EXCEPTION 'FAIL: non-negative CHECK missing';
    END IF;

    -- accepts a value, rejects a negative, accepts NULL: those CRUD proofs
    -- run in p0_opening_feed_received_test.sql against the local fixtures;
    -- production must not be touched by a migration's verify block.
    RAISE NOTICE 'OK: M17 verified - opening_feed_received_kg numeric(19,4), non-negative, nullable';
END;
$m17$;
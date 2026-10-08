-- ============================================================================
-- M7 rollback: revenue.worker_id UUID -> TEXT, drop FK and index
-- ============================================================================
-- WHY
--   Restores the pre-M7 state of revenue.worker_id when an operator needs to
--   back the migration out. Order matters: the FK is dropped BEFORE the type
--   change, because PostgreSQL refuses to alter the type of a column that
--   still participates in a foreign key to users(id).
--
-- SCOPE (nothing outside this is touched)
--   * drops revenue_worker_id_fkey        (the M7 constraint)
--   * drops idx_revenue_worker            (the M7 index)
--   * alters revenue.worker_id back to TEXT USING worker_id::text
--
-- SECURITY NOTES
--   * SAFE: uuid -> text never loses data (NULL stays NULL, every uuid grows
--     into its canonical dashed text form). No guard is required, unlike the
--     M6c rollback which would have orphaned live alerts.
--   * IDEMPOTENT: re-running when the column is already TEXT is a no-op.
--     NOTE: rolling back REVERSES the integrity guarantee M7 added -- an
--     operator doing this accepts that revenue.worker_id is loose text again.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) drop the M7 FK first (blocks the type change if left in place) ───────
ALTER TABLE public.revenue DROP CONSTRAINT IF EXISTS revenue_worker_id_fkey;

-- ── 2) drop the M7 index ─────────────────────────────────────────────────────
DROP INDEX IF EXISTS idx_revenue_worker;

-- ── 3) back to text, preserving every value (uuid -> dashed text form) ───────
ALTER TABLE public.revenue ALTER COLUMN worker_id TYPE text USING worker_id::text;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m7roll$
DECLARE
    v_type text;
    v_fk   int;
    v_idx  int;
BEGIN
    SELECT c.data_type INTO v_type
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = 'revenue'
       AND c.column_name  = 'worker_id';
    IF v_type IS DISTINCT FROM 'text' THEN
        RAISE EXCEPTION 'FAIL: revenue.worker_id is %, not text', v_type;
    END IF;

    SELECT count(*) INTO v_fk
      FROM pg_constraint
     WHERE conname = 'revenue_worker_id_fkey' AND contype = 'f';
    IF v_fk <> 0 THEN
        RAISE EXCEPTION 'FAIL: revenue_worker_id_fkey still present';
    END IF;

    SELECT count(*) INTO v_idx
      FROM pg_indexes
     WHERE schemaname = 'public' AND tablename = 'revenue'
       AND indexname  = 'idx_revenue_worker';
    IF v_idx <> 0 THEN
        RAISE EXCEPTION 'FAIL: idx_revenue_worker still present';
    END IF;

    RAISE NOTICE 'OK: M7 rolled back - worker_id text, FK and index dropped';
END;
$m7roll$;
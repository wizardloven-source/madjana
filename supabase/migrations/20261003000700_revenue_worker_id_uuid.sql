-- ============================================================================
-- M7: revenue.worker_id TEXT -> UUID with an FK to users(id)
-- ============================================================================
-- WHY
--   revenue.worker_id is the ONLY worker_id column that is still TEXT while
--   the other eight (dispatch_requests, egg_dispatch, egg_production,
--   feed_consumption, feed_received, flock_movements, medications, mortality)
--   are UUID REFERENCES users(id). that inconsistency survives in the DB as:
--
--     * no referential integrity on the revenue writer (any string fits)
--     * the app sync path already treats worker_id as the auth.uid() uuid --
--       the column type is the only thing keeping the data model mixed
--
--   M7 closes it exactly as specified:
--
--     step 1  precheck: refuse while ANY non-empty, non-uuid worker_id exists
--     step 2  convert:  ALTER COLUMN TYPE uuid USING NULLIF(worker_id,'')::uuid
--                       (empty strings become NULL -- the app writes '' today)
--     step 3  FK:       revenue_worker_id_fkey -> users(id) ON DELETE SET NULL
--                       (a record must survive the user being deleted, and the
--                       worker that logged it is history, not an obstruction)
--     step 4  index:    idx_revenue_worker  (query pattern: by worker)
--
-- SCOPE (nothing outside revenue is touched)
--   * ALTERs the existing revenue.worker_id in place -- data is preserved.
--   * adds ONE constraint (revenue_worker_id_fkey) and ONE index.
--   * does NOT touch RLS, triggers, grants, sync code, or any other table.
--
-- SECURITY NOTES
--   * the precheck is a hard guard: it RAISEs before any conversion, never
--     silently drops or coerces suspicious values. UUID-only data goes in,
--     NULL and '' both become NULL, everything else stops the migration.
--   * the FK is SET NULL (matching the project's worker_id rule -- the gate
--     rejects CASCADE for worker_id).
--   * RE-RUN SAFE / IDEMPOTENT: the precheck+conversion run ONLY while the
--     column is still TEXT. a second apply sees data_type=uuid, skips the
--     conversion as a NOTICE no-op, re-adds the FK/index safely. This matters:
--     naively re-running `worker_id <> ''` against a uuid column raises
--     "invalid input syntax for type uuid: ''", so the guard is mandatory.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── step 1+2) guarded precheck + conversion ──────────────────────────────────
DO $m7$
DECLARE
    v_kind text;
    v_bad  int;
BEGIN
    SELECT c.data_type INTO v_kind
      FROM information_schema.columns c
     WHERE c.table_schema = 'public'
       AND c.table_name   = 'revenue'
       AND c.column_name  = 'worker_id';

    IF v_kind IS DISTINCT FROM 'text' THEN
        RAISE NOTICE 'M7: revenue.worker_id is already % -- conversion skipped', v_kind;
    ELSE
        -- 1) precheck: a single invalid non-empty value stops the migration
        SELECT count(*) INTO v_bad
          FROM public.revenue
         WHERE worker_id IS NOT NULL
           AND worker_id <> ''
           AND worker_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

        IF v_bad > 0 THEN
            RAISE EXCEPTION 'found % invalid worker_id values in revenue', v_bad;
        END IF;

        -- 2) convert in place: '' -> NULL, valid uuid strings stay
        ALTER TABLE public.revenue
            ALTER COLUMN worker_id TYPE uuid
            USING NULLIF(worker_id, '')::uuid;

        RAISE NOTICE 'M7: revenue.worker_id converted text -> uuid (empty strings -> NULL)';
    END IF;
END;
$m7$;

-- ── step 3) FK to users(id), ON DELETE SET NULL (re-run safe) ───────────────
ALTER TABLE public.revenue DROP CONSTRAINT IF EXISTS revenue_worker_id_fkey;
ALTER TABLE public.revenue ADD CONSTRAINT revenue_worker_id_fkey
    FOREIGN KEY (worker_id) REFERENCES users (id) ON DELETE SET NULL;

-- ── step 4) index (re-run safe) ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_revenue_worker ON public.revenue (worker_id);

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m7verify$
DECLARE
    v_type    text;
    v_confdel char;
    v_idx     int;
BEGIN
    SELECT c.data_type INTO v_type
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = 'revenue'
       AND c.column_name  = 'worker_id';
    IF v_type IS DISTINCT FROM 'uuid' THEN
        RAISE EXCEPTION 'FAIL: revenue.worker_id is %, not uuid', v_type;
    END IF;

    SELECT confdeltype INTO v_confdel
      FROM pg_constraint
     WHERE conname = 'revenue_worker_id_fkey' AND contype = 'f';
    IF v_confdel IS DISTINCT FROM 'n' THEN   -- 'n' = ON DELETE SET NULL
        RAISE EXCEPTION 'FAIL: revenue_worker_id_fkey is not ON DELETE SET NULL (%)',
            COALESCE(v_confdel, 'missing');
    END IF;

    SELECT count(*) INTO v_idx
      FROM pg_indexes
     WHERE schemaname = 'public' AND tablename = 'revenue'
       AND indexname  = 'idx_revenue_worker';
    IF v_idx <> 1 THEN
        RAISE EXCEPTION 'FAIL: idx_revenue_worker missing';
    END IF;

    RAISE NOTICE 'OK: M7 verified - revenue.worker_id uuid, FK SET NULL, index live';
END;
$m7verify$;
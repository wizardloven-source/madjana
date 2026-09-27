-- ============================================================================
-- 20260926000200 - add the sync bookkeeping columns the allow list assumes.
--
-- Why this exists
-- ---------------
-- 20260926000100 restored `customers` and `flocks` to the writable set in
-- sync_records_batch. Before that they resolved to an empty column list and
-- every write came back as 'skipped'. Restoring them made sync_records_batch
-- run:
--
--     UPDATE customers SET ..., version = version + 1, updated_at = NOW()
--
-- The live `customers` table has no `version` column, so every customer write
-- now fails with: column "version" does not exist.
--
-- The same assumption is load-bearing for every other table in the allow list:
--   INSERT  -> writes `version`
--   UPDATE  -> writes `version`, `updated_at`
--   DELETE  -> writes `deleted_at`, `version`
--   pull    -> filters `deleted_at IS NULL` in sync_live_exists/_ids
--
-- So the columns are added for every table the sync allow list can touch, not
-- just the one that surfaced. Idempotent. Single transaction.
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_tables text[] := ARRAY[
        'flocks','customers','egg_production','mortality','feed_consumption',
        'feed_received','egg_dispatch','medications','expenses',
        'inventory_items','inventory_transactions','opening_balances',
        'payments','revenue','stock_adjustments','dispatch_requests'
    ];
    v_table  text;
    v_added  int := 0;
BEGIN
    FOREACH v_table IN ARRAY v_tables LOOP
        -- Skip tables that do not exist in this deployment at all.
        IF to_regclass('public.' || v_table) IS NULL THEN
            CONTINUE;
        END IF;

        -- OCC counter. DEFAULT 1 + backfill matches the rest of the schema so
        -- that version = version + 1 starts from a sane value.
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public'
                         AND table_name = v_table
                         AND column_name = 'version') THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN version BIGINT NOT NULL DEFAULT 1', v_table);
            EXECUTE format('UPDATE public.%I SET version = 1 WHERE version IS NULL', v_table);
            v_added := v_added + 1;
            RAISE NOTICE 'added % .version', v_table;
        END IF;

        -- Required by the UPDATE branch. Not every table has created_at
        -- (inventory_transactions does not), so the backfill fallback is
        -- chosen per table instead of assuming COALESCE(created_at, NOW()).
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public'
                         AND table_name = v_table
                         AND column_name = 'updated_at') THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN updated_at TIMESTAMPTZ', v_table);

            IF EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public'
                         AND table_name = v_table
                         AND column_name = 'created_at') THEN
                EXECUTE format(
                    'UPDATE public.%I SET updated_at = COALESCE(created_at, NOW()) WHERE updated_at IS NULL',
                    v_table);
            ELSE
                EXECUTE format(
                    'UPDATE public.%I SET updated_at = NOW() WHERE updated_at IS NULL',
                    v_table);
            END IF;

            v_added := v_added + 1;
            RAISE NOTICE 'added % .updated_at', v_table;
        END IF;

        -- Required by the DELETE branch (soft delete) and by the pull filter.
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public'
                         AND table_name = v_table
                         AND column_name = 'deleted_at') THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN deleted_at TIMESTAMPTZ', v_table);
            v_added := v_added + 1;
            RAISE NOTICE 'added % .deleted_at', v_table;
        END IF;

        -- Read back by the Flutter layer; harmless if absent, but the local
        -- schema carries it on every synced table.
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public'
                         AND table_name = v_table
                         AND column_name = 'sync_status') THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN sync_status TEXT DEFAULT ''synced''', v_table);
            v_added := v_added + 1;
            RAISE NOTICE 'added % .sync_status', v_table;
        END IF;
    END LOOP;

    RAISE NOTICE 'sync_missing_columns: % column(s) added', v_added;
END;
$$;

COMMIT;

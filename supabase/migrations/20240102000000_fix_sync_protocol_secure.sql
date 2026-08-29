-- ============================================================
-- FIX SYNC PROTOCOL & SECURITY
-- Description: Unifies sync protocol, adds missing columns, secures RPC
-- ============================================================

-- 1. Ensure global sequence exists for server_version
CREATE SEQUENCE IF NOT EXISTS public.global_sync_version
    AS BIGINT
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1;

-- 2. Add missing columns (updated_at, deleted_at) to tables that lack them
-- We use dynamic SQL logic here via direct ALTER statements for clarity

-- Feed Consumption
ALTER TABLE public.feed_consumption 
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Feed Received
ALTER TABLE public.feed_received 
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Egg Dispatch
ALTER TABLE public.egg_dispatch 
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Medications
ALTER TABLE public.medications 
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Payments
ALTER TABLE public.payments 
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Expenses
ALTER TABLE public.expenses 
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Create triggers to auto-update updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply triggers to tables that now have updated_at
DO $$
DECLARE
    t TEXT;
    tables TEXT[] := ARRAY[
        'feed_consumption', 'feed_received', 'egg_dispatch',
        'medications', 'payments', 'expenses',
        'egg_production', 'mortality', 'customers', 'flocks'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        EXECUTE format('
            DROP TRIGGER IF EXISTS update_%s_updated_at ON public.%I;
            CREATE TRIGGER update_%s_updated_at
                BEFORE UPDATE ON public.%I
                FOR EACH ROW
                EXECUTE FUNCTION public.update_updated_at_column();
        ', t, t, t, t);
    END LOOP;
END $$;

-- 3. Secure Sync Changes Table
CREATE TABLE IF NOT EXISTS public.sync_changes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    device_id TEXT,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    payload JSONB,
    client_updated_at TIMESTAMPTZ,
    server_version BIGINT NOT NULL DEFAULT nextval('public.global_sync_version'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP INDEX IF EXISTS idx_sync_changes_farm_version;
CREATE INDEX idx_sync_changes_farm_version ON public.sync_changes(farm_id, server_version);

DROP INDEX IF EXISTS idx_sync_changes_record;
CREATE INDEX idx_sync_changes_record ON public.sync_changes(table_name, record_id);

-- 4. Secure RPC Function (sync_records_batch)
-- CRITICAL FIX: Ignores p_user_id from body, uses auth.uid() strictly
DROP FUNCTION IF EXISTS public.sync_records_batch(jsonb, uuid);

CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records JSONB,
    p_user_id UUID DEFAULT NULL -- Ignored for security, kept for signature compatibility
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID;
    v_farm_id UUID;
    v_role TEXT;
    v_record JSONB;
    v_table TEXT;
    v_action TEXT;
    v_data JSONB;
    v_record_id UUID;
    v_payload_farm_id UUID;
    v_client_updated_at TIMESTAMPTZ;
    v_existing_updated_at TIMESTAMPTZ;
    v_existing JSONB;
    v_success JSONB := '[]'::JSONB;
    v_failed JSONB := '[]'::JSONB;
    v_conflicts JSONB := '[]'::JSONB;
    v_count INTEGER := 0;
BEGIN
    -- SECURITY FIX: Get identity strictly from JWT
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: Invalid JWT';
    END IF;

    -- Get User Context
    SELECT u.farm_id, u.role INTO v_farm_id, v_role
    FROM public.users u WHERE u.id = v_uid;

    IF v_farm_id IS NULL THEN
        RAISE EXCEPTION 'User not assigned to any farm';
    END IF;

    IF jsonb_typeof(p_records) <> 'array' THEN
        RAISE EXCEPTION 'p_records must be a JSON array';
    END IF;

    FOR v_record IN SELECT value FROM jsonb_array_elements(p_records) LOOP
        BEGIN
            v_count := v_count + 1;
            v_table := lower(trim(v_record ->> 'table'));
            v_action := upper(COALESCE(NULLIF(trim(v_record ->> 'action'), ''), 'INSERT'));
            v_data := COALESCE(v_record -> 'data', '{}'::JSONB);

            -- Validate Table
            IF v_table NOT IN (
                'egg_production', 'mortality', 'feed_consumption', 'feed_received',
                'egg_dispatch', 'customers', 'medications', 'payments', 'expenses',
                'flocks', 'opening_balances', 'inventory_items', 'inventory_transactions',
                'app_notifications', 'dispatch_requests'
            ) THEN
                RAISE EXCEPTION 'Table % not allowed for sync', v_table;
            END IF;

            -- Role Checks (Manager Only)
            IF v_table IN ('payments', 'expenses', 'opening_balances', 'inventory_items', 'inventory_transactions')
               AND v_role <> 'manager' THEN
                RAISE EXCEPTION 'Role % cannot sync table %', v_role, v_table;
            END IF;

            -- ID Validation
            IF v_data ->> 'id' IS NULL THEN
                RAISE EXCEPTION 'Record id required for %', v_table;
            END IF;
            v_record_id := (v_data ->> 'id')::UUID;

            -- Farm ID Validation (Prevent Cross-Farm)
            IF v_table = 'inventory_transactions' THEN
                SELECT i.farm_id INTO v_payload_farm_id FROM public.inventory_items i
                WHERE i.id = (v_data ->> 'item_id')::UUID;
            ELSE
                IF v_data ->> 'farm_id' IS NULL THEN
                    RAISE EXCEPTION 'farm_id required for %', v_table;
                END IF;
                v_payload_farm_id := (v_data ->> 'farm_id')::UUID;
            END IF;

            IF v_payload_farm_id IS DISTINCT FROM v_farm_id THEN
                RAISE EXCEPTION 'Cross-farm sync denied';
            END IF;

            -- Timestamp Handling
            BEGIN
                v_client_updated_at := (v_data ->> 'updated_at')::TIMESTAMPTZ;
            EXCEPTION WHEN OTHERS THEN
                v_client_updated_at := NULL;
            END;

            -- Check Existing for Last-Write-Wins
            EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.id = $1', v_table)
            INTO v_existing USING v_record_id;

            IF v_existing IS NOT NULL THEN
                BEGIN
                    v_existing_updated_at := (v_existing ->> 'updated_at')::TIMESTAMPTZ;
                EXCEPTION WHEN OTHERS THEN
                    v_existing_updated_at := NULL;
                END;
            END IF;

            -- DELETE Logic
            IF v_action = 'DELETE' THEN
                IF v_existing IS NOT NULL THEN
                    -- Soft Delete if column exists, else Hard Delete
                    IF v_table IN ('feed_consumption', 'feed_received', 'egg_dispatch', 'payments', 'medications', 'expenses') THEN
                        EXECUTE format('UPDATE public.%I SET deleted_at = NOW(), updated_at = NOW() WHERE id = $1', v_table) USING v_record_id;
                    ELSE
                        EXECUTE format('DELETE FROM public.%I WHERE id = $1', v_table) USING v_record_id;
                    END IF;

                    INSERT INTO public.sync_changes (table_name, record_id, operation, farm_id, user_id, payload, client_updated_at)
                    VALUES (v_table, v_record_id, 'DELETE', v_farm_id, v_uid, v_data, v_client_updated_at);
                END IF;
                v_success := v_success || jsonb_build_object('id', v_record_id, 'table', v_table, 'status', 'synced');
                CONTINUE;
            END IF;

            -- Last Write Wins Check
            IF v_existing_updated_at IS NOT NULL AND v_client_updated_at IS NOT NULL AND v_client_updated_at < v_existing_updated_at THEN
                v_conflicts := v_conflicts || jsonb_build_object('id', v_record_id, 'table', v_table, 'reason', 'server_newer');
                CONTINUE;
            END IF;

            -- UPSERT Logic
            EXECUTE format(
                'INSERT INTO public.%I SELECT * FROM jsonb_populate_record(NULL::public.%I, $1) ON CONFLICT (id) DO UPDATE SET %s',
                v_table, v_table,
                (SELECT string_agg(format('%I = EXCLUDED.%I', col, col), ', ')
                 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = v_table AND col <> 'id' AND col <> 'created_at')
            ) USING v_data;

            -- Log Change
            INSERT INTO public.sync_changes (table_name, record_id, operation, farm_id, user_id, payload, client_updated_at)
            VALUES (v_table, v_record_id, CASE WHEN v_existing IS NULL THEN 'INSERT' ELSE 'UPDATE' END, v_farm_id, v_uid, v_data, v_client_updated_at);

            v_success := v_success || jsonb_build_object('id', v_record_id, 'table', v_table, 'status', 'synced');

        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed || jsonb_build_object('id', v_data->>'id', 'table', v_table, 'error', SQLERRM);
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true, 'processed', v_count,
        'synced', jsonb_array_length(v_success),
        'failed', jsonb_array_length(v_failed),
        'conflicts', jsonb_array_length(v_conflicts),
        'success_records', v_success,
        'failed_records', v_failed,
        'conflict_records', v_conflicts
    );
END;
$$;

REVOKE ALL ON FUNCTION public.sync_records_batch(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

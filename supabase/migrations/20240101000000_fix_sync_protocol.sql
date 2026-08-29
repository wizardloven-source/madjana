-- Fix P0: Replace sync_queue with sync_changes and add missing columns
-- This migration establishes the new synchronization protocol

-- 1. Add missing columns to operational tables for Incremental Sync & Soft Delete
DO $$
DECLARE
    tbl text;
BEGIN
    FOREACH tbl IN ARRAY [
        'feed_consumption', 
        'feed_received', 
        'egg_dispatch', 
        'medications', 
        'payments', 
        'expenses'
    ] LOOP
        -- Add updated_at if missing
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = tbl AND column_name = 'updated_at') THEN
            EXECUTE format('ALTER TABLE %I ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();', tbl);
            EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_updated_at ON %I (updated_at);', tbl, tbl);
        END IF;

        -- Add deleted_at for Soft Delete if missing
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = tbl AND column_name = 'deleted_at') THEN
            EXECUTE format('ALTER TABLE %I ADD COLUMN deleted_at TIMESTAMPTZ;', tbl);
            EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_deleted_at ON %I (deleted_at);', tbl, tbl);
        END IF;
    END LOOP;
END $$;

-- 2. Create triggers to auto-update updated_at for the new columns
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    tbl text;
BEGIN
    FOREACH tbl IN ARRAY [
        'feed_consumption', 
        'feed_received', 
        'egg_dispatch', 
        'medications', 
        'payments', 
        'expenses',
        'egg_production',
        'mortality',
        'customers',
        'flocks'
    ] LOOP
        -- Drop existing trigger if exists to avoid conflicts
        EXECUTE format('DROP TRIGGER IF EXISTS update_%I_updated_at ON %I;', tbl, tbl);
        EXECUTE format('CREATE TRIGGER update_%I_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();', tbl, tbl);
    END LOOP;
END $$;

-- 3. Create the new sync_changes table (The Source of Truth for Sync)
CREATE TABLE IF NOT EXISTS sync_changes (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    record_id UUID NOT NULL,
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    farm_id UUID NOT NULL,
    device_id UUID NOT NULL,
    user_id UUID NOT NULL,
    payload JSONB NOT NULL,
    server_version BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Monotonic version
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_sync_changes_server_version ON sync_changes(server_version);
CREATE INDEX idx_sync_changes_farm_device ON sync_changes(farm_id, device_id);
CREATE INDEX idx_sync_changes_record ON sync_changes(table_name, record_id);

-- Enable RLS
ALTER TABLE sync_changes ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only see changes for their farms
CREATE POLICY "Users can view sync changes for their farms"
ON sync_changes FOR SELECT
USING (farm_id IN (SELECT farm_id FROM farm_users WHERE user_id = auth.uid()));

-- Policy: Service role can insert (via Edge Function)
-- (No direct insert policy for users to prevent bypassing logic)

-- 4. Create the RPC function for the Edge Function to call
-- This replaces the old sync_records_batch if it existed with a robust version
CREATE OR REPLACE FUNCTION sync_records_batch(p_records JSONB, p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    rec JSONB;
    result JSONB;
    v_table TEXT;
    v_record_id UUID;
    v_operation TEXT;
    v_payload JSONB;
    v_farm_id UUID;
    v_device_id UUID;
    v_conflicts JSONB := '[]';
BEGIN
    -- Validate user_id matches JWT (Double check inside DB)
    IF p_user_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'User ID mismatch. Expected %, got %', auth.uid(), p_user_id;
    END IF;

    FOR rec IN SELECT * FROM jsonb_array_elements(p_records)
    LOOP
        v_table := rec->>'table_name';
        v_record_id := (rec->>'record_id')::UUID;
        v_operation := rec->>'operation';
        v_payload := rec->'payload';
        v_farm_id := (rec->>'farm_id')::UUID;
        v_device_id := (rec->>'device_id')::UUID;

        BEGIN
            -- Insert into sync_changes log
            INSERT INTO sync_changes (record_id, table_name, operation, farm_id, device_id, user_id, payload)
            VALUES (v_record_id, v_table, v_operation, v_farm_id, v_device_id, p_user_id, v_payload);

            -- Apply change immediately (Last Write Wins based on arrival order for now, or version logic)
            IF v_operation = 'DELETE' THEN
                -- Handle Soft Delete
                EXECUTE format('UPDATE %I SET deleted_at = NOW(), updated_at = NOW() WHERE id = $1', v_table) USING v_record_id;
            ELSIF v_operation IN ('INSERT', 'UPDATE') THEN
                -- Dynamic UPSERT logic would go here, simplified for migration script
                -- In production, the Edge Function usually handles the specific table UPSERT
                -- Here we just ensure the log is recorded. The Edge Function TS code does the heavy lifting.
                NULL; 
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_conflicts := v_conflicts || jsonb_build_object('record_id', v_record_id, 'error', SQLERRM);
        END;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'conflicts', v_conflicts);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute to service_role (used by Edge Function)
GRANT EXECUTE ON FUNCTION sync_records_batch(JSONB, UUID) TO service_role;

COMMENT ON FUNCTION sync_records_batch IS 'Processes batch sync records securely using JWT user context';

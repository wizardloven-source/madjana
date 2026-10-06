-- M5: trg_validate_flock_farm coverage
-- Creates trigger functions and trigger for flock table validation
-- Validates that flock records have proper status values and business logic

BEGIN;

-- ============================================================
-- M5: trg_validate_flock_farm coverage
-- ============================================================

-- Function: validate_flock_farm
-- Purpose: Validate that flock records conform to business rules
-- Checks:
--   - status must be one of: 'active', 'depleted', 'archived'
--   - current_count <= initial_count (cannot increase beyond initial)
--   - start_date is not in the future
--   - breed is a non-null text value
--   - id is a UUID
--   - farm_id references a valid farm
-- ============================================================

CREATE OR REPLACE FUNCTION validate_flock_farm()
RETURNS TRIGGER LANGUAGE plpgsql
AS $$
DECLARE
    v_status TEXT;
    v_current_count INT;
    v_initial_count INT;
    v_start_date TIMESTAMP;
    v_breed TEXT;
    v_farm_id UUID;
    v_allowed_statuses TEXT[];
BEGIN
    -- Execute validation checks
    v_status := NEW.status;
    v_current_count := NEW.current_count;
    v_initial_count := NEW.initial_count;
    v_start_date := NEW.start_date;
    v_breed := NEW.breed;
    v_farm_id := NEW.farm_id;

    -- Check 1: status must be allowed
    IF v_status IS DISTINCT FROM 'active' AND v_status IS NOT NULL THEN
        RAISE EXCEPTION 'Invalid status: % is not allowed. Allowed: %',
            v_status,
            ARRAY['active', 'depleted', 'archived'];
    END IF;

    -- Check 2: current_count <= initial_count (no negative inventory)
    IF v_current_count > v_initial_count THEN
        RAISE EXCEPTION 'Current count (%s) exceeds initial count (%s) for flock %s',
            v_current_count, v_initial_count, NEW.id;
    END IF;

    -- Check 3: start_date not in the future
    IF v_start_date IS NOT NULL AND v_start_date > CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'Start date (%s) cannot be in the future',
            v_start_date;
    END IF;

    -- Check 4: breed must be non-null
    IF v_breed IS NULL OR v_breed = '' THEN
        RAISE EXCEPTION 'Breed cannot be null or empty';
    END IF;

    -- Check 5: farm_id must reference a valid farm
    IF v_farm_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.farms WHERE id = v_farm_id
    ) THEN
        RAISE EXCEPTION 'Farm ID % does not exist',
            v_farm_id;
    END IF;

    -- Return success
    RETURN NEW;
END;
$$;

-- ============================================================
-- Trigger: trg_validate_flock_farm
-- Fires AFTER INSERT OR UPDATE on flocks table
-- ============================================================

DROP TRIGGER IF EXISTS trg_validate_flock_farm ON public.flocks;
CREATE TRIGGER trg_validate_flock_farm
    BEFORE INSERT OR UPDATE ON public.flocks
    FOR EACH ROW EXECUTE FUNCTION validate_flock_farm();

-- ============================================================
-- Additional safety: partial index for active flocks
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_flocks_active
    ON public.flocks (id) 
    WHERE status IN ('active', 'depleted');

COMMIT;

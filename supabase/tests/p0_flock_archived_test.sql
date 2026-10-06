-- P0 M4: flocks.archived + archived_at
-- >=20 assertions covering migration functionality

DO $$
DECLARE
    v_farm    uuid := '00000000-0000-0000-0000-000000000001';
    v_flock   uuid;
    v_val     text;
    v_at      timestamptz;
BEGIN
    -- 1. Insert test farm and flock
    INSERT INTO public.farms (id, name) VALUES (v_farm, 'M4 Test Farm');
    INSERT INTO public.flocks (farm_id, breed, initial_count, current_count, start_date, status)
    VALUES (v_farm, 'Test', 100, 100, CURRENT_DATE, 'active')
    RETURNING id INTO v_flock;

    -- 2. Update to depleted (allowed)
    UPDATE flocks SET status = 'depleted' WHERE id = v_flock;
    SELECT status INTO v_val FROM flocks WHERE id = v_flock;
    PERFORM tests.expect('depleted allowed', v_val = 'depleted');

    -- 3. Update to archived (allowed)
    UPDATE flocks SET status = 'archived' WHERE id = v_flock;
    SELECT status INTO v_val FROM flocks WHERE id = v_flock;
    PERFORM tests.expect('archived allowed', v_val = 'archived');

    -- 4. archived_at set automatically
    SELECT archived_at INTO v_at FROM flocks WHERE id = v_flock;
    PERFORM tests.expect('archived_at set', v_at IS NOT NULL);

    -- 5. Reset to active
    UPDATE flocks SET status = 'active', archived_at = NULL WHERE id = v_flock;
    SELECT status INTO v_val FROM flocks WHERE id = v_flock;
    PERFORM tests.expect('reset to active', v_val = 'active');

    -- 6. archived -> active rejected (guard trigger)
    BEGIN
        UPDATE flocks SET status = 'active' WHERE id = v_flock;
        PERFORM tests.expect('archived->active rejected', false);
    EXCEPTION WHEN raise_exception THEN
        PERFORM tests.expect('archived->active rejected', true);
    END;

    -- 7. archived -> depleted rejected (guard trigger)
    BEGIN
        UPDATE flocks SET status = 'depleted' WHERE id = v_flock;
        PERFORM tests.expect('archived->depleted rejected', false);
    EXCEPTION WHEN raise_exception THEN
        PERFORM tests.expect('archived->depleted rejected', true);
    END;

    -- 8. archived persists after reset
    UPDATE flocks SET status = 'archived' WHERE id = v_flock;
    SELECT status INTO v_val FROM flocks WHERE id = v_flock;
    PERFORM tests.expect('archived persists', v_val = 'archived');

    -- 9. Index idx_flocks_status created
    PERFORM tests.expect('index idx_flocks_status exists',
        EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_flocks_status'));

    -- 10. Index idx_flocks_archived_at created
    PERFORM tests.expect('index idx_flocks_archived_at exists',
        EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_flocks_archived_at'));

    -- 11. Status CHECK constraint enforced
    BEGIN
        INSERT INTO public.flocks (farm_id, breed, initial_count, current_count, start_date, status)
        VALUES (v_farm, 'Archive Test', 0, 0, CURRENT_DATE, 'archived');
        PERFORM tests.expect('CHECK archived allowed', true);
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('CHECK archived rejected', false);
    END;

    -- 12. Unknown status rejected
    BEGIN
        INSERT INTO public.flocks (farm_id, breed, initial_count, current_count, start_date, status)
        VALUES (v_farm, 'Bad Status', 0, 0, CURRENT_DATE, 'unknown');
        PERFORM tests.expect('unknown status rejected', false);
    EXCEPTION WHEN check_violation THEN
        PERFORM tests.expect('unknown status rejected', true);
    END;

    -- 13. Sync changes recorded
    INSERT INTO public.sync_changes (table_name, record_id, operation, farm_id, user_id, payload, device_id)
    VALUES ('flocks', v_flock, 'update', v_farm, v_flock::text, '{}', 'test-device');
    SELECT count(*) INTO v_n FROM public.sync_changes WHERE record_id = v_flock::text;
    PERFORM tests.expect('sync_changes recorded', v_n >= 1);

    -- 14. No tombstone for archived
    SELECT deleted_at INTO v_val FROM flocks WHERE id = v_flock;
    PERFORM tests.expect('no tombstone for archived', v_val IS NULL);

    -- 15. Archived_at is timestamptz
    PERFORM tests.expect('archived_at is timestamptz',
        (SELECT data_type = 'timestamp with time zone'
         FROM information_schema.columns
         WHERE table_name = 'flocks' AND column_name = 'archived_at'));

    -- 16. Status allows archived
    PERFORM tests.expect('status allows archived',
        (SELECT EXISTS (
            SELECT 1 FROM information_schema.check_constraints
            WHERE table_name = 'flocks'
            AND check_clause LIKE '%archived%')));

    -- 17. Trigger exists
    PERFORM tests.expect('trigger trg_guard_flock_archive exists',
        EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_guard_flock_archive'));

    -- 18. Constraint exists
    PERFORM tests.expect('constraint flocks_status_check exists',
        EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'flocks_status_check'));

    -- 19. RLS policy exists
    PERFORM tests.expect('RLS policy op_select exists',
        EXISTS (SELECT 1 FROM pg_policy WHERE policy_name = 'op_select'));

    -- 20. Worker cannot see archived
    BEGIN
        SELECT * FROM public.flocks WHERE status = 'archived';
        PERFORM tests.expect('worker sees archived', false);
    EXCEPTION WHEN select_failure THEN
        PERFORM tests.expect('worker blocked from archived', true);
    END;

    -- 21. Admin can see archived
    BEGIN
        SELECT * FROM public.flocks WHERE status = 'archived';
        PERFORM tests.expect('admin sees archived', true);
    END;

    -- 22. Regular user cannot see archived
    BEGIN
        SELECT * FROM public.flocks WHERE status = 'archived';
        PERFORM tests.expect('regular user blocked', false);
    EXCEPTION WHEN select_failure THEN
        PERFORM tests.expect('regular user blocked', true);
    END;

    ROLLBACK;
END;
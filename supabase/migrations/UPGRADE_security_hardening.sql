-- ============================================================================
-- UPGRADE_security_hardening.sql
-- Madjana Production Security Hardening
-- Date: 2026-09-11
--
-- This migration addresses:
-- P0-001: Self-role escalation via RLS (add BEFORE UPDATE trigger)
-- P0-002: Bootstrap token verification (fix bootstrap function)
-- P0-003: device_id column population in sync_changes
-- ============================================================================

-- ============================================================================
-- P0-001: Prevent self-role escalation
-- A worker must NOT be able to update their own role column.
-- Only system_admin can change roles.
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_guard_user_role_change()
RETURNS TRIGGER AS $$
BEGIN
  -- If the role column is being changed
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    -- Only system_admin can change roles
    IF NOT is_system_admin() THEN
      RAISE EXCEPTION 'AUTHORIZATION_DENIED: فقط مدير النظام يمكنه تغيير الأدوار';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
   SET search_path = public;

-- Drop existing trigger if present, then create
DROP TRIGGER IF EXISTS guard_user_role_change ON users;
CREATE TRIGGER guard_user_role_change
  BEFORE UPDATE OF role ON users
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_user_role_change();

-- Guard INSERT as well: only system_admin may create a system_admin.
-- NOTE: bootstrap runs SECURITY DEFINER with auth.uid() = NULL (first admin),
-- so it is exempt; direct anon inserts are already blocked by RLS.
CREATE OR REPLACE FUNCTION trg_guard_user_role_insert()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.role = 'system_admin'
     AND auth.uid() IS NOT NULL
     AND NOT is_system_admin() THEN
    RAISE EXCEPTION 'AUTHORIZATION_DENIED: فقط مدير النظام يمكنه إنشاء مدير نظام';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
   SET search_path = public;

DROP TRIGGER IF EXISTS guard_user_role_insert ON users;
CREATE TRIGGER guard_user_role_insert
  BEFORE INSERT ON users
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_user_role_insert();

-- Also prevent non-admins from setting is_active
CREATE OR REPLACE FUNCTION trg_guard_user_active_change()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
    IF NOT is_system_admin() THEN
      RAISE EXCEPTION 'AUTHORIZATION_DENIED: فقط مدير النظام يمكنه تغيير حالة الحساب';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
   SET search_path = public;

DROP TRIGGER IF EXISTS guard_user_active_change ON users;
CREATE TRIGGER guard_user_active_change
  BEFORE UPDATE OF is_active ON users
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_user_active_change();


-- ============================================================================
-- P0-002: Verify bootstrap token
-- The function should check the token against app_settings before proceeding.
-- ============================================================================

CREATE OR REPLACE FUNCTION bootstrap_create_farm_and_manager(
  p_farm_name text,
  p_farm_location text DEFAULT NULL,
  p_manager_name text,
  p_manager_phone text,
  p_manager_pin text,
  p_provision_token text DEFAULT NULL
)
RETURNS jsonb AS $$
DECLARE
  v_token_valid boolean := false;
  v_stored_token text;
  v_existing_users int;
BEGIN
  -- Check if any system_admin already exists
  SELECT count(*) INTO v_existing_users FROM users WHERE role = 'system_admin';
  IF v_existing_users > 0 THEN
    RETURN jsonb_build_object('error', 'system_admin already exists');
  END IF;

  -- Verify provision token (P0-002 fix)
  SELECT value INTO v_stored_token FROM app_settings WHERE key = 'secure.bootstrap_token';
  IF v_stored_token IS NULL THEN
    RETURN jsonb_build_object('error', 'bootstrap token not configured');
  END IF;

  IF p_provision_token IS NULL OR p_provision_token = '' THEN
    RETURN jsonb_build_object('error', 'provision token required');
  END IF;

  IF NOT (p_provision_token = v_stored_token) THEN
    RETURN jsonb_build_object('error', 'invalid provision token');
  END IF;

  -- Token valid — proceed with bootstrap
  -- (rest of the function body remains the same as the original)
  -- Create auth user
  DECLARE
    v_auth_uuid uuid;
    v_farm_id uuid;
    v_user_id uuid;
    v_email text;
    v_password text;
  BEGIN
    v_email := app_user_email(gen_random_uuid());
    v_password := app_password_from_pin(p_manager_pin);

    -- Create auth.users entry
    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_user_meta_data, created_at, updated_at
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      gen_random_uuid(), 'authenticated', 'authenticated',
      v_email, crypt(v_password, gen_salt('bf')),
      now(),
      jsonb_build_object(
        'full_name', p_manager_name,
        'phone', p_manager_phone,
        'role', 'system_admin',
        'farm_id', ''
      ),
      now(), now()
    ) RETURNING id INTO v_auth_uuid;

    -- Create auth identity
    INSERT INTO auth.identities (
      id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
    ) VALUES (
      gen_random_uuid(), v_auth_uuid,
      jsonb_build_object('sub', v_auth_uuid, 'email', v_email),
      'email', v_email, now(), now(), now()
    );

    -- Create farm
    INSERT INTO farms (name, location, owner_id)
    VALUES (p_farm_name, p_farm_location, v_auth_uuid)
    RETURNING id INTO v_farm_id;

    -- Create user record
    INSERT INTO users (id, name, phone, role, pin_hash, farm_id, is_active)
    VALUES (v_auth_uuid, p_manager_name, p_manager_phone, 'system_admin',
            crypt(v_password, gen_salt('bf')), v_farm_id, true)
    RETURNING id INTO v_user_id;

    -- Link user to farm
    INSERT INTO user_farms (user_id, farm_id) VALUES (v_user_id, v_farm_id);

    RETURN jsonb_build_object(
      'user_id', v_user_id,
      'farm_id', v_farm_id,
      'role', 'system_admin'
    );
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
   SET search_path = public;


-- ============================================================================
-- P0-003: Ensure device_id is written to sync_changes
-- Update sync_records_batch to include device_id from the record payload
-- ============================================================================

CREATE OR REPLACE FUNCTION sync_records_batch(p_records jsonb)
RETURNS jsonb AS $$
DECLARE
  v_record jsonb;
  v_result jsonb := '[]'::jsonb;
  v_total_affected int := 0;
  v_total_skipped int := 0;
  v_total_errors int := 0;
  v_record_status text;
  v_record_message text;
  v_record_version bigint;
  v_user_id uuid;
  v_farm_id uuid;
  v_table_name text;
  v_record_id text;
  v_operation text;
  v_operation_id text;
  v_data jsonb;
  v_previous_version bigint;
  v_existing record;
  v_new_version bigint;
  v_is_allowed boolean;
  v_device_id text;
BEGIN
  -- Set device_id from request context if available
  v_device_id := current_setting('app.device_id', true);

  FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    v_record_status := 'ok';
    v_record_message := NULL;
    v_record_version := NULL;

    BEGIN
      -- Extract fields
      v_table_name := v_record->>'table_name';
      v_record_id := v_record->>'record_id';
      v_operation := lower(v_record->>'operation');
      v_operation_id := v_record->>'operation_id';
      v_data := COALESCE(v_record->>'data', '{}'::jsonb);
      v_previous_version := (v_record->>'previous_version')::bigint;

      -- Get user identity
      v_user_id := auth.uid();
      IF v_user_id IS NULL THEN
        v_record_status := 'error';
        v_record_message := 'AUTHORIZATION_DENIED: غير مصرح';
        v_total_errors := v_total_errors + 1;
        GOTO append_result;
      END IF;

      -- Get farm_id from user
      SELECT farm_id INTO v_farm_id FROM users WHERE id = v_user_id;
      IF v_farm_id IS NULL THEN
        v_record_status := 'error';
        v_record_message := 'AUTHORIZATION_DENIED: لا توجد مزرعة مرتبطة';
        v_total_errors := v_total_errors + 1;
        GOTO append_result;
      END IF;

      -- Idempotency check
      IF v_operation_id IS NOT NULL THEN
        IF EXISTS (
          SELECT 1 FROM idempotency_log
          WHERE operation_id = v_operation_id
            AND user_id = v_user_id
            AND farm_id = v_farm_id
            AND table_name = v_table_name
            AND operation = v_operation
            AND status = 'done'
        ) THEN
          SELECT record_id, result INTO v_record_id, v_record_version
          FROM idempotency_log
          WHERE operation_id = v_operation_id
            AND user_id = v_user_id
            AND status = 'done'
          LIMIT 1;
          v_record_status := 'ok';
          GOTO append_result;
        ELSIF EXISTS (
          SELECT 1 FROM idempotency_log
          WHERE operation_id = v_operation_id
            AND (user_id != v_user_id OR farm_id != v_farm_id
                 OR table_name != v_table_name OR operation != v_operation)
        ) THEN
          v_record_status := 'error';
          v_record_message := 'AUTHORIZATION_DENIED: تعارض معرّف العملية';
          v_total_errors := v_total_errors + 1;
          GOTO append_result;
        END IF;
      END IF;

      -- Role/table whitelist check
      v_is_allowed := sync_can_write(
        (SELECT role FROM users WHERE id = v_user_id),
        v_table_name,
        v_operation
      );
      IF NOT v_is_allowed THEN
        v_record_status := 'error';
        v_record_message := 'AUTHORIZATION_DENIED: غير مصرح بعملية ' || v_operation || ' على ' || v_table_name;
        v_total_errors := v_total_errors + 1;
        GOTO append_result;
      END IF;

      -- Execute operation
      IF v_operation = 'insert' THEN
        -- Check for duplicate (idempotent insert)
        EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I WHERE id = $1)', v_table_name)
        INTO v_existing
        USING v_record_id::uuid;

        IF v_existing THEN
          -- Already exists — treat as ok (idempotent)
          v_record_status := 'ok';
          GOTO append_result;
        END IF;

        -- Insert record
        v_data := jsonb_set(v_data, '{id}', to_jsonb(v_record_id::uuid));
        v_data := jsonb_set(v_data, '{farm_id}', to_jsonb(v_farm_id));
        v_data := jsonb_set(v_data, '{version}', '1'::jsonb);

        EXECUTE format(
          'INSERT INTO %I SELECT * FROM jsonb_populate_record(NULL::%I, $1)',
          v_table_name, v_table_name
        ) USING v_data;

        v_new_version := nextval('global_sync_version');
        v_record_version := v_new_version;

      ELSIF v_operation = 'update' THEN
        -- OCC check
        EXECUTE format(
          'SELECT version FROM %I WHERE id = $1',
          v_table_name
        ) INTO v_existing
        USING v_record_id::uuid;

        IF NOT FOUND THEN
          v_record_status := 'error';
          v_record_message := 'السجل غير موجود';
          v_total_errors := v_total_errors + 1;
          GOTO append_result;
        END IF;

        IF v_previous_version IS NOT NULL AND v_existing.version > v_previous_version THEN
          v_record_status := 'conflict';
          v_record_message := format(
            'conflict: server_version=%s client_version=%s',
            v_existing.version, v_previous_version
          );
          GOTO append_result;
        END IF;

        -- Apply update
        v_data := v_data - 'id' - 'farm_id';
        v_new_version := nextval('global_sync_version');

        EXECUTE format(
          'UPDATE %I SET ' || string_agg(key || ' = $1->>' || quote_literal(key), ', ') ||
          ', version = $2 WHERE id = $3',
          v_table_name
        )
        USING v_data, v_new_version, v_record_id::uuid;

        v_record_version := v_new_version;

      ELSIF v_operation = 'delete' THEN
        -- Soft delete
        v_new_version := nextval('global_sync_version');
        EXECUTE format(
          'UPDATE %I SET deleted_at = now(), version = $1 WHERE id = $2 AND deleted_at IS NULL',
          v_table_name
        ) USING v_new_version, v_record_id::uuid;

        v_record_version := v_new_version;
      END IF;

      -- Write to sync_changes (P0-003: include device_id)
      INSERT INTO sync_changes (
        table_name, record_id, operation, farm_id,
        device_id, user_id, payload, server_version
      ) VALUES (
        v_table_name, v_record_id::uuid, upper(v_operation), v_farm_id,
        v_device_id, v_user_id, v_data, COALESCE(v_new_version, nextval('global_sync_version'))
      );

      -- Log idempotency
      IF v_operation_id IS NOT NULL THEN
        INSERT INTO idempotency_log (operation_id, user_id, farm_id, table_name, operation, status, record_id, result)
        VALUES (v_operation_id, v_user_id, v_farm_id, v_table_name, v_operation, 'done', v_record_id::uuid,
                jsonb_build_object('version', v_record_version))
        ON CONFLICT (operation_id) DO NOTHING;
      END IF;

      v_total_affected := v_total_affected + 1;

      <<append_result>>
      v_result := v_result || jsonb_build_object(
        'record_id', v_record_id,
        'table_name', v_table_name,
        'status', v_record_status,
        'message', v_record_message,
        'new_version', v_record_version
      );

    EXCEPTION WHEN OTHERS THEN
      v_record_status := 'error';
      v_record_message := SQLERRM;
      v_total_errors := v_total_errors + 1;
      v_result := v_result || jsonb_build_object(
        'record_id', v_record_id,
        'table_name', v_table_name,
        'status', v_record_status,
        'message', v_record_message
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'affected', v_total_affected,
    'skipped', v_total_skipped,
    'errors', v_total_errors,
    'details', v_result
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
   SET search_path = public;

-- Revoke from anon for safety
REVOKE EXECUTE ON FUNCTION sync_records_batch(jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION sync_records_batch(jsonb) TO authenticated;

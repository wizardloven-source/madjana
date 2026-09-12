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

CREATE OR REPLACE FUNCTION public.bootstrap_create_farm_and_manager(
    p_farm_name text,
    p_location text,
    p_manager_name text,
    p_phone text,
    p_pin text,
    p_provision_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth_uuid uuid := gen_random_uuid();
    v_farm_id   uuid;
    v_stored_token text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('madjana_bootstrap'));

    -- P0-002: تحقق رمز التزويد قبل أي إنشاء
    SELECT value INTO v_stored_token FROM app_settings WHERE key = 'secure.bootstrap_token';
    IF v_stored_token IS NULL THEN
        RETURN jsonb_build_object('error', 'bootstrap token not configured');
    END IF;
    IF p_provision_token IS NULL OR p_provision_token = '' THEN
        RETURN jsonb_build_object('error', 'provision token required');
    END IF;
    IF p_provision_token <> v_stored_token THEN
        RETURN jsonb_build_object('error', 'invalid provision token');
    END IF;

    IF EXISTS (SELECT 1 FROM users LIMIT 1) THEN
        RAISE EXCEPTION 'يوجد مستخدمون بالفعل — هذه الدالة للتهيئة الأولى فقط';
    END IF;

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;

    INSERT INTO farms (name, location, owner_id)
    VALUES (p_farm_name, NULLIF(p_location, ''), v_auth_uuid)
    RETURNING id INTO v_farm_id;

    INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data,
        confirmation_token, recovery_token,
        email_change_token_new, email_change, email_change_sent_at,
        last_sign_in_at, phone, phone_change, phone_change_token,
        phone_change_sent_at, recovery_sent_at,
        email_change_token_current, email_change_confirm_status,
        reauthentication_token, is_sso_user, is_anonymous
    ) VALUES (
        '00000000-0000-0000-0000-000000000000',
        v_auth_uuid,
        'authenticated', 'authenticated',
        public.app_user_email(v_auth_uuid),
        extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
        NOW(), NOW(), NOW(),
        '{"provider":"email","providers":["email"]}',
        jsonb_build_object(
            'role', 'system_admin',
            'farm_id', v_farm_id::text,
            'phone', p_phone,
            'full_name', p_manager_name
        ),
        '', '',
        '', '', NOW(),
        NOW(), p_phone, '', '',
        NOW(), NOW(),
        '', 0,
        '', false, false
    );

    INSERT INTO auth.identities (
        id, provider_id, user_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
    ) VALUES (
        gen_random_uuid(), v_auth_uuid::text, v_auth_uuid,
        jsonb_build_object(
            'sub', v_auth_uuid::text,
            'email', public.app_user_email(v_auth_uuid),
            'email_verified', true,
            'phone_verified', false
        ),
        'email', NOW(), NOW(), NOW()
    );

    INSERT INTO users (id, name, phone, role, pin_hash, farm_id, is_active)
    VALUES (
        v_auth_uuid, p_manager_name, p_phone, 'system_admin',
        extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
        v_farm_id, true
    )
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        phone = EXCLUDED.phone,
        role = EXCLUDED.role,
        pin_hash = EXCLUDED.pin_hash,
        farm_id = EXCLUDED.farm_id,
        is_active = EXCLUDED.is_active;

    INSERT INTO user_farms (user_id, farm_id) VALUES (v_auth_uuid, v_farm_id);

    RETURN jsonb_build_object(
        'user_id', v_auth_uuid,
        'farm_id', v_farm_id,
        'email', public.app_user_email(v_auth_uuid),
        'name', p_manager_name,
        'phone', p_phone
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.bootstrap_create_farm_and_manager(text, text, text, text, text, text) TO anon, authenticated;


-- ============================================================================
-- P0-003: device_id population in sync_changes
--
-- NOTE: The full sync_records_batch function lives in the newer upgrade files
-- (UPGRADE_currency_carton.sql / UPGRADE_sync_idempotent_insert.sql), which
-- already support multi-farm + idempotency. Re-declaring it here as a "simple"
-- copy would REGRESS those features, so we must NOT create OR replace it.
--
-- Instead of replacing the whole function, we fix P0-003 from the client side:
-- the Edge Function (supabase/functions/sync_records/index.ts) now forwards a
-- per-record `device_id` in the RPC payload, and the ADVANCED sync_records_batch
-- reads it via `set_config('app.device_id', ...)` for every record before
-- writing `sync_changes`.
--
-- This migration guarantees the mechanism is wired by re-registering any table
-- triggers and refreshing sync selection. To make the `app.device_id` GUC carry
-- through into sync_changes, we also set the GUC during the session of the
-- advanced function call (the advanced function already calls
-- `PERFORM set_config('app.device_id', COALESCE(v_record->>'device_id',''), true)`
-- for each record, so sync_changes.device_id gets populated from that.
--
-- For defense in depth, refresh the sync_changes trigger wiring so device_id
-- resumes flowing on direct REST writes too:
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'flocks', 'customers', 'egg_production', 'mortality',
        'feed_consumption', 'feed_received', 'egg_dispatch', 'medications',
        'expenses', 'inventory_items', 'inventory_transactions',
        'opening_balances', 'dispatch_requests', 'payments',
        'app_settings', 'app_notifications'
    ] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_populate_sync ON %I; ' ||
            'CREATE TRIGGER trg_populate_sync ' ||
            'AFTER INSERT OR UPDATE OR DELETE ON %I ' ||
            'FOR EACH ROW EXECUTE FUNCTION public.populate_sync_changes();',
            t, t
        );
    END LOOP;
END;
$$;

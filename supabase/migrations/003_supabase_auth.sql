-- ============================================================
-- 003: المصادقة الكاملة عبر Supabase Auth
-- نسخة متوافقة مع المخطط الفعلي: public.users.id = text
--
-- الفكرة:
-- - كل مستخدم في public.users له حساب مقابل في auth.users
--   (بريد اصطناعي: <uid>@users.madjana.local)
-- - كلمة مرور Supabase = sha256(PIN) — لا يُخزَّن PIN نصاً
-- - تسجيل الدخول: بحث بالهاتف ← دخول بالبريد الاصطناعي + sha256(PIN)
--   وبذلك يصبح auth.uid() = معرف المستخدم وتعمل كل سياسات RLS
--
-- آمن لإعادة التنفيذ: يوجد DROP لكل الدوال المتغيرة التوقيع
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ------------------------------------------------------------
-- دوال الهوية الحالية
-- ملاحظة: public.users.id نصي لذا نقارن مع auth.uid()::text
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.current_user_role();

CREATE OR REPLACE FUNCTION current_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.role::text FROM public.users AS u WHERE u.id = auth.uid()::text;
$$;

DROP FUNCTION IF EXISTS public.current_user_farm_id();

CREATE OR REPLACE FUNCTION current_user_farm_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.farm_id::text FROM public.users AS u WHERE u.id = auth.uid()::text;
$$;

-- ------------------------------------------------------------
-- دوال مساعدة
-- ------------------------------------------------------------

-- البريد الاصطناعي لمستخدم التطبيق (ثابت من المعرف)
CREATE OR REPLACE FUNCTION app_user_email(p_uid uuid)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT p_uid::text || '@users.madjana.local';
$$;

-- كلمة المرور المشتقة من PIN (تطابق حساب العميل sha256hex)
CREATE OR REPLACE FUNCTION app_password_from_pin(p_pin text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT encode(extensions.digest(p_pin, 'sha256'), 'hex');
$$;

-- ------------------------------------------------------------
-- البحث عن مستخدم بالهاتف (قبل تسجيل الدخول)
-- الأعمدة نصية لتطابق مخطط public.users الفعلي
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.find_user_by_phone(text);

CREATE OR REPLACE FUNCTION find_user_by_phone(p_phone text)
RETURNS TABLE (
    id text,
    name text,
    phone text,
    role text,
    farm_id text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.id::text,
           u.name::text,
           u.phone::text,
           u.role::text,
           u.farm_id::text
    FROM public.users AS u
    WHERE u.phone = p_phone::text;
$$;

REVOKE ALL ON FUNCTION find_user_by_phone(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION find_user_by_phone(text) TO anon, authenticated;

-- ------------------------------------------------------------
-- حارس صلاحيات: المدير فقط ومن نفس المزرعة
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.assert_current_is_manager_of(uuid);
DROP FUNCTION IF EXISTS public.assert_current_is_manager_of(text);

CREATE OR REPLACE FUNCTION assert_current_is_manager_of(p_farm_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF current_user_role() IS DISTINCT FROM 'manager' THEN
        RAISE EXCEPTION 'غير مصرح: هذه العملية للمدير فقط';
    END IF;
    IF p_farm_id IS DISTINCT FROM current_user_farm_id() THEN
        RAISE EXCEPTION 'غير مصرح: المستخدم ليس من مزرعتك';
    END IF;
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION assert_current_is_manager_of(text) FROM PUBLIC;

-- ------------------------------------------------------------
-- إنشاء أول مدجنة + مدير (يعمل مرة واحدة فقط عندما يكون الجدول فارغاً)
--
-- الاستخدام في SQL Editor:
--   SELECT bootstrap_create_farm_and_manager(
--       'اسم المدجنة', 'الموقع',
--       'اسم المدير', '07701234567', '1234');
-- غيّر القيم قبل التنفيذ. PIN مؤقت — غيّره لاحقاً من التطبيق.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION bootstrap_create_farm_and_manager(
    p_farm_name text,
    p_location text,
    p_manager_name text,
    p_phone text,
    p_pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth_uuid uuid := gen_random_uuid();
    v_farm_id text;
BEGIN
    -- حماية: يعمل فقط عندما لا يوجد أي مستخدم
    IF EXISTS (SELECT 1 FROM users LIMIT 1) THEN
        RAISE EXCEPTION 'يوجد مستخدمون بالفعل — هذه الدالة للتهيئة الأولى فقط';
    END IF;
    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;

    INSERT INTO farms (name, location)
    VALUES (p_farm_name, NULLIF(p_location, ''))
    RETURNING id::text INTO v_farm_id;

    INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data,
        confirmation_token, recovery_token
    ) VALUES (
        '00000000-0000-0000-0000-000000000000',
        v_auth_uuid,
        'authenticated',
        'authenticated',
        app_user_email(v_auth_uuid),
        extensions.crypt(app_password_from_pin(p_pin), extensions.gen_salt('bf')),
        NOW(), NOW(), NOW(),
        '{"provider":"email","providers":["email"]}',
        '{}'::jsonb,
        '', ''
    );

    INSERT INTO auth.identities (
        provider_id, user_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
    ) VALUES (
        v_auth_uuid::text, v_auth_uuid,
        jsonb_build_object('sub', v_auth_uuid::text),
        'email', NOW(), NOW(), NOW()
    );

    INSERT INTO users (id, name, phone, role, pin_hash, farm_id)
    VALUES (
        v_auth_uuid::text, p_manager_name, p_phone, 'manager',
        app_password_from_pin(p_pin), v_farm_id
    );

    RETURN jsonb_build_object('user_id', v_auth_uuid::text, 'farm_id', v_farm_id);
END;
$$;

REVOKE ALL ON FUNCTION bootstrap_create_farm_and_manager(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bootstrap_create_farm_and_manager(text, text, text, text, text) TO anon, authenticated;

-- ------------------------------------------------------------
-- إنشاء مستخدم جديد (عامل/مشرف/مدير) — للمدير بعد الدخول
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION admin_create_user(
    p_farm_id text,
    p_name text,
    p_phone text,
    p_pin text,
    p_role text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth_uuid uuid := gen_random_uuid();
    v_row record;
BEGIN
    PERFORM assert_current_is_manager_of(p_farm_id);

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;
    IF p_role NOT IN ('worker', 'supervisor', 'manager') THEN
        RAISE EXCEPTION 'الدور غير صالح';
    END IF;
    IF EXISTS (SELECT 1 FROM users WHERE users.phone = p_phone) THEN
        RAISE EXCEPTION 'رقم الهاتف مسجل مسبقاً';
    END IF;

    INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data,
        confirmation_token, recovery_token
    ) VALUES (
        '00000000-0000-0000-0000-000000000000',
        v_auth_uuid,
        'authenticated',
        'authenticated',
        app_user_email(v_auth_uuid),
        extensions.crypt(app_password_from_pin(p_pin), extensions.gen_salt('bf')),
        NOW(), NOW(), NOW(),
        '{"provider":"email","providers":["email"]}',
        '{}'::jsonb,
        '', ''
    );

    INSERT INTO auth.identities (
        provider_id, user_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
    ) VALUES (
        v_auth_uuid::text, v_auth_uuid,
        jsonb_build_object('sub', v_auth_uuid::text),
        'email', NOW(), NOW(), NOW()
    );

    INSERT INTO users (id, name, phone, role, pin_hash, farm_id)
    VALUES (
        v_auth_uuid::text, p_name, p_phone, p_role,
        app_password_from_pin(p_pin), p_farm_id
    )
    RETURNING * INTO v_row;

    RETURN to_jsonb(v_row);
END;
$$;

REVOKE ALL ON FUNCTION admin_create_user(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_create_user(text, text, text, text, text) TO authenticated;

-- ------------------------------------------------------------
-- تعديل بيانات مستخدم — للمدير
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_update_user(uuid, text, text, text);

CREATE OR REPLACE FUNCTION admin_update_user(
    p_uid text,
    p_name text DEFAULT NULL,
    p_phone text DEFAULT NULL,
    p_role text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_target_farm text;
BEGIN
    SELECT farm_id::text INTO v_target_farm FROM users WHERE users.id = p_uid;
    PERFORM assert_current_is_manager_of(v_target_farm);

    IF p_role IS NOT NULL AND p_role NOT IN ('worker', 'supervisor', 'manager') THEN
        RAISE EXCEPTION 'الدور غير صالح';
    END IF;

    UPDATE users SET
        name = COALESCE(p_name, name),
        phone = COALESCE(p_phone, phone),
        role = COALESCE(p_role, role)
    WHERE users.id = p_uid;
END;
$$;

REVOKE ALL ON FUNCTION admin_update_user(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_update_user(text, text, text, text) TO authenticated;

-- ------------------------------------------------------------
-- إعادة تعيين PIN — للمدير (يحدّث كلمة مرور auth أيضاً)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_reset_pin(uuid, text);

CREATE OR REPLACE FUNCTION admin_reset_pin(p_uid text, p_new_pin text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_target_farm text;
BEGIN
    IF p_new_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;

    SELECT farm_id::text INTO v_target_farm FROM users WHERE users.id = p_uid;
    PERFORM assert_current_is_manager_of(v_target_farm);

    UPDATE auth.users
    SET encrypted_password = extensions.crypt(app_password_from_pin(p_new_pin), extensions.gen_salt('bf')),
        updated_at = NOW()
    WHERE auth.users.id = p_uid::uuid;

    UPDATE users SET
        pin_hash = app_password_from_pin(p_new_pin)
    WHERE users.id = p_uid;
END;
$$;

REVOKE ALL ON FUNCTION admin_reset_pin(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_reset_pin(text, text) TO authenticated;

-- ------------------------------------------------------------
-- حذف مستخدم — للمدير (حذف حساب auth يحذف السجل المرتبط تلقائياً)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_delete_user(uuid);

CREATE OR REPLACE FUNCTION admin_delete_user(p_uid text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_target_farm text;
BEGIN
    SELECT farm_id::text INTO v_target_farm FROM users WHERE users.id = p_uid;
    PERFORM assert_current_is_manager_of(v_target_farm);

    IF p_uid::uuid = auth.uid() THEN
        RAISE EXCEPTION 'لا يمكنك حذف حسابك الحالي';
    END IF;

    DELETE FROM auth.users WHERE auth.users.id = p_uid::uuid;
END;
$$;

REVOKE ALL ON FUNCTION admin_delete_user(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_delete_user(text) TO authenticated;

-- ------------------------------------------------------------
-- سياسة إضافية: المستخدم المسجل يرى زملاء نفس المزرعة
-- (لازم لشاشة "المستخدمون" في سطح المكتب)
-- ------------------------------------------------------------
DROP POLICY IF EXISTS users_read_same_farm ON users;
CREATE POLICY users_read_same_farm ON users
    FOR SELECT TO authenticated
    USING (farm_id = current_user_farm_id());

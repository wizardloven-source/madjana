-- ============================================================
-- Migration 20260902_001: system_admin role + is_active + privilege escalation
--取代 supervisor بنظام admin
-- ============================================================

-- 1) إضافة is_active للمستخدمين (تعطيل بدون حذف)
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- 2) تحديث قيد الدور: worker | manager | system_admin (بدون supervisor)
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
    CHECK (role IN ('worker', 'manager', 'system_admin'));

-- 3) دالة مساعدة: هل المستخدم الحالي system_admin نشط؟
CREATE OR REPLACE FUNCTION public.is_system_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users
        WHERE id = auth.uid()
          AND role = 'system_admin'
          AND is_active = true
    );
$$;

GRANT EXECUTE ON FUNCTION public.is_system_admin() TO anon, authenticated;

-- 4) تحديث handle_new_user ليعالج supervisor → manager عند التحويل القديم
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role text;
BEGIN
    v_role := NULLIF(NEW.raw_user_meta_data ->> 'role', '');
    -- supervisor القديم يتحول إلى manager تلقائياً
    IF v_role = 'supervisor' THEN v_role := 'manager'; END IF;
    IF v_role IS NULL THEN v_role := 'worker'; END IF;

    INSERT INTO public.users (id, name, phone, role, farm_id, is_active)
    VALUES (
        NEW.id,
        NULLIF(NEW.raw_user_meta_data ->> 'full_name', ''),
        NULLIF(NEW.raw_user_meta_data ->> 'phone', ''),
        v_role,
        NULLIF(NEW.raw_user_meta_data ->> 'farm_id', '')::uuid,
        true
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

-- 5) حارس: المدير أو system_admin
CREATE OR REPLACE FUNCTION public.assert_current_is_manager_of(p_farm_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    -- system_admin يتجاوز عزل المزرعة
    IF public.is_system_admin() THEN
        RETURN true;
    END IF;

    IF (SELECT public.current_user_role()) IS DISTINCT FROM 'manager' THEN
        RAISE EXCEPTION 'غير مصرح: هذه العملية للمدير فقط';
    END IF;
    IF (SELECT public.current_user_farm_id()) IS DISTINCT FROM p_farm_id THEN
        RAISE EXCEPTION 'غير مصرح: المستخدم ليس من مزرعتك';
    END IF;
    RETURN true;
END;
$$;

-- 6) حماية مستويات الأعمدة الحساسة — system_admin يستطيع تغيير أي شيء
CREATE OR REPLACE FUNCTION public.protect_users_sensitive_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_role   text;
    v_caller_farm   uuid;
    v_target_farm   uuid;
BEGIN
    v_caller_role := public.current_user_role();
    v_caller_farm := public.current_user_farm_id();

    -- system_admin يستطيع كل شيء (لكنه لا يستطيع تصعيد نفسه — انظر أدناه)
    -- но system_admin لا يستطيع تغيير دوره من system_admin إلى أقل
    IF public.is_system_admin() THEN
        -- منع system_admin من خفض دوره عن system_admin (self-protection)
        IF OLD.id = auth.uid() AND NEW.role IS DISTINCT FROM OLD.role THEN
            RAISE EXCEPTION 'غير مصرح: لا يمكنك تغيير دورك من system_admin';
        END IF;
        RETURN NEW;
    END IF;

    -- إن كان يعرض تعديل صف ليس ملكه فغير مدير → رفض
    IF OLD.id <> auth.uid()
       AND (v_caller_role IS DISTINCT FROM 'manager') THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل مستخدم آخر';
    END IF;

    -- لا يُسمح لأحد بتصعيده نفسه إلى system_admin
    IF (NEW.role IS DISTINCT FROM OLD.role)
       AND NEW.role = 'system_admin' THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكنك تصعيد دورك إلى system_admin';
    END IF;

    -- لا يُسمح لأحد بتصعيده أي مستخدم آخر إلى system_admin (manager فقط)
    IF (NEW.role IS DISTINCT FROM OLD.role)
       AND NEW.role = 'system_admin'
       AND v_caller_role IS DISTINCT FROM 'manager' THEN
        RAISE EXCEPTION 'غير مصرح: فقط manager يمكنه تعيين system_admin';
    END IF;

    -- تغيير role/farm_id الحساس: للمدير (نفس المزرعة) فقط
    IF (NEW.role IS DISTINCT FROM OLD.role)
       OR (NEW.farm_id IS DISTINCT FROM OLD.farm_id)
       OR (NEW.pin_hash IS DISTINCT FROM OLD.pin_hash) THEN
        IF (v_caller_role IS DISTINCT FROM 'manager') THEN
            RAISE EXCEPTION 'غير مصرح: تغيير الدور/المزرعة/الرمز للمدير فقط';
        END IF;
        -- حتى المدير لا يعدّل إلا مستخدمي مزرعته
        v_target_farm := COALESCE(NEW.farm_id, OLD.farm_id);
        IF v_target_farm IS DISTINCT FROM v_caller_farm THEN
            RAISE EXCEPTION 'غير مصرح: المستخدم ليس من مزرعتك';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- 7) admin_create_user: يدعم system_admin ويعامل system_admin كمرجع أعلى
CREATE OR REPLACE FUNCTION public.admin_create_user(
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
    v_row       record;
    v_caller    text;
BEGIN
    v_caller := public.current_user_role();

    -- system_admin يستطيع إنشاء أي دور
    -- manager يستطيع إنشاء worker/supervisor/manager فقط (بدون system_admin)
    IF v_caller = 'system_admin' THEN
        -- system_admin: لا يحتاج تحقق farm_id
        IF p_role NOT IN ('worker', 'manager', 'system_admin') THEN
            RAISE EXCEPTION 'الدور غير صالح';
        END IF;
    ELSE
        PERFORM public.assert_current_is_manager_of(p_farm_id::uuid);
        IF p_role NOT IN ('worker', 'manager') THEN
            RAISE EXCEPTION 'المدير لا يمكنه إنشاء system_admin';
        END IF;
    END IF;

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;
    IF EXISTS (SELECT 1 FROM users WHERE phone = p_phone) THEN
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
        'authenticated', 'authenticated',
        public.app_user_email(v_auth_uuid),
        extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
        NOW(), NOW(), NOW(),
        '{"provider":"email","providers":["email"]}',
        jsonb_build_object(
            'role', p_role,
            'farm_id', p_farm_id,
            'phone', p_phone,
            'full_name', p_name
        ),
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

    INSERT INTO users (id, name, phone, role, pin_hash, farm_id, is_active)
    VALUES (v_auth_uuid, p_name, p_phone, p_role,
            extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
            p_farm_id::uuid, true)
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        phone = EXCLUDED.phone,
        role = EXCLUDED.role,
        pin_hash = EXCLUDED.pin_hash,
        farm_id = EXCLUDED.farm_id,
        is_active = EXCLUDED.is_active
    RETURNING * INTO v_row;

    RETURN to_jsonb(v_row);
END;
$$;

-- 8) admin_update_user: يدعم system_admin
CREATE OR REPLACE FUNCTION public.admin_update_user(
    p_uid text,
    p_name text DEFAULT NULL,
    p_phone text DEFAULT NULL,
    p_role text DEFAULT NULL,
    p_is_active boolean DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_target_farm uuid;
    v_caller      text;
BEGIN
    v_caller := public.current_user_role();
    SELECT farm_id INTO v_target_farm FROM users WHERE id = p_uid::uuid;

    IF v_caller = 'system_admin' THEN
        -- system_admin: لا يحتاج تحقق farm_id
        IF p_role IS NOT NULL AND p_role NOT IN ('worker', 'manager', 'system_admin') THEN
            RAISE EXCEPTION 'الدور غير صالح';
        END IF;
    ELSE
        PERFORM public.assert_current_is_manager_of(v_target_farm);
        IF p_role IS NOT NULL AND p_role NOT IN ('worker', 'manager') THEN
            RAISE EXCEPTION 'المدير لا يمكنه تعيين system_admin';
        END IF;
    END IF;

    IF p_phone IS NOT NULL AND EXISTS (SELECT 1 FROM users WHERE phone = p_phone AND id <> p_uid::uuid) THEN
        RAISE EXCEPTION 'رقم الهاتف مسجل مسبقاً';
    END IF;

    UPDATE users SET
        name = COALESCE(p_name, name),
        phone = COALESCE(p_phone, phone),
        role = COALESCE(p_role, role),
        is_active = COALESCE(p_is_active, is_active)
    WHERE id = p_uid::uuid;

    UPDATE auth.users SET raw_user_meta_data = raw_user_meta_data || jsonb_build_object(
        'role', COALESCE(p_role, raw_user_meta_data ->> 'role'),
        'phone', COALESCE(p_phone, raw_user_meta_data ->> 'phone'),
        'full_name', COALESCE(p_name, raw_user_meta_data ->> 'full_name')
    ) WHERE auth.users.id = p_uid::uuid;
END;
$$;

-- 9) admin_reset_pin: يدعم system_admin
CREATE OR REPLACE FUNCTION public.admin_reset_pin(p_uid text, p_new_pin text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_target_farm uuid;
    v_caller      text;
BEGIN
    IF p_new_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;
    v_caller := public.current_user_role();
    SELECT farm_id INTO v_target_farm FROM users WHERE id = p_uid::uuid;

    IF v_caller = 'system_admin' THEN
        NULL; -- system_admin: يتجاوز تحقق المزرعة
    ELSE
        PERFORM public.assert_current_is_manager_of(v_target_farm);
    END IF;

    UPDATE auth.users
    SET encrypted_password = extensions.crypt(public.app_password_from_pin(p_new_pin), extensions.gen_salt('bf')),
        updated_at = NOW()
    WHERE auth.users.id = p_uid::uuid;

    UPDATE users SET pin_hash = extensions.crypt(public.app_password_from_pin(p_new_pin), extensions.gen_salt('bf'))
    WHERE id = p_uid::uuid;
END;
$$;

-- 10) admin_delete_user: يدعم system_admin
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_uid text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_target_farm uuid;
    v_caller      text;
BEGIN
    v_caller := public.current_user_role();
    SELECT farm_id INTO v_target_farm FROM users WHERE id = p_uid::uuid;

    IF v_caller = 'system_admin' THEN
        NULL; -- system_admin: يتجاوز تحقق المزرعة
    ELSE
        PERFORM public.assert_current_is_manager_of(v_target_farm);
    END IF;

    IF p_uid::uuid = auth.uid() THEN
        RAISE EXCEPTION 'لا يمكنك حذف حسابك الحالي';
    END IF;
    DELETE FROM auth.users WHERE auth.users.id = p_uid::uuid;
END;
$$;

-- 11) find_user_by_phone: يفحص is_active
CREATE OR REPLACE FUNCTION public.find_user_by_phone(p_phone text)
RETURNS TABLE (id uuid)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.id::uuid
    FROM public.users AS u
    WHERE u.phone = p_phone
      AND u.is_active = true
    LIMIT 1;
$$;

-- 12) create_farm_with_manager: RPC transactional
-- ينشئ مدجنة + مديرها في معاملة واحدة
CREATE OR REPLACE FUNCTION public.create_farm_with_manager(
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
    v_farm_id   uuid;
    v_user_id   uuid;
    v_result    jsonb;
BEGIN
    -- فقط system_admin أو المدير الأول (bootstrap) يمكنه إنشاء مدجنة
    IF NOT public.is_system_admin() THEN
        -- المدير العادي لا يستطيع إنشاء مدجنة جديدة
        RAISE EXCEPTION 'غير مصرح: فقط system_admin يمكنه إنشاء مدجنة جديدة';
    END IF;

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;

    IF EXISTS (SELECT 1 FROM users WHERE phone = p_phone) THEN
        RAISE EXCEPTION 'رقم الهاتف مسجل مسبقاً';
    END IF;

    -- إنشاء المزرعة
    INSERT INTO farms (name, location)
    VALUES (p_farm_name, NULLIF(p_location, ''))
    RETURNING id INTO v_farm_id;

    -- إنشاء حساب auth
    v_user_id := gen_random_uuid();

    INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data,
        confirmation_token, recovery_token
    ) VALUES (
        '00000000-0000-0000-0000-000000000000',
        v_user_id,
        'authenticated', 'authenticated',
        public.app_user_email(v_user_id),
        extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
        NOW(), NOW(), NOW(),
        '{"provider":"email","providers":["email"]}',
        jsonb_build_object(
            'role', 'manager',
            'farm_id', v_farm_id::text,
            'phone', p_phone,
            'full_name', p_manager_name
        ),
        '', ''
    );

    INSERT INTO auth.identities (
        provider_id, user_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
    ) VALUES (
        v_user_id::text, v_user_id,
        jsonb_build_object('sub', v_user_id::text),
        'email', NOW(), NOW(), NOW()
    );

    -- إنشاء سجل المستخدم
    INSERT INTO users (id, name, phone, role, pin_hash, farm_id, is_active)
    VALUES (
        v_user_id, p_manager_name, p_phone, 'manager',
        extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
        v_farm_id, true
    );

    SELECT jsonb_build_object(
        'user_id', v_user_id,
        'farm_id', v_farm_id,
        'email', public.app_user_email(v_user_id),
        'name', p_manager_name,
        'phone', p_phone
    ) INTO v_result;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_farm_with_manager(text, text, text, text, text) TO authenticated;

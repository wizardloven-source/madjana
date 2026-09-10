-- ============================================================
-- UPGRADE: الربط المتعدد للمداجن (multi-farm) — غير مدمر
-- ============================================================
-- يُشغَّل مرة واحدة على قاعدة بيانات مستخدمة مسبقاً (مفردة-مدجنة)
-- لإضافة، بدون حذف أي بيانات:
--   1) جدول user_farms (ربط مجموعة-إلى-مجموعة)
--   2) دوال الربط الحالي وربط المستخدمين وتعيين المدجنة النشطة
--   3) سياسات RLS المحدّثة
--   4) ربط تلقائي للمستخدمين الحاليين بمداجنهم (من عمود farm_id)
--
-- آمن لإعادة تشغيله (idempotent): كل أوامره IF NOT EXISTS /
-- DROP IF EXISTS / CREATE OR REPLACE.
-- ============================================================

BEGIN;

-- ============================================================
-- 1) جدول العلاقات + الفهرس
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_farms (
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    farm_id    UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, farm_id)
);

CREATE INDEX IF NOT EXISTS idx_user_farms_farm ON public.user_farms(farm_id);

-- ============================================================
-- 2) ربط تلقائي: كل مستخدم مرتبط بمدجنة نشطة يصبح عضواً فيها
--    (هذا يجعل المستخدمين الحاليين يظهرون فوراً في القوائم)
-- ============================================================
INSERT INTO public.user_farms (user_id, farm_id)
SELECT id, farm_id
FROM public.users
WHERE farm_id IS NOT NULL
ON CONFLICT (user_id, farm_id) DO NOTHING;

-- ============================================================
-- 3) RLS لجدول العلاقات
-- ============================================================
ALTER TABLE public.user_farms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_farms_select_own ON public.user_farms;
CREATE POLICY user_farms_select_own ON public.user_farms
    FOR SELECT TO authenticated
    USING (
        user_id = auth.uid()
        OR is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND EXISTS (
                SELECT 1 FROM public.user_farms uf2
                WHERE uf2.user_id = user_farms.user_id
                  AND uf2.farm_id = current_user_farm_id()
            )
        )
    );

DROP POLICY IF EXISTS user_farms_admin_write ON public.user_farms;
CREATE POLICY user_farms_admin_write ON public.user_farms
    FOR INSERT TO authenticated
    WITH CHECK (is_system_admin());

DROP POLICY IF EXISTS user_farms_admin_delete ON public.user_farms;
CREATE POLICY user_farms_admin_delete ON public.user_farms
    FOR DELETE TO authenticated
    USING (is_system_admin());

-- ============================================================
-- 4) دوال الهوية المتعددة
-- ============================================================
DROP FUNCTION IF EXISTS public.current_user_farm_ids();
CREATE OR REPLACE FUNCTION public.current_user_farm_ids()
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(
        ARRAY(
            SELECT uf.farm_id
            FROM public.user_farms uf
            WHERE uf.user_id = auth.uid()
            ORDER BY uf.created_at
        ),
        ARRAY[]::uuid[]
    );
$$;

DROP FUNCTION IF EXISTS public.current_user_farms_with_names();
CREATE OR REPLACE FUNCTION public.current_user_farms_with_names()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object('id', f.id, 'name', f.name)
            ORDER BY f.name
        ),
        '[]'::jsonb
    )
    FROM public.user_farms uf
    JOIN public.farms f ON f.id = uf.farm_id
    WHERE uf.user_id = auth.uid();
$$;

-- ============================================================
-- 5) تحديد المدجنة النشطة
-- ============================================================
DROP FUNCTION IF EXISTS public.set_active_farm(text);
CREATE OR REPLACE FUNCTION public.set_active_farm(
    p_farm_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_farm_uuid   uuid;
    v_user_record record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
    END IF;

    v_farm_uuid := NULLIF(p_farm_id, '')::uuid;
    IF v_farm_uuid IS NULL THEN
        RAISE EXCEPTION 'حدد المدجنة أولاً';
    END IF;

    IF NOT public.is_system_admin() THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.user_farms
            WHERE user_id = auth.uid() AND farm_id = v_farm_uuid
        ) THEN
            RAISE EXCEPTION 'أنت غير مرتبط بهذه المدجنة';
        END IF;
    END IF;

    UPDATE public.users
    SET farm_id = v_farm_uuid, updated_at = NOW()
    WHERE id = auth.uid();

    UPDATE auth.users
    SET raw_user_meta_data = raw_user_meta_data
        || jsonb_build_object('farm_id', v_farm_uuid::text)
    WHERE id = auth.uid();

    SELECT * INTO v_user_record FROM public.users WHERE id = auth.uid();
    RETURN to_jsonb(v_user_record);
END;
$$;

-- ============================================================
-- 6) إنشاء مستخدم (محدّث: يربط بالمدجنة عبر user_farms أيضًا)
-- ============================================================
DROP FUNCTION IF EXISTS public.admin_create_user(text, text, text, text, text);
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

    IF v_caller = 'system_admin' THEN
        IF p_role NOT IN ('worker', 'manager', 'system_admin') THEN
            RAISE EXCEPTION 'الدور غير صالح';
        END IF;
        IF NULLIF(p_farm_id, '') IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM farms WHERE id = NULLIF(p_farm_id, '')::uuid) THEN
            RAISE EXCEPTION 'المدجنة غير موجودة';
        END IF;
    ELSE
        IF NULLIF(p_farm_id, '') IS NULL THEN
            RAISE EXCEPTION 'يجب تحديد المدجنة';
        END IF;
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
            'role', p_role,
            'farm_id', NULLIF(p_farm_id, ''),
            'phone', p_phone,
            'full_name', p_name
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
    VALUES (v_auth_uuid, p_name, p_phone, p_role,
            extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
            NULLIF(p_farm_id, '')::uuid, true)
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        phone = EXCLUDED.phone,
        role = EXCLUDED.role,
        pin_hash = EXCLUDED.pin_hash,
        farm_id = EXCLUDED.farm_id,
        is_active = EXCLUDED.is_active
    RETURNING * INTO v_row;

    IF NULLIF(p_farm_id, '') IS NOT NULL THEN
        INSERT INTO public.user_farms (user_id, farm_id)
        VALUES (v_auth_uuid, NULLIF(p_farm_id, '')::uuid)
        ON CONFLICT (user_id, farm_id) DO NOTHING;
    END IF;

    RETURN to_jsonb(v_row);
END;
$$;

-- ============================================================
-- 7) إنشاء مزرعة + مدير (محدّث)
-- ============================================================
DROP FUNCTION IF EXISTS public.create_farm_with_manager(text, text, text, text, text);
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
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: فقط system_admin يمكنه إنشاء مزرعة جديدة';
    END IF;

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;

    IF EXISTS (SELECT 1 FROM users WHERE phone = p_phone) THEN
        RAISE EXCEPTION 'رقم الهاتف مسجل مسبقاً';
    END IF;

    INSERT INTO farms (name, location)
    VALUES (p_farm_name, NULLIF(p_location, ''))
    RETURNING id INTO v_farm_id;

    v_user_id := gen_random_uuid();

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
        gen_random_uuid(), v_user_id::text, v_user_id,
        jsonb_build_object(
            'sub', v_user_id::text,
            'email', public.app_user_email(v_user_id),
            'email_verified', true,
            'phone_verified', false
        ),
        'email', NOW(), NOW(), NOW()
    );

    INSERT INTO users (id, name, phone, role, pin_hash, farm_id, is_active)
    VALUES (
        v_user_id, p_manager_name, p_phone, 'manager',
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

    INSERT INTO public.user_farms (user_id, farm_id)
    VALUES (v_user_id, v_farm_id)
    ON CONFLICT (user_id, farm_id) DO NOTHING;

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

-- ============================================================
-- 8) إنشاء مدجنة فقط (system_admin)
-- ============================================================
DROP FUNCTION IF EXISTS public.admin_create_farm(text, text);
CREATE OR REPLACE FUNCTION public.admin_create_farm(
    p_farm_name text,
    p_location text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_farm_record record;
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: فقط system_admin يمكنه إنشاء مدجنة';
    END IF;
    IF NULLIF(p_farm_name, '') IS NULL THEN
        RAISE EXCEPTION 'أدخل اسم المدجنة';
    END IF;
    INSERT INTO public.farms (name, location)
    VALUES (p_farm_name, NULLIF(p_location, ''))
    RETURNING * INTO v_farm_record;
    RETURN to_jsonb(v_farm_record);
END;
$$;

-- ============================================================
-- 9) ربط مستخدم بمدجنة (إضافة فقط، بدون تحويل)
-- ============================================================
DROP FUNCTION IF EXISTS public.admin_assign_user_to_farm(text, text);
CREATE OR REPLACE FUNCTION public.admin_assign_user_to_farm(
    p_uid text,
    p_farm_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_record record;
    v_farm_uuid   uuid;
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: فقط system_admin يمكنه ربط المستخدمين بالمداجن';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_uid::uuid) THEN
        RAISE EXCEPTION 'المستخدم غير موجود';
    END IF;

    v_farm_uuid := NULLIF(p_farm_id, '')::uuid;
    IF v_farm_uuid IS NULL THEN
        RAISE EXCEPTION 'حدد المدجنة أولاً';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.farms WHERE id = v_farm_uuid) THEN
        RAISE EXCEPTION 'المدجنة غير موجودة';
    END IF;

    INSERT INTO public.user_farms (user_id, farm_id)
    VALUES (p_uid::uuid, v_farm_uuid)
    ON CONFLICT (user_id, farm_id) DO NOTHING;

    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_uid::uuid AND farm_id IS NOT NULL) THEN
        UPDATE public.users
        SET farm_id = v_farm_uuid, updated_at = NOW()
        WHERE id = p_uid::uuid;
        UPDATE auth.users
        SET raw_user_meta_data = raw_user_meta_data
            || jsonb_build_object('farm_id', v_farm_uuid::text)
        WHERE id = p_uid::uuid;
    END IF;

    SELECT * INTO v_user_record FROM public.users WHERE id = p_uid::uuid;
    RETURN to_jsonb(v_user_record);
END;
$$;

-- ============================================================
-- 10) فكّ ربط مستخدم بمدجنة
-- ============================================================
DROP FUNCTION IF EXISTS public.admin_unassign_user_from_farm(text, text);
CREATE OR REPLACE FUNCTION public.admin_unassign_user_from_farm(
    p_uid text,
    p_farm_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_record record;
    v_farm_uuid   uuid;
    v_new_active  uuid;
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: فقط system_admin يمكنه فك ربط المستخدمين بالمداجن';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_uid::uuid) THEN
        RAISE EXCEPTION 'المستخدم غير موجود';
    END IF;

    v_farm_uuid := NULLIF(p_farm_id, '')::uuid;
    IF v_farm_uuid IS NULL THEN
        RAISE EXCEPTION 'حدد المدجنة أولاً';
    END IF;

    DELETE FROM public.user_farms
    WHERE user_id = p_uid::uuid AND farm_id = v_farm_uuid;

    -- إذا كانت المدجنة المُزالة هي النشطة، انقل النشاط إلى مدجنة أخرى أو افرغه
    IF EXISTS (SELECT 1 FROM public.users WHERE id = p_uid::uuid AND farm_id = v_farm_uuid) THEN
        SELECT farm_id INTO v_new_active
        FROM public.user_farms
        WHERE user_id = p_uid::uuid AND farm_id <> v_farm_uuid
        ORDER BY created_at
        LIMIT 1;

        IF v_new_active IS NOT NULL THEN
            UPDATE public.users
            SET farm_id = v_new_active, updated_at = NOW()
            WHERE id = p_uid::uuid;
            UPDATE auth.users
            SET raw_user_meta_data = raw_user_meta_data
                || jsonb_build_object('farm_id', v_new_active::text)
            WHERE id = p_uid::uuid;
        ELSE
            UPDATE public.users
            SET farm_id = NULL, updated_at = NOW()
            WHERE id = p_uid::uuid;
            UPDATE auth.users
            SET raw_user_meta_data = raw_user_meta_data - 'farm_id'
            WHERE id = p_uid::uuid;
        END IF;
    END IF;

    SELECT * INTO v_user_record FROM public.users WHERE id = p_uid::uuid;
    RETURN to_jsonb(v_user_record);
END;
$$;

-- ============================================================
-- 11) كل المستخدمين مع مداجنهم (system_admin فقط)
-- ============================================================
DROP FUNCTION IF EXISTS public.admin_select_all_users_with_farms();
CREATE OR REPLACE FUNCTION public.admin_select_all_users_with_farms()
RETURNS TABLE (
    user_id        uuid,
    active_farm_id uuid,
    name           text,
    phone          text,
    role           text,
    is_active      boolean,
    created_at     timestamptz,
    updated_at     timestamptz,
    farm_ids       text[]
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        u.id                   AS user_id,
        u.farm_id              AS active_farm_id,
        u.name                 AS name,
        u.phone                AS phone,
        u.role::text           AS role,
        u.is_active            AS is_active,
        u.created_at           AS created_at,
        u.updated_at           AS updated_at,
        COALESCE(
            ARRAY(
                SELECT uf.farm_id::text
                FROM public.user_farms uf
                WHERE uf.user_id = u.id
                ORDER BY uf.created_at
            ),
            ARRAY[]::text[]
        )                      AS farm_ids
    FROM public.users u
    WHERE public.is_system_admin()
    ORDER BY u.created_at;
$$;

-- ============================================================
-- 12) إدارة المستخدمين (استبدال لضمان التطابق مع المخطط الحالي)
-- ============================================================
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
        NULL;
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
        NULL;
    ELSE
        PERFORM public.assert_current_is_manager_of(v_target_farm);
    END IF;

    IF p_uid::uuid = auth.uid() THEN
        RAISE EXCEPTION 'لا يمكنك حذف حسابك الحالي';
    END IF;
    DELETE FROM auth.users WHERE auth.users.id = p_uid::uuid;
END;
$$;

-- ============================================================
-- 13) سياسات users محدّثة (عامل متعدد المداجن للمدير)
-- ============================================================
DROP POLICY IF EXISTS users_select_self ON public.users;
CREATE POLICY users_select_self ON public.users
    FOR SELECT TO authenticated
    USING (
        id = auth.uid()
        OR is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND (
                role = 'system_admin'
                OR EXISTS (
                    SELECT 1 FROM public.user_farms uf
                    WHERE uf.user_id = users.id
                      AND uf.farm_id = current_user_farm_id()
                )
            )
        )
    );

DROP POLICY IF EXISTS users_update_self ON public.users;
CREATE POLICY users_update_self ON public.users
    FOR UPDATE TO authenticated
    USING (
        id = auth.uid()
        OR is_system_admin()
        OR current_user_role() = 'manager'
    )
    WITH CHECK (
        id = auth.uid()
        OR is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND EXISTS (
                SELECT 1 FROM public.user_farms uf
                WHERE uf.user_id = users.id
                  AND uf.farm_id = current_user_farm_id()
            )
        )
    );

-- ============================================================
-- 13b) الزبائن: نطاق المشاركة (المدير/النظام عام، والعامل مدجنته فقط) + RLS
-- ============================================================
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS is_global BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.customers_scope_guard()
RETURNS TRIGGER AS $$
BEGIN
    NEW.is_global := COALESCE(current_user_role() IN ('manager', 'system_admin'), false);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_customers_scope_guard ON public.customers;
CREATE TRIGGER trg_customers_scope_guard
    BEFORE INSERT ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.customers_scope_guard();

-- إعادة تعريف الدالة لتشمل فرع الزبائن (متطابقة مع UNIFIED)
CREATE OR REPLACE FUNCTION public.ensure_operational_policies(p_table name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_customers boolean := (p_table = 'customers');
BEGIN
    EXECUTE format('DROP POLICY IF EXISTS op_select ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_insert ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_update ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_delete ON %I', p_table);

    IF v_customers THEN
        EXECUTE format('CREATE POLICY op_select ON %I FOR SELECT TO authenticated USING (is_system_admin() OR is_global OR farm_id = current_user_farm_id())', p_table);
        EXECUTE format('CREATE POLICY op_insert ON %I FOR INSERT TO authenticated WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
        EXECUTE format('CREATE POLICY op_update ON %I FOR UPDATE TO authenticated USING (is_system_admin() OR is_global OR farm_id = current_user_farm_id()) WITH CHECK (is_system_admin() OR is_global OR farm_id = current_user_farm_id())', p_table);
        EXECUTE format('CREATE POLICY op_delete ON %I FOR DELETE TO authenticated USING ((is_system_admin() OR is_global OR farm_id = current_user_farm_id()) AND (is_system_admin() OR current_user_role() = ''manager''))', p_table);
    ELSE
        EXECUTE format('CREATE POLICY op_select ON %I FOR SELECT TO authenticated USING (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
        EXECUTE format('CREATE POLICY op_insert ON %I FOR INSERT TO authenticated WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
        EXECUTE format('CREATE POLICY op_update ON %I FOR UPDATE TO authenticated USING (is_system_admin() OR farm_id = current_user_farm_id()) WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
        EXECUTE format('CREATE POLICY op_delete ON %I FOR DELETE TO authenticated USING ((is_system_admin() OR farm_id = current_user_farm_id()) AND (is_system_admin() OR current_user_role() = ''manager''))', p_table);
    END IF;
END;
$$;

-- تطبيق سياسات الزبائن (نطاق المشاركة الجديد)
SELECT public.ensure_operational_policies('customers');

-- ============================================================
-- 14) Grant permissions
-- ============================================================
GRANT EXECUTE ON FUNCTION public.current_user_farm_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farms_with_names() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_active_farm(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_user(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_farm_with_manager(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_farm(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_assign_user_to_farm(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unassign_user_from_farm(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_select_all_users_with_farms() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
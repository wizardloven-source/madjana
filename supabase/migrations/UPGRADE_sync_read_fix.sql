-- ============================================================================
-- ترقية: إصلاح سحب البيانات (pull) بين الأجهزة
--
-- ملاحظة: ملف إضافي (additive) - لا يمسح أي بيانات.
-- يُطبَّق في محرر SQL الخاص بـ Supabase (SQL Editor).
--
-- المشكلة:
-- دالة pull_remote_changes الموجودة فعلياً في قاعدة البيانات نسخة قديمة
-- فيها خطأ GROUP BY (رمز 42803)، فكان سحب الديسكتوب يفشل دائماً
-- ("column sc.server_version must appear in the GROUP BY...") ولم تصل أي
-- بيانات من الأجهزة الأخرى. كما أن سلسلة الصيانة (cleanup/compact/
-- refresh/auto_maintain) غير مضمونة الوجود في القاعدة الحية.
--
-- الحل (هنا): إعادة إنشاء سلسلة السحب كاملة بنسختها الصحيحة المطابقة
-- لـ UNIFIED_schema.sql (المرجع الأساسي)، وكل الأوامر متسامحة
-- (CREATE OR REPLACE / IF NOT EXISTS) — أي أعمدة/دوال ناقصة تُنشأ،
-- والموجودة تُستبدل بالنسخة الصحيحة.
-- ============================================================================

-- 1) جدول نقطة التزامن (بدون بيان Drop — إضافي وآمن)
CREATE TABLE IF NOT EXISTS public.sync_checkpoint (
    farm_id           UUID PRIMARY KEY REFERENCES farms(id) ON DELETE CASCADE,
    latest_version    BIGINT NOT NULL DEFAULT 0,
    purged_below      BIGINT NOT NULL DEFAULT 0,
    last_maintenance  TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_sync_checkpoint_latest ON public.sync_checkpoint(latest_version);
-- لو الجدول موجود بنسخة قديمة ناقصة الأعمدة
ALTER TABLE public.sync_checkpoint ADD COLUMN IF NOT EXISTS latest_version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE public.sync_checkpoint ADD COLUMN IF NOT EXISTS purged_below BIGINT NOT NULL DEFAULT 0;
ALTER TABLE public.sync_checkpoint ADD COLUMN IF NOT EXISTS last_maintenance TIMESTAMPTZ;
ALTER TABLE public.sync_checkpoint ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- 2) تنظيف السجلات القديمة
CREATE OR REPLACE FUNCTION public.cleanup_old_sync_changes(
    p_keep_days int DEFAULT NULL,
    p_farm_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_keep_days int;
BEGIN
    IF NOT (public.is_system_admin() OR public.current_user_role() = 'manager') THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: غير مسموح بتنظيف المزامنة';
    END IF;

    v_keep_days := COALESCE(p_keep_days, 30);
    IF v_keep_days < 1 THEN
        RAISE EXCEPTION 'VALIDATION_ERROR: فترة الاحتفاظ يجب أن تكون يوماً واحداً على الأقل';
    END IF;

    IF public.is_system_admin() THEN
        DELETE FROM sync_changes
        WHERE created_at < NOW() - (v_keep_days || ' days')::interval
          AND (p_farm_id IS NULL OR farm_id = p_farm_id);
        IF p_farm_id IS NULL THEN
            PERFORM public.refresh_sync_checkpoint(NULL, true);
        ELSE
            PERFORM public.refresh_sync_checkpoint(p_farm_id);
        END IF;
    ELSE
        DELETE FROM sync_changes
        WHERE farm_id = public.current_user_farm_id()
          AND created_at < NOW() - (v_keep_days || ' days')::interval;
        PERFORM public.refresh_sync_checkpoint(public.current_user_farm_id());
    END IF;
END;
$$;

-- 3) ضغط التحديثات المتتالية
CREATE OR REPLACE FUNCTION public.compact_sync_changes(
    p_farm_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_base bigint := 0;
    v_f    record;
BEGIN
    IF NOT (public.is_system_admin() OR public.current_user_role() = 'manager') THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: غير مسموح بضغط المزامنة';
    END IF;

    IF public.is_system_admin() THEN
        IF p_farm_id IS NOT NULL THEN
            v_base := COALESCE((SELECT purged_below FROM sync_checkpoint WHERE farm_id = p_farm_id), 0);
            DELETE FROM sync_changes prev
            USING sync_changes sc
            WHERE prev.farm_id = p_farm_id
              AND prev.operation = 'UPDATE'
              AND prev.server_version > v_base
              AND sc.farm_id = prev.farm_id
              AND sc.table_name = prev.table_name
              AND sc.record_id = prev.record_id
              AND sc.operation = 'UPDATE'
              AND sc.server_version > prev.server_version
              AND NOT EXISTS (
                  SELECT 1 FROM sync_changes mid
                  WHERE mid.farm_id = prev.farm_id
                    AND mid.table_name = prev.table_name
                    AND mid.record_id = prev.record_id
                    AND mid.server_version > prev.server_version
                    AND mid.server_version < sc.server_version
                    AND mid.operation <> 'UPDATE'
              );
        ELSE
            PERFORM public.refresh_sync_checkpoint(NULL, true);
            FOR v_f IN SELECT id FROM public.farms LOOP
                PERFORM public.compact_sync_changes(v_f.id);
            END LOOP;
            RETURN;
        END IF;
    ELSE
        v_base := COALESCE((SELECT purged_below FROM sync_checkpoint WHERE farm_id = public.current_user_farm_id()), 0);
        DELETE FROM sync_changes prev
        USING sync_changes sc
        WHERE prev.farm_id = public.current_user_farm_id()
          AND prev.operation = 'UPDATE'
          AND prev.server_version > v_base
          AND sc.farm_id = prev.farm_id
          AND sc.table_name = prev.table_name
          AND sc.record_id = prev.record_id
          AND sc.operation = 'UPDATE'
          AND sc.server_version > prev.server_version
          AND NOT EXISTS (
              SELECT 1 FROM sync_changes mid
              WHERE mid.farm_id = prev.farm_id
                AND mid.table_name = prev.table_name
                AND mid.record_id = prev.record_id
                AND mid.server_version > prev.server_version
                AND mid.server_version < sc.server_version
                AND mid.operation <> 'UPDATE'
          );
    END IF;

    IF public.is_system_admin() AND p_farm_id IS NULL THEN
        NULL;
    ELSIF public.is_system_admin() THEN
        PERFORM public.refresh_sync_checkpoint(p_farm_id);
    ELSE
        PERFORM public.refresh_sync_checkpoint(public.current_user_farm_id());
    END IF;
END;
$$;

-- 4) تحديث نقطة التزامن
CREATE OR REPLACE FUNCTION public.refresh_sync_checkpoint(
    p_farm_id uuid DEFAULT NULL,
    p_all boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_f record;
BEGIN
    IF p_all THEN
        FOR v_f IN SELECT id FROM public.farms LOOP
            PERFORM public.refresh_sync_checkpoint(v_f.id);
        END LOOP;
        RETURN;
    END IF;

    IF p_farm_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_ERROR: يجب تحديد مزرعة أو p_all = true';
    END IF;

    INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, updated_at)
    SELECT
        p_farm_id,
        COALESCE((SELECT MAX(server_version) FROM sync_changes WHERE farm_id = p_farm_id), 0),
        COALESCE((SELECT MIN(server_version) FROM sync_changes WHERE farm_id = p_farm_id), 0),
        NOW()
    ON CONFLICT (farm_id) DO UPDATE SET
        latest_version = EXCLUDED.latest_version,
        purged_below   = EXCLUDED.purged_below,
        updated_at     = NOW();
END;
$$;

-- 5) صيانة تلقائية عند السحب (مرة كل 6 ساعات لكل مزرعة)
CREATE OR REPLACE FUNCTION public.auto_maintain_sync()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_farm      uuid;
    v_interval  interval;
    v_last      timestamptz;
BEGIN
    v_farm := public.current_user_farm_id();
    IF v_farm IS NULL THEN
        RETURN;
    END IF;

    v_interval := make_interval(mins => 360);

    SELECT last_maintenance INTO v_last
    FROM sync_checkpoint WHERE farm_id = v_farm;

    IF v_last IS NOT NULL AND v_last > NOW() - v_interval THEN
        RETURN;
    END IF;

    PERFORM public.cleanup_old_sync_changes(NULL, v_farm);
    PERFORM public.compact_sync_changes(v_farm);

    INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, last_maintenance, updated_at)
    SELECT
        v_farm,
        COALESCE((SELECT MAX(server_version) FROM sync_changes WHERE farm_id = v_farm), 0),
        COALESCE((SELECT MIN(server_version) FROM sync_changes WHERE farm_id = v_farm), 0),
        NOW(), NOW()
    ON CONFLICT (farm_id) DO UPDATE SET
        latest_version    = EXCLUDED.latest_version,
        purged_below      = EXCLUDED.purged_below,
        last_maintenance  = NOW(),
        updated_at        = NOW();
END;
$$;

-- 6) سحب التغييرات (النسخة المصححة — بلا خطأ GROUP BY)
CREATE OR REPLACE FUNCTION public.pull_remote_changes(
    p_farm_id uuid,
    p_from_version bigint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role     text;
    v_latest   bigint;
    v_min_keep bigint;
    v_changes  jsonb;
    v_cp       record;
    v_operational_only boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: غير مسجل الدخول';
    END IF;

    IF NOT public.is_system_admin() THEN
        SELECT public.current_user_role() INTO v_role;
        IF v_role NOT IN ('manager', 'worker') THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: دور غير مصرح بسحب المزامنة';
        END IF;
        IF p_farm_id IS DISTINCT FROM public.current_user_farm_id() THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: مزرعة غير مصرح بها';
        END IF;
        IF v_role = 'worker' THEN
            v_operational_only := true;
        END IF;
    END IF;

    PERFORM public.auto_maintain_sync();

    SELECT latest_version, purged_below INTO v_latest, v_min_keep
    FROM sync_checkpoint WHERE farm_id = p_farm_id;

    IF v_latest IS NULL THEN
        SELECT COALESCE(MAX(server_version), 0), COALESCE(MIN(server_version), 0)
            INTO v_latest, v_min_keep
        FROM sync_changes WHERE farm_id = p_farm_id;
        IF v_min_keep = 0 THEN v_min_keep := v_latest; END IF;
        INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, updated_at)
        VALUES (p_farm_id, v_latest, v_min_keep, NOW())
        ON CONFLICT (farm_id) DO UPDATE SET
            latest_version = EXCLUDED.latest_version,
            purged_below   = EXCLUDED.purged_below,
            updated_at     = NOW();
    END IF;

    IF v_operational_only THEN
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        )) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND public.sync_can_read('worker', sc.table_name)
          AND sc.server_version > p_from_version
        ORDER BY sc.server_version ASC;

        SELECT COALESCE(MAX(server_version), p_from_version) INTO v_latest
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name)
          AND server_version > p_from_version;

        SELECT COALESCE(MIN(server_version), v_latest) INTO v_min_keep
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name);
    ELSE
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        )) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND sc.server_version > p_from_version
        ORDER BY sc.server_version ASC;
    END IF;

    IF p_from_version > 0 AND p_from_version < v_min_keep THEN
        RETURN jsonb_build_object(
            'resync_required', true,
            'message', 'بيانات الجهاز أقدم من فترة الاحتفاظ، يلزم إعادة مزامنة كاملة',
            'latest_version', v_latest
        );
    END IF;

    RETURN jsonb_build_object(
        'resync_required', false,
        'latest_version', v_latest,
        'changes', COALESCE(v_changes, '[]'::jsonb)
    );
END;
$$;

-- 7) الصلاحيات (نفسها الموجودة في UNIFIED_schema.sql)
GRANT EXECUTE ON FUNCTION public.pull_remote_changes(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_old_sync_changes(int, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.compact_sync_changes(uuid) TO authenticated;
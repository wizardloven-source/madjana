-- ============================================================
-- UPGRADE: sync_live_ids + الزبائن العامة (is_global)
-- سبب: كان التطبيق يحذف محلياً أي زبون عام (is_global) غير
--       مرتبط بمزرعة المستخدم، لأن sync_live_ids كان يجلب فقط
--       أرقام الفارم المطلوبة (farm_id = $1) فيغيب الزبون العام
--       من القائمة فيحذفه _reconcileServerDeleted من الجهاز.
-- الحل: جلب الزبائن العامة أيضاً للقراءة عبر is_global = TRUE.
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_live_ids(p_farm_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role  text;
    v_tables text[] := '{}'::text[];
    v_t     text;
    v_ids   jsonb;
    v_result jsonb := '{}'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED';
    END IF;

    v_role := current_user_role();
    IF NOT is_system_admin() AND current_user_farm_id() IS DISTINCT FROM p_farm_id THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED';
    END IF;

    IF is_system_admin() OR v_role = 'manager' THEN
        v_tables := ARRAY['flocks','egg_production','mortality','feed_consumption',
                          'feed_received','egg_dispatch','medications','customers',
                          'expenses','inventory_items','inventory_transactions',
                          'opening_balances','payments'];
    ELSIF v_role = 'worker' THEN
        v_tables := ARRAY['egg_production','mortality','feed_consumption',
                          'feed_received','egg_dispatch','medications'];
    ELSE
        RAISE EXCEPTION 'AUTHORIZATION_DENIED';
    END IF;

    FOREACH v_t IN ARRAY v_tables LOOP
        IF NOT public.sync_can_read(v_role, v_t) THEN
            CONTINUE;
        END IF;
        BEGIN
            IF v_t = 'customers' THEN
                -- الزبائن العامة (is_global) يُبقيها كلُّ مزارع حسب الصلاحية
                EXECUTE format($q$
                    SELECT COALESCE(jsonb_agg(id::text ORDER BY id::text), '[]'::jsonb)
                    FROM public.%I
                    WHERE (farm_id = $1 OR is_global = TRUE) AND deleted_at IS NULL
                $q$, v_t) INTO v_ids USING p_farm_id;
            ELSE
                EXECUTE format($q$
                    SELECT COALESCE(jsonb_agg(id::text ORDER BY id::text), '[]'::jsonb)
                    FROM public.%I
                    WHERE farm_id = $1 AND deleted_at IS NULL
                $q$, v_t) INTO v_ids USING p_farm_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            CONTINUE;
        END;
        v_result := v_result || jsonb_build_object(v_t, v_ids);
    END LOOP;

RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_live_ids(uuid) TO authenticated;
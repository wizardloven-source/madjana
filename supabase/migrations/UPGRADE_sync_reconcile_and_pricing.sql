-- ============================================================
-- UPGRADE: مصالحة الحذف المركزي + قائمة مستخدمي المدجنة + وزن الكيس
-- ============================================================
-- 1) sync_live_ids(uuid): يعيد معرّفات السجلات الحيّة (غير المحذوفة) لكل
--    جدول قابل للمزامنة في مدجنة محددة — يستخدمها الجهاز لمسح سجلاته
--    المحلية التي لم تعد موجودة على الخادم (حذف مباشر من لوحة SQL/
--    عرض الجداول لا يولّد tombstone في sync_changes).
-- 2) get_farm_users(uuid): يعيد مستخدمي المدجنة (مدير + عمال + سوبر أدمن)
--    بغض النظر عن وجود ربط في user_farms — يصلح شاشة المستخدمين في سطح المكتب.
-- 3) إرخاء قيد check_feed_received_mode ليعتمد وزن الكيس على
--    farms.feed_bag_weight_kg بدلاً من الثابت 24.
-- ============================================================

-- ------------------------------------------------------------
-- (1) معرّفات السجلات الحيّة
-- ------------------------------------------------------------
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
            EXECUTE format($q$
                SELECT COALESCE(jsonb_agg(id::text ORDER BY id::text), '[]'::jsonb)
                FROM public.%I
                WHERE farm_id = $1 AND deleted_at IS NULL
            $q$, v_t) INTO v_ids USING p_farm_id;
        EXCEPTION WHEN OTHERS THEN
            CONTINUE;
        END;
        v_result := v_result || jsonb_build_object(v_t, v_ids);
    END LOOP;

    RETURN v_result;
END; $$;

GRANT EXECUTE ON FUNCTION public.sync_live_ids(uuid) TO authenticated;

-- ------------------------------------------------------------
-- (2) قائمة مستخدمي مدجنة محددة (مدير/سوبر أدمن)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_farm_users(p_farm_id uuid)
RETURNS TABLE (
    uid        uuid,
    name       text,
    phone      text,
    role       text,
    farm_id    uuid,
    is_active  boolean,
    created_at timestamptz,
    farm_ids   jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED';
    END IF;

    v_role := current_user_role();
    IF NOT is_system_admin()
       AND (v_role <> 'manager' OR current_user_farm_id() IS DISTINCT FROM p_farm_id) THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED';
    END IF;

    RETURN QUERY
    SELECT
        u.id,
        COALESCE(u.name, ''),
        COALESCE(u.phone, ''),
        u.role::text,
        u.farm_id,
        COALESCE(u.is_active, true),
        u.created_at,
        COALESCE((
            SELECT jsonb_agg(uf.farm_id ORDER BY uf.farm_id)
            FROM public.user_farms uf
            WHERE uf.user_id = u.id
        ), '[]'::jsonb) AS farm_ids
    FROM public.users u
    WHERE (u.role = 'system_admin'
           OR u.farm_id = p_farm_id
           OR EXISTS (
               SELECT 1 FROM public.user_farms uf2
               WHERE uf2.user_id = u.id AND uf2.farm_id = p_farm_id
           )
           OR u.id = auth.uid())
    ORDER BY u.created_at ASC;
END; $$;

GRANT EXECUTE ON FUNCTION public.get_farm_users(uuid) TO authenticated;

-- ------------------------------------------------------------
-- (3) وزن الكيس من إعدادات المدجنة بدلاً من الثابت 24
-- ------------------------------------------------------------
ALTER TABLE public.feed_received DROP CONSTRAINT IF EXISTS check_feed_received_mode;

ALTER TABLE public.feed_received
    ADD CONSTRAINT check_feed_received_mode CHECK (
        (quantity > 0) AND (
            (entry_mode = 'bags' AND quantity_kg = quantity *
                COALESCE(
                    (SELECT feed_bag_weight_kg FROM public.farms
                     WHERE id = feed_received.farm_id),
                    24
                )
            ) OR
            (entry_mode = 'kg'   AND quantity_kg = quantity) OR
            (entry_mode = 'ton'  AND quantity_kg = quantity * 1000)
        )
    );
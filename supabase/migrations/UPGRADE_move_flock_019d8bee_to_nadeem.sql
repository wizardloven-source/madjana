-- ============================================================
-- UPGRADE / REPAIR: نقل القطيع 019d8bee (بياض كبير) من "المدجنة" إلى "نديم بركات"
-- ------------------------------------------------------------
-- السبب الجذري: قبل migration 00800/00801 كان sync_records_batch يختم farm_id
--   من current_user_farm_id() (المزرعة "النشطة" وقت الرفع) لا من farm_id الحقيقي.
--   القطيع 019d8bee (1250 -> 1021 طائر) سُجّل تحت المدجنة (12141b73...)
--   بدل نديم بركات (ea124a67...).
--   المرجع: 20260926000800_farm_membership_authorization.sql:25-28
--
-- ماذا يفعل (بنطاق "القطيع + كل سجلاته"):
--   1) ينقل صف flocks نفسه (أولاً — تريغر validate_flock_farm يقارن الجداول
--      التابعة بـ flocks.farm_id، فيجب أن يسبقها).
--   2) ينقل السجلات التشغيلية: egg_production, mortality, feed_consumption,
--      feed_received, medications, opening_balances.
--   3) ينقل egg_dispatch و dispatch_requests فقط إذا كان الزبون يخصّ نديم بركات
--      (customer.farm_id = نديم). الزبائن العامّون (is_global) والزبائن التابعون
--      للمدجنة تبقى سجلاتهم تحت المدجنة، لأن تريغر validate_dispatch_refs يقارن
--      customer.farm_id بـ farm_id ولا يستثني is_global — فنقلها يُرفض.
--      (تُطبع أعداد السجلات المتبقية في نهاية السكربت.)
--   4) يدفع صفوف sync_changes (UPDATE) لمزرعة نديم لتسحبها أجهزته. أما أجهزة
--      المدجنة فتُزيل السجلات محلياً عبر sync_live_ids (لم تعد ضمن مجموعتها الحيّة).
--   5) يسجّل العملية في audit_log.
--
-- IDEMPOTENT: كل تحديث مشروط بـ farm_id = المدجنة، فإعادة التشغيل لا تغيّر شيئاً.
-- لا ينفّذ أي INSERT/DELETE — تحديثات فقط.
-- ============================================================

DO $$
DECLARE
    v_flock  CONSTANT uuid := '019d8bee-4b97-4fb5-b27c-9bc822443df0';
    v_from   CONSTANT uuid := '12141b73-ebee-4ab0-be31-80195b759303';  -- المدجنة
    v_to     CONSTANT uuid := 'ea124a67-e18f-4694-841e-e704356ffe4b';  -- نديم بركات
    v_dev    CONSTANT text := 'repair-019d8bee-to-nadeem';
    v_t      text;
    v_n      bigint;
BEGIN
    -- منع تريغر populate_sync_changes من التوليد التلقائي (auth.uid() NULL أصلاً،
    -- لكن نضمن ذلك) لأننا ندفع sync_changes يدوياً بمزرعة الهدف.
    PERFORM set_config('app.skip_sync_trigger', 'on', true);

    IF NOT EXISTS (
        SELECT 1 FROM public.flocks WHERE id = v_flock AND farm_id = v_from
    ) THEN
        RAISE NOTICE 'SKIP: القطيع % ليس تحت المدجنة — لا إجراء (idempotent).', v_flock;
        RETURN;
    END IF;

    -- (1) القطيع أولاً
    UPDATE public.flocks
       SET farm_id = v_to, updated_at = NOW(), version = version + 1
     WHERE id = v_flock AND farm_id = v_from;

    -- (2) السجلات التشغيلية التابعة
    UPDATE public.egg_production
       SET farm_id = v_to, updated_at = NOW(), version = version + 1
     WHERE flock_id = v_flock AND farm_id = v_from;

    UPDATE public.mortality
       SET farm_id = v_to, updated_at = NOW(), version = version + 1
     WHERE flock_id = v_flock AND farm_id = v_from;

    UPDATE public.feed_consumption
       SET farm_id = v_to, updated_at = NOW(), version = version + 1
     WHERE flock_id = v_flock AND farm_id = v_from;

    UPDATE public.feed_received
       SET farm_id = v_to, updated_at = NOW(), version = version + 1
     WHERE flock_id = v_flock AND farm_id = v_from;

    UPDATE public.medications
       SET farm_id = v_to, updated_at = NOW(), version = version + 1
     WHERE flock_id = v_flock AND farm_id = v_from;

    UPDATE public.opening_balances
       SET farm_id = v_to
     WHERE flock_id = v_flock AND farm_id = v_from;

    -- (3) السجلات المرتبطة بزبائن — تُنقل فقط إذا كان الزبون يخصّ نديم بركات
    UPDATE public.egg_dispatch d
       SET farm_id = v_to, updated_at = NOW(), version = version + 1
     WHERE d.flock_id = v_flock AND d.farm_id = v_from
       AND EXISTS (
             SELECT 1 FROM public.customers c
              WHERE c.id = d.customer_id
                AND c.farm_id = v_to
           );

    UPDATE public.dispatch_requests dr
       SET farm_id = v_to
     WHERE dr.flock_id = v_flock AND dr.farm_id = v_from
       AND (
             dr.customer_id IS NULL
          OR EXISTS (
                SELECT 1 FROM public.customers c
                 WHERE c.id = dr.customer_id
                   AND c.farm_id = v_to
             )
           );

    -- (4) دفع sync_changes (UPDATE) لمزرعة نديم لكل جدول بعد النقل
    FOREACH v_t IN ARRAY ARRAY[
        'flocks', 'egg_production', 'mortality', 'feed_consumption',
        'feed_received', 'medications', 'opening_balances',
        'egg_dispatch', 'dispatch_requests'
    ] LOOP
        IF v_t = 'flocks' THEN
            EXECUTE $q$
                INSERT INTO public.sync_changes
                    (table_name, record_id, operation, farm_id, device_id, user_id, payload)
                SELECT 'flocks', x.id, 'UPDATE', $1, $2, NULL,
                       to_jsonb(x) - 'sync_status' - 'deleted_at'
                  FROM public.flocks x
                 WHERE x.id = $3 AND x.farm_id = $1
            $q$ USING v_to, v_dev, v_flock;
        ELSE
            EXECUTE format($q$
                INSERT INTO public.sync_changes
                    (table_name, record_id, operation, farm_id, device_id, user_id, payload)
                SELECT %L, x.id, 'UPDATE', $1, $2, NULL,
                       to_jsonb(x) - 'sync_status' - 'deleted_at'
                  FROM public.%I x
                 WHERE x.flock_id = $3 AND x.farm_id = $1
            $q$, v_t, v_t) USING v_to, v_dev, v_flock;
        END IF;
    END LOOP;

    -- (5) سجل تدقيق
    INSERT INTO public.audit_log
        (farm_id, user_id, action, table_name, record_id, old_values, new_values, device_id)
    VALUES
        (v_to, NULL, 'UPDATE', 'flocks', v_flock,
         jsonb_build_object('farm_id', v_from, 'note', 'كان مسكّناً خطأً تحت المدجنة'),
         jsonb_build_object('farm_id', v_to),
         v_dev);

    -- إبلاغ عن سجلات البيع/التوزيع التي بقيت تحت المدجنة (زبونها لا يخصّ نديم)
    SELECT count(*) INTO v_n FROM public.egg_dispatch
     WHERE flock_id = v_flock AND farm_id = v_from;
    IF v_n > 0 THEN
        RAISE NOTICE 'تنبيه: % سجل egg_dispatch بقي تحت المدجنة (زبونها لا يخصّ نديم).', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM public.dispatch_requests
     WHERE flock_id = v_flock AND farm_id = v_from;
    IF v_n > 0 THEN
        RAISE NOTICE 'تنبيه: % سجل dispatch_requests بقي تحت المدجنة (زبونها لا يخصّ نديم).', v_n;
    END IF;

    RAISE NOTICE 'OK: نُقل القطيع % إلى نديم بركات مع سجلاته، ودُفعت صفوف sync_changes.', v_flock;
END $$;

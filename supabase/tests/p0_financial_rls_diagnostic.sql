-- ============================================================================
--  p0_financial_rls_diagnostic.sql   —   تشخيص فقط، لا يغيّر أي شيء
-- ============================================================================
--  الهدف: إثبات ما إذا كانت ثغرة تصعيد الصلاحيات P0 حيّة على الإنتاج.
--  المرجع: ANALYSIS_REPORT.md § 7.1 و migration 20260926000800 (سطر 254-301).
--
--  ── قاعدة إلزامية قبل التشغيل ─────────────────────────────────────────────
--  المشروع لا يستخدم FORCE ROW LEVEL SECURITY في أي مكان. لذلك:
--    * تشغيل هذا الملف كـ postgres (superuser)  ➜  RLS يُتجاوَز  ➜  نتيجة كاذبة
--    * تشغيله كـ test_runner أو authenticated  ➜  RLS ساري      ➜  نتيجة صحيحة
--  run_all.py يشغّل مجموعات الاختبار بـ:  SET ROLE test_runner   (وهذا سبب اختياره)
--
--  كل استعلامات التحقق أدناه يجب أن تُنفَّذ كـ non-superuser.
--  جرّب أولاً:
--      SELECT current_user, session_user,
--             rolsuper, rolbypassrls
--      FROM pg_roles WHERE rolname = current_user;
--  إذا رجّع rolsuper = true أو rolbypassrls = true ➜ STOP، لا تتّصل بأي شيء.
-- ============================================================================

\set ON_ERROR_STOP on
\timing off

BEGIN;   -- كل الاستعلامات قراءة فقط، لكن BEGIN/ROLLBACK يضمن ذلك

--  هذا الملف لا يُشغَّل كـ superuser أبداً — فقط test_runner أو authenticated.
-- لا يوجد superuser هنا إطلاقاً.

--  ── ── STEP 1: كل السياسات الحالية على الجداول الستة ────────────────────
\echo '=== STEP 1 — كل السياسات على الجداول المالية الستة ==='
SELECT
    tablename,
    policyname,
    cmd,
    roles::text          AS applies_to,
    array_length(roles, 1) AS n_roles,
    coalesce(qual,      '(none)') AS using_expr,
    coalesce(with_check, '(none)') AS check_expr,
    CASE
        WHEN coalesce(qual, '') ILIKE '%user_manages_farm%'
          OR coalesce(with_check, '') ILIKE '%user_manages_farm%'
            THEN 'manager-only  ✔'
        WHEN coalesce(qual, '') ILIKE '%user_has_farm_access%'
          OR coalesce(with_check, '') ILIKE '%user_has_farm_access%'
            THEN 'MEMBERSHIP-only  ✘ ثغرة P0'
        ELSE 'غير مصنّف — يحتاج مراجعة يدوية'
    END AS verdict
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('payments', 'expenses', 'revenue',
                    'opening_balances', 'inventory_items', 'stock_adjustments')
ORDER BY tablename, cmd, policyname;

\echo ''
\echo '=== STEP 1b — نفس الشيء على جدولين مجاورين للاكتمال ==='
\echo '(كلا customers و inventory_transactions وقع في نفس صنف المشكلة — خارج نطاق هذا الإصلاح)'
SELECT
    tablename, policyname, cmd, roles::text AS applies_to,
    coalesce(qual, '(none)')       AS using_expr,
    coalesce(with_check, '(none)') AS check_expr,
    CASE
        WHEN coalesce(qual, '') ILIKE '%user_has_farm_access%'
          OR coalesce(with_check, '') ILIKE '%user_has_farm_access%'
            THEN 'MEMBERSHIP-only  ✘ نفس الصنف'
        ELSE 'manager-gated'
    END AS verdict
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('customers', 'inventory_transactions')
ORDER BY tablename, cmd, policyname;

--  ── ── STEP 2: الجواب الدقيق — access أم manages؟ ───────────────────────
\echo ''
\echo '=== STEP 2 — الدالة المستخدمة فعلياً: access (worker passes) أم manages؟ ==='
\echo '(ملاحظة: RLS يجمع سياسات الأمر نفسه بـ OR، ف-existence of أي سياسة أضعف' 
\echo ' تُبطل كلwheelحتوى أقوى واحدة — الأقوى ليس الأدنى)'
WITH financial(t) AS (
    VALUES ('payments'), ('expenses'), ('revenue'),
           ('opening_balances'), ('inventory_items'), ('stock_adjustments')
),
pol AS (
    SELECT tablename, policyname, cmd,
           coalesce(qual, '')       AS q,
           coalesce(with_check, '') AS wc
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (SELECT t FROM financial)
),
-- نأخذ المسند الفعال لكل أمر: للـ INSERT هو WITH CHECK، لغيره هو USING
effective AS (
    SELECT tablename, policyname, cmd,
           CASE WHEN cmd = 'INSERT' THEN wc ELSE q END AS pred
    FROM pol
),
scored AS (
    SELECT f.t AS tablename,
           e.cmd,
           e.policyname,
           e.pred,
           CASE
               WHEN e.pred = '' THEN 'ALLOW-ALL'
               WHEN e.pred ILIKE '%user_manages_farm%'
                 OR e.pred ILIKE '%system_admin%' THEN 'MANAGER'
               WHEN e.pred ILIKE '%user_has_farm_access%' THEN 'MEMBER'
               ELSE 'OTHER'
           END AS strength,
           rank() OVER (PARTITION BY f.t, e.cmd
                        ORDER BY CASE
                            WHEN e.pred ILIKE '%user_manages_farm%'
                              OR e.pred ILIKE '%system_admin%' THEN 1
                            WHEN e.pred ILIKE '%user_has_farm_access%' THEN 2
                            ELSE 3
                        END) AS rk
    FROM financial f
    LEFT JOIN effective e ON e.tablename = f.t
)
SELECT
    tablename,
    string_agg(DISTINCT cmd, ', ' ORDER BY cmd)                    AS commands_present,
    string_agg(DISTINCT upper(strength), ', ' ORDER BY upper(strength)) AS strengths_found,
    -- RLS يجمع سياسات الأمر نفسه بـ OR ⇒ существова最强的不是 الأضعف
    CASE
        WHEN bool_or(strength IN ('ALLOW-ALL', 'MEMBER'))
            THEN 'THREAT — عامل يستطيع القراءة/الكتابة'
        WHEN bool_or(strength = 'MANAGER')
            THEN 'SAFE — مدير فقط'
        ELSE 'NO POLICY — لا وصول (أمان بالمصادفة، يُصلَح)'
    END AS verdict,
    string_agg(DISTINCT policyname, ', ') FILTER (WHERE policyname IS NOT NULL) AS policies
FROM scored
GROUP BY tablename
ORDER BY tablename;

--  ── STEP 3: محاكاة دور عامل ──────────────────────────────────────────────
--  هذه الخطوة هي الدليل الفعلي، لا استعلامات الكتالوج في STEP 1/2.
--
--  نكتشف عاملاً حقيقياً ومزرعته من البيانات الفعلية بدل تثبيت UUIDs، لأن هذا
--  الملف مُعدّ للتشغيل على الإنتاج حيث fixtures الاختبار غير موجودة.
--
--  نقطة حرجة: نستخدم SET LOCAL ROLE authenticated. ضبط request.jwt.claims
--  وحده لا يكفي لو بقيت الجلسة على postgres، لأن جداول المشروع مفعّل عليها
--  RLS بلا FORCE، فيتخطّى postgres كل السياسات وتظهر نتيجة كاذبة تماماً.
--  بعد SET ROLE تتحقق RLS فعلاً لأن authenticated ليس مالك الجداول.
\echo ''
\echo '=== STEP 3 — هل العامل يستطيع SELECT / INSERT على الجداول المالية؟ ==='
\echo '(يكتشف عاملاً ومزرعة حقيقية من بياناتك — لا UUIDs ثابتة)'

-- خط الأساس يُقاس بصلاحية كاملة قبل تبديل الدور، وإلا لاحظنا 0 صفوف
-- لسبب واحد فقط: أن RLS يخفيها أصلاً.
CREATE TEMP TABLE diag_baseline (tbl text PRIMARY KEY, total bigint) ON COMMIT DROP;
INSERT INTO diag_baseline (tbl, total)
SELECT t.tbl,
       CASE t.tbl
           WHEN 'payments'          THEN (SELECT count(*) FROM public.payments)
           WHEN 'expenses'          THEN (SELECT count(*) FROM public.expenses)
           WHEN 'revenue'           THEN (SELECT count(*) FROM public.revenue)
           WHEN 'opening_balances'  THEN (SELECT count(*) FROM public.opening_balances)
           WHEN 'inventory_items'   THEN (SELECT count(*) FROM public.inventory_items)
           WHEN 'stock_adjustments' THEN (SELECT count(*) FROM public.stock_adjustments)
       END
  FROM (VALUES ('payments'), ('expenses'), ('revenue'),
               ('opening_balances'), ('inventory_items'), ('stock_adjustments')
       ) AS t(tbl);

DO $precheck$
DECLARE v_super boolean; v_bypass boolean;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        RAISE EXCEPTION
            'HARNESS ERROR: دور authenticated غير موجود في هذه القاعدة. '
            'هذه ليست قاعدة مشروع Supabase — توقّف ولا تثق بأي نتيجة.';
    END IF;

    -- لازم أن يحدث الفحص بعد التبديل: بعد SET ROLE يصبح current_user هو
    -- authenticated، وقبلها يكون postgres (superuser) ويتجاوز RLS.
    EXECUTE 'SET LOCAL ROLE authenticated';

    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
      FROM pg_roles WHERE rolname = current_user;
    IF v_super OR v_bypass THEN
        RAISE EXCEPTION
            'HARNESS ERROR: الدور الحالي (%) superuser أو BYPASSRLS — '
            'النتائج ستكون كاذبة.', current_user;
    END IF;

    -- ادّعاء مبدئي ثم تحقق أن RLS مفعّل لهذه الجلسة
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', '00000000-0000-0000-0000-000000000000',
                           'role', 'authenticated')::text,
        true);
    IF current_setting('row_security') <> 'on' THEN
        RAISE EXCEPTION 'HARNESS ERROR: row_security=% — لا يمكن الاعتماد على النتائج.',
                        current_setting('row_security');
    END IF;

    RAISE NOTICE 'OK — current_user=% superuser=% bypassrls=% row_security=on',
                 current_user, v_super, v_bypass;
END;
$precheck$;

DO $diag$
DECLARE
    v_worker  uuid;
    v_farm_a  uuid := '00000000-0000-0000-0000-000000000001';
    v_farm_b  uuid;
    v_role    text;
    v_tbl     text;
    v_cnt     bigint;
    v_base    bigint;
    v_customer uuid;
    v_err     text;
    v_leak    text := '';
BEGIN
    ------------------------------------------------------------------
    -- اكتشاف عامل حقيقي ومزرعته من البيانات الفعلية.
    -- لا نستخدم UUIDs مثبّتة لأنها fixtures الاختبار ولا وجود لها في الإنتاج.
    ------------------------------------------------------------------
    SELECT uf.user_id, uf.farm_id INTO v_worker, v_farm_a
      FROM public.user_farms uf
      JOIN public.users u ON u.id = uf.user_id
     WHERE u.role = 'worker'
     ORDER BY uf.farm_id
     LIMIT 1;

    IF v_worker IS NULL THEN
        RAISE EXCEPTION
            'لا يوجد أي عامل (user_farms ⨝ users) في هذه القاعدة. '
            'لا يمكن محاكاة عامل — أضف عاملاً أو شغّل الملف على قاعدة فيها بيانات.';
    END IF;

    -- مزرعة أخرى لا ينتمي إليها هذا العامل، لاختبار عزل المزارع
    SELECT f.id INTO v_farm_b
      FROM public.farms f
     WHERE f.id <> v_farm_a
       AND NOT EXISTS (SELECT 1 FROM public.user_farms uf2
                        WHERE uf2.farm_id = f.id AND uf2.user_id = v_worker)
     ORDER BY f.id
     LIMIT 1;

    RAISE NOTICE 'العامل المكتشف: % ، مزرعته: % ، مزرعة غريبة: %',
                 v_worker, v_farm_a, coalesce(v_farm_b::text, '(لا توجد)');

    ------------------------------------------------------------------
    -- sanity: هل الدالة تقرأ الدور فعلاً من الهوية الحالية؟
    ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        jsonb_build_object('sub', v_worker::text, 'role', 'authenticated')::text, true);

    SELECT public.current_user_role() INTO v_role;
    IF v_role IS DISTINCT FROM 'worker' THEN
        RAISE EXCEPTION
            'HARNESS ERROR: current_user_role() = % (توقعنا worker). '
            'الهوية أو الدالة current_user_role() لا تعمل كما هو متوقع — '
            'لا يمكن الاعتماد على نتائج هذا الملف.', v_role;
    END IF;
    RAISE NOTICE 'OK — الهوية صالحة، current_user_role() = %', v_role;

    IF NOT public.user_has_farm_access(v_farm_a) THEN
        RAISE EXCEPTION
            'HARNESS ERROR: user_has_farm_access() = FALSE لمزرعة العامل نفسه — '
            'دالة العضوية لا تعمل كما هو متوقع.';
    END IF;
    IF public.user_manages_farm(v_farm_a) THEN
        RAISE EXCEPTION
            'HARNESS ERROR: user_manages_farm() قال صح لعامل — الدالة معطوبة!';
    END IF;
    RAISE NOTICE 'OK — user_has_farm_access=TRUE، user_manages_farm=FALSE (كما يجب)';

    ------------------------------------------------------------------
    -- 3a. SELECT على الجداول الستة
    -- RLS يخفي الصفوف ولا يرمي ⇒ نتحقق أن الاستعلام ينجح ويعيد 0 صف.
    --
    -- "0 صفوف" لا تساوي "آمن": إن كان الجدول فارغاً أصلاً فالتيجة لا
    -- تقول شيئاً عن RLS. نقارن بخط الأساس المرصود في diag_baseline ونوسم
    -- الحالة INCONCLUSIVE بدل أن نُعلن جدولاً فارغاً بأنه محمي.
    ------------------------------------------------------------------
    FOR v_tbl IN SELECT * FROM (VALUES
        ('payments'), ('expenses'), ('revenue'),
        ('opening_balances'), ('inventory_items'), ('stock_adjustments')
    ) AS t(tbl) LOOP
        v_cnt := NULL; v_err := NULL;
        SELECT b.total INTO v_base FROM diag_baseline b WHERE b.tbl = v_tbl;
        BEGIN
            EXECUTE format('SELECT count(*) FROM public.%I', v_tbl) INTO v_cnt;
        EXCEPTION WHEN OTHERS THEN
            v_err := SQLERRM;
        END;

        IF v_err IS NOT NULL THEN
            RAISE WARNING 'SELECT %: مرفوض (%s)', v_tbl, left(v_err, 80);
            v_leak := v_leak || format('%s=DENIED ', v_tbl);
        ELSIF v_cnt > 0 THEN
            RAISE WARNING 'SELECT %: تسريب! العامل يرى % صف!', v_tbl, v_cnt;
            v_leak := v_leak || format('%s=LEAK(%s) ', v_tbl, v_cnt);
        ELSIF coalesce(v_base, 0) = 0 THEN
            RAISE WARNING 'SELECT %: inconclusive — الجدول فارغ أصلاً، '
                          'لا يمكن إثبات الحماية منه', v_tbl;
            v_leak := v_leak || format('%s=INCONCLUSIVE ', v_tbl);
        ELSE
            RAISE NOTICE 'SELECT %: 0 صف من أصل % — محمي', v_tbl, v_base;
            v_leak := v_leak || format('%s=OK ', v_tbl);
        END IF;
    END LOOP;

    ------------------------------------------------------------------
    -- 3b. INSERT على جدولين تمثيليين
    -- نُدرج ضمن المعاملة ثم نُبقي الصف (كل شيء داخل BEGIN/ROLLBACK).
    --
    -- payments يشترط customer_id و price_per_carton كـ NOT NULL، لذلك يجب
    -- جلب زبون من نفس المزرعة. لولا ذلك لفشل الإدراج بخطأ not-null لا علاقة
    -- له بـ RLS، والفحص سيُبلّغ "خطأ غير متوقع" بينما الحكم الحقيقي مجهول.
    ------------------------------------------------------------------
    v_customer := NULL;
    SELECT c.id INTO v_customer
      FROM public.customers c
     WHERE c.farm_id = v_farm_a
     LIMIT 1;
    RAISE NOTICE 'زبون للمزرعة: %', coalesce(v_customer::text, '(لا يوجد)');

    BEGIN
        INSERT INTO public.expenses (farm_id, date, category, description, amount)
        VALUES (v_farm_a, CURRENT_DATE, 'other', 'RLS probe', 1);
        RAISE WARNING 'INSERT expenses: SUCCEEDED — التسريب مؤكد!';
        v_leak := v_leak || 'expenses.INSERT=LEAK ';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'INSERT expenses: مرفوض (insufficient_privilege) — سليم';
        v_leak := v_leak || 'expenses.INSERT=OK ';
    WHEN OTHERS THEN
        IF position('row-level security' in SQLERRM) > 0 THEN
            RAISE NOTICE 'INSERT expenses: مرفوض (RLS) — سليم';
            v_leak := v_leak || 'expenses.INSERT=OK ';
        ELSE
            RAISE WARNING 'INSERT expenses: خطأ غير متوقع — %', left(SQLERRM, 80);
            v_leak := v_leak || 'expenses.INSERT=UNKNOWN ';
        END IF;
    END;

    IF v_customer IS NULL THEN
        RAISE WARNING 'INSERT payments: SKIPPED — لا يوجد زبون في هذه المزرعة،'
                      ' والعمود customer_id NOT NULL. النتيجة غير محسومة هنا.';
        v_leak := v_leak || 'payments.INSERT=INCONCLUSIVE ';
    ELSE
        BEGIN
            INSERT INTO public.payments (farm_id, customer_id, date,
                                         price_per_carton, total_due, amount_paid,
                                         payment_method, manager_id)
            VALUES (v_farm_a, v_customer, CURRENT_DATE, 1, 100, 100, 'cash', v_worker);
            RAISE WARNING 'INSERT payments: SUCCEEDED — التسريب مؤكد!';
            v_leak := v_leak || 'payments.INSERT=LEAK ';
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'INSERT payments: مرفوض (insufficient_privilege) — سليم';
            v_leak := v_leak || 'payments.INSERT=OK ';
        WHEN OTHERS THEN
            IF position('row-level security' in SQLERRM) > 0 THEN
                RAISE NOTICE 'INSERT payments: مرفوض (RLS) — سليم';
                v_leak := v_leak || 'payments.INSERT=OK ';
            ELSE
                RAISE WARNING 'INSERT payments: خطأ غير متوقع — %', left(SQLERRM, 80);
                v_leak := v_leak || 'payments.INSERT=UNKNOWN ';
            END IF;
        END;
    END IF;

    ------------------------------------------------------------------
    -- 3c. عبور المزارع: العامل في A يجب ألا يرى شيئاً من B
    ------------------------------------------------------------------
    BEGIN
        SELECT count(*) INTO v_cnt FROM public.payments WHERE farm_id = v_farm_b;
        IF v_cnt > 0 THEN
            RAISE WARNING 'عزل المزارع مكسور: العامل يرى % صف من FARM_B', v_cnt;
            v_leak := v_leak || 'cross-farm=LEAK ';
        ELSE
            RAISE NOTICE 'عزل المزارع: FARM_B غير مرئية — سليم';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'عزل المزارع: مرفوض — سليم';
    END;

    ------------------------------------------------------------------
    -- الحكم النهائي
    -- ثلاث حالات لا حالتان: LEAK يعني تسريباً مؤكَّداً، و INCONCLUSIVE تعني
    -- "لم نتمكن من إثبات الحماية" ولا يجوز اعتبارها نجاحاً.
    ------------------------------------------------------------------
    RAISE NOTICE '';
    RAISE NOTICE '======================================================';
    RAISE NOTICE 'النتيجة: %', v_leak;

    IF position('LEAK' in v_leak) > 0 THEN
        RAISE NOTICE '*** الثغرة حيّة — طبّق 20261002000000_restore_financial_rls.sql ***';
    ELSIF position('INCONCLUSIVE' in v_leak) > 0
       OR position('UNKNOWN' in v_leak) > 0 THEN
        RAISE WARNING 'النتيجة غير محسومة على بعض الجداول (فارغة أو خطأ غير متوقع).';
        RAISE NOTICE 'لا تسريب مرصود، لكن هذا ليس إثباتاً للأمان. عالج البنود أعلاه';
        RAISE NOTICE 'وأعد التشغيل قبل الاعتماد على النتيجة.';
    ELSE
        RAISE NOTICE 'لا تسريب مباشر. تأكد أن الثغرة مغلقة في الإنتاج بأصل المخطط:';
        RAISE NOTICE 'راجع سجل migration 20260926000800 في supabase_migrations.';
    END IF;
    RAISE NOTICE '======================================================';
END
$diag$;

--  ── ── STEP 4: سجلّ الهجرات — أي نسخة من مخططك هي الفعلية؟ ───────────────
\echo ''
\echo '=== STEP 4 — أي ملفات هجرة طُبّقت وميّ ==='
DO $miglog$
BEGIN
    IF to_regclass('supabase_migrations.schema_migrations') IS NULL THEN
        RAISE NOTICE 'لا يوجد جدول supabase_migrations.schema_migrations هنا.';
        RAISE NOTICE 'شغّل بدل ذلك:  supabase migration list';
        RETURN;
    END IF;
    RAISE NOTICE 'الجدول موجود. شغّل يدوياً للاطلاع على آخر 15 هجرة:';
    RAISE NOTICE '  SELECT version, name FROM supabase_migrations.schema_migrations';
    RAISE NOTICE '  ORDER BY version DESC LIMIT 15;';
END;
$miglog$;

ROLLBACK;   -- لا تغيير دائم. هذا الملف آمن للتشغيل المتكرر على الإنتاج.
-- ═══════════════════════════════════════════════════════
-- Migration 008: سياسات RLS الناقصة + إصلاح صلاحيات القراءة
-- تنفيذ: من محرر SQL في Supabase Dashboard (أمر واحد كامل)
--
-- المشكلة المُصلَحة:
-- - جدول users: قراءة زملاء نفس المزرعة (شاشة المستخدمين بالكمبيوتر)
-- - جدول customers: لا توجد أي سياسة → الرفع من الموبايل والسحب
--   للكمبيوتر محجوبان بصلاحيات RLS (المشكلة الثانية والرابعة)
-- - جداول flocks / mortality / feed_consumption / feed_received
--   / medications / egg_dispatch (إدراج): لا سياسات
-- آمن لإعادة التنفيذ (DROP POLICY IF EXISTS قبل كل إنشاء)
-- ═══════════════════════════════════════════════════════

-- ─────────────── دوال مساعدة آمنة نصياً ───────────────
-- تعمل مع المخطط النصي (id/farm_id نصية) ومع المخطط UUID أيضاً
create or replace function public.current_role_safe()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select u.role::text from public.users u where u.id::text = auth.uid()::text limit 1
$$;

create or replace function public.current_farm_safe()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select u.farm_id::text from public.users u where u.id::text = auth.uid()::text limit 1
$$;

grant execute on function public.current_role_safe() to anon, authenticated;
grant execute on function public.current_farm_safe() to anon, authenticated;

-- ============================================================
-- 1) users: قراءة زملاء نفس المزرعة (شاشة المستخدمون)
-- ============================================================
drop policy if exists users_read_same_farm on users;
create policy users_read_same_farm on users
    for select to authenticated
    using (farm_id::text = public.current_farm_safe());

-- ============================================================
-- 2) customers: قراءة/إدراج لجميع أفراد المزرعة، تعديل/حذف للمدير
-- ============================================================
drop policy if exists customers_read_same_farm on customers;
create policy customers_read_same_farm on customers
    for select to authenticated
    using (farm_id::text = public.current_farm_safe());

drop policy if exists customers_insert_same_farm on customers;
create policy customers_insert_same_farm on customers
    for insert to authenticated
    with check (farm_id::text = public.current_farm_safe());

drop policy if exists customers_update_manager on customers;
create policy customers_update_manager on customers
    for update to authenticated
    using (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    )
    with check (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    );

drop policy if exists customers_delete_manager on customers;
create policy customers_delete_manager on customers
    for delete to authenticated
    using (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    );

-- ============================================================
-- 3) flocks: قراءة لأفراد المزرعة، إدارة للمدير
-- ============================================================
drop policy if exists flocks_read_same_farm on flocks;
create policy flocks_read_same_farm on flocks
    for select to authenticated
    using (farm_id::text = public.current_farm_safe());

drop policy if exists flocks_manager_write on flocks;
create policy flocks_manager_write on flocks
    for all to authenticated
    using (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    )
    with check (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    );

-- ============================================================
-- 4) mortality / feed_consumption / feed_received / medications
--    قراءة للمزرعة + إدراج تشغيلي (عامل/مشرف/مدير)
-- ============================================================
drop policy if exists mortality_read_same_farm on mortality;
create policy mortality_read_same_farm on mortality
    for select to authenticated
    using (farm_id::text = public.current_farm_safe());

drop policy if exists mortality_insert_operational on mortality;
create policy mortality_insert_operational on mortality
    for insert to authenticated
    with check (
        farm_id::text = public.current_farm_safe()
        and (
            public.current_role_safe() = 'manager'
            or (
                public.current_role_safe() in ('worker', 'supervisor')
                and worker_id::text = auth.uid()::text
            )
        )
    );

drop policy if exists feed_consumption_read_same_farm on feed_consumption;
create policy feed_consumption_read_same_farm on feed_consumption
    for select to authenticated
    using (farm_id::text = public.current_farm_safe());

drop policy if exists feed_consumption_insert_operational on feed_consumption;
create policy feed_consumption_insert_operational on feed_consumption
    for insert to authenticated
    with check (
        farm_id::text = public.current_farm_safe()
        and (
            public.current_role_safe() = 'manager'
            or (
                public.current_role_safe() in ('worker', 'supervisor')
                and worker_id::text = auth.uid()::text
            )
        )
    );

drop policy if exists feed_received_read_same_farm on feed_received;
create policy feed_received_read_same_farm on feed_received
    for select to authenticated
    using (farm_id::text = public.current_farm_safe());

drop policy if exists feed_received_insert_operational on feed_received;
create policy feed_received_insert_operational on feed_received
    for insert to authenticated
    with check (
        farm_id::text = public.current_farm_safe()
        and (
            public.current_role_safe() = 'manager'
            or (
                public.current_role_safe() in ('worker', 'supervisor')
                and worker_id::text = auth.uid()::text
            )
        )
    );

drop policy if exists medications_read_same_farm on medications;
create policy medications_read_same_farm on medications
    for select to authenticated
    using (farm_id::text = public.current_farm_safe());

drop policy if exists medications_insert_operational on medications;
create policy medications_insert_operational on medications
    for insert to authenticated
    with check (
        farm_id::text = public.current_farm_safe()
        and (
            public.current_role_safe() = 'manager'
            or (
                public.current_role_safe() in ('worker', 'supervisor')
                and worker_id::text = auth.uid()::text
            )
        )
    );

-- ============================================================
-- 5) egg_dispatch: إدراج تشغيلي (القراءة موجودة سابقاً)
-- ============================================================
drop policy if exists egg_dispatch_insert_operational on egg_dispatch;
create policy egg_dispatch_insert_operational on egg_dispatch
    for insert to authenticated
    with check (
        farm_id::text = public.current_farm_safe()
        and (
            public.current_role_safe() = 'manager'
            or (
                public.current_role_safe() in ('worker', 'supervisor')
                and worker_id::text = auth.uid()::text
            )
        )
    );

-- ============================================================
-- 6) medicines_catalog: قراءة عامة لأفراد المزرعة
-- ============================================================
drop policy if exists medicines_catalog_read_all_authenticated on medicines_catalog;
create policy medicines_catalog_read_all_authenticated on medicines_catalog
    for select to authenticated
    using (true);

-- ============================================================
-- 7) إعادة بناء السياسات التشغيلية السابقة بمقارنات نصية آمنة
--    (تعمل مع أعمدة id/farm_id من نوع نص أو UUID معاً)
-- ============================================================

-- egg_production: قراءة + إدراج تشغيلي (شامل المدير)
drop policy if exists worker_read_operational on egg_production;
create policy worker_read_operational on egg_production
    for select to authenticated
    using (
        public.current_role_safe() in ('worker', 'supervisor', 'manager')
        and farm_id::text = public.current_farm_safe()
    );

drop policy if exists worker_insert_operational on egg_production;
create policy worker_insert_operational on egg_production
    for insert to authenticated
    with check (
        farm_id::text = public.current_farm_safe()
        and (
            public.current_role_safe() = 'manager'
            or (
                public.current_role_safe() in ('worker', 'supervisor')
                and worker_id::text = auth.uid()::text
            )
        )
    );

-- egg_dispatch: قراءة (تشغيلية) — الإدراج أعلاه في القسم 5
drop policy if exists worker_read_dispatch on egg_dispatch;
create policy worker_read_dispatch on egg_dispatch
    for select to authenticated
    using (
        public.current_role_safe() in ('worker', 'supervisor', 'manager')
        and farm_id::text = public.current_farm_safe()
    );

-- payments: المدير فقط (قراءة + إدراج + تحديث) بنصوص آمنة
drop policy if exists manager_only_payments on payments;
create policy manager_only_payments on payments
    for all to authenticated
    using (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    )
    with check (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    );

-- expenses: المدير فقط (بنصوص آمنة)
drop policy if exists manager_full_access_expenses on expenses;
create policy manager_full_access_expenses on expenses
    for all to authenticated
    using (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    )
    with check (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    );

-- ============================================================
-- 8) جداول كانت مفعّلة RLS بلا أي سياسة (محجوبة كلياً):
--    inventory_items / inventory_transactions / app_settings
-- ============================================================

-- المخزون: المدير فقط يقرأ/يضيف/يعدّل/يحذف أصناف مزرعته
drop policy if exists inventory_items_manager_all on inventory_items;
create policy inventory_items_manager_all on inventory_items
    for all to authenticated
    using (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    )
    with check (
        farm_id::text = public.current_farm_safe()
        and public.current_role_safe() = 'manager'
    );

-- حركة المخزون: المدير فقط (سجل تدقيق) — بدون الاعتماد على farm_id
drop policy if exists inventory_transactions_manager_all on inventory_transactions;
create policy inventory_transactions_manager_all on inventory_transactions
    for all to authenticated
    using (public.current_role_safe() = 'manager')
    with check (public.current_role_safe() = 'manager');

-- إعدادات التطبيق: قراءة لجميع المصادقين، الكتابة للمدير — بدون أعمدة افتراضية
drop policy if exists app_settings_read_all on app_settings;
create policy app_settings_read_all on app_settings
    for select to authenticated
    using (true);

drop policy if exists app_settings_manager_write on app_settings;
create policy app_settings_manager_write on app_settings
    for insert to authenticated
    with check (public.current_role_safe() = 'manager');

drop policy if exists app_settings_manager_update on app_settings;
create policy app_settings_manager_update on app_settings
    for update to authenticated
    using (public.current_role_safe() = 'manager')
    with check (public.current_role_safe() = 'manager');
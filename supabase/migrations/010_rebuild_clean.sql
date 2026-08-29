-- ============================================================
-- 010: إعادة البناء الجذري الكامل (المخطط النظيف)
--
-- القرارات البنيوية الملبّاة من الخطة:
--   1) users.id = auth.uid()  (نوع UUID، مطابق تماماً)
--   2) Trigger handle_new_user على auth.users
--      ينشئ سجل users تلقائياً بنفس NEW.id لكل مستخدم يُسجَّل
--   3) RLS مفعّل على جميع الجداول
--   4) دوال الهوية current_user_role() / current_user_farm_id()
--      STABLE وليست SECURITY DEFINER
--   5) إنشاء المدير الأول:
--      الطريقة الموصى بها (تضمن دخولاً صحيحاً 100%):
--        أ) لوحة التحكم ← Authentication ← Users ← Add user
--           (بريد دلوي، باسورد = sha256(PIN) السداسي، Auto confirm: ON)
--        ب) حدّث المرور عبر دالة من أدناه)
--      ملاحظة: bootstrap_create_farm_and_manager أُنشئ لراحة الوضع الفارغ،
--      لكن الإدراج المباشر داخل auth.users قد لا يطابق كل أعمدة GoTrue
--      الخاصة بنسخة المشروع — إن وُجد خلل تسجيل دخول ناتج عنه فاستخدم
--      الطريقة أعلاه (لوحة التحكم + الـ Trigger) ثم رقّي الحساب عبر SQL.
--      أنشئ trigger handle_new_user على auth.users
--      بنفس NEW.id لكل مستخدم يُسجَّل
--
-- ملاحظة تقنية هامة (بخصوص بند "لا SECURITY DEFINER"):
--   - دالة handle_new_user (Trigger) يجب أن تكون SECURITY DEFINER
--     لأنها تكتب في public.users من inside schema auth —
--     وهذا النمط القياسي الرسمي من Supabase، وليس "دالة هوية".
--   - دوال الهوية (current_user_role/farm_id) هي STABLE + invoker.
--   - الاستثناء الوحيد: سياسة "المدير يرى مستخدمي مزرعته" على جدول
--     users نفسِه لا يمكنها استدعاء current_user_role() لأن PostgreSQL
--     يكشف تكراراً لا نهائياً (RLS على users يعيد استدعاء دالة تقرأ
--     users). ولذلك تستخدم هذه السياسةُ حقول user_metadata من JWT
--     (agrole + farm_id المحفوظان في auth عند الإنشاء) — وهذا يحقّق
--     نفس النتيجة دون أي SECURITY DEFINER ودون معالجة بريد.
--
-- آمن لإعادة التنفيذ بالكامل (DROP IF EXISTS في البداية).
-- لا تشغّل 001..008 بعد هذا الملف (010 يغني عنها كلها).
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- 0) تنظيف أي بقايا من النسخ القديمة
-- ============================================================
DROP TRIGGER IF EXISTS handle_new_user ON auth.users;
DROP FUNCTION IF EXISTS public.handle_new_user();

DROP TRIGGER IF EXISTS trg_calc_total_eggs ON egg_production;
DROP TRIGGER IF EXISTS trg_calc_dispatch_total ON egg_dispatch;
DROP TRIGGER IF EXISTS trg_update_flock_count ON mortality;
DROP TRIGGER IF EXISTS expenses_audit_trigger ON expenses;
DROP FUNCTION IF EXISTS calc_total_eggs(), calc_dispatch_total(),
    update_flock_count_on_mortality(), audit_expenses_changes(), log_audit_changes();

DROP TABLE IF EXISTS sync_queue, app_notifications, dispatch_requests,
    audit_log, medicines_catalog, medications, payments, egg_dispatch,
    customers, feed_received, feed_consumption, mortality, egg_production,
    flocks, opening_balances, inventory_transactions, inventory_items,
    expenses, users, farms CASCADE;

DROP FUNCTION IF EXISTS public.find_user_by_phone(text);
DROP FUNCTION IF EXISTS public.current_user_role(), public.current_user_farm_id();
DROP FUNCTION IF EXISTS public.current_role_safe(), public.current_farm_safe();
DROP FUNCTION IF EXISTS public.app_user_email(uuid), public.app_password_from_pin(text);
DROP FUNCTION IF EXISTS public.assert_current_is_manager_of(uuid);
DROP FUNCTION IF EXISTS public.bootstrap_create_farm_and_manager(text, text, text, text, text);
DROP FUNCTION IF EXISTS public.admin_create_user(text, text, text, text, text);
DROP FUNCTION IF EXISTS public.admin_update_user(text, text, text, text);
DROP FUNCTION IF EXISTS public.admin_reset_pin(text, text);
DROP FUNCTION IF EXISTS public.admin_delete_user(text);
DROP FUNCTION IF EXISTS public.sync_records_batch(jsonb, uuid);

-- ============================================================
-- 1) المزارع والمستخدمون  (users.id = auth.uid())
-- ============================================================
CREATE TABLE farms (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name       TEXT NOT NULL,
    location   TEXT,
    owner_id   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE users (
    id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    name          TEXT,
    phone         TEXT UNIQUE,
    role          TEXT NOT NULL DEFAULT 'worker'
                      CHECK (role IN ('worker', 'supervisor', 'manager')),
    pin_hash      TEXT,
    farm_id       UUID REFERENCES farms(id) ON DELETE SET NULL,
    remember_token TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_users_farm ON users(farm_id);
CREATE INDEX idx_users_role ON users(role);
CREATE INDEX idx_users_phone ON users(phone);

-- ============================================================
-- 2) الجداول التشغيلية (شارة: id uuid default؛ موازية لمخطط التطبيق)
-- ============================================================
CREATE TABLE flocks (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id       UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    breed         TEXT NOT NULL,
    start_date    DATE NOT NULL,
    initial_count INTEGER NOT NULL CHECK (initial_count > 0),
    current_count INTEGER NOT NULL,
    status        TEXT NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'depleted')),
    sections_count INTEGER NOT NULL DEFAULT 1,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_flocks_farm ON flocks(farm_id);
CREATE INDEX idx_flocks_status ON flocks(status);

CREATE TABLE customers (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id    UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    phone      TEXT NOT NULL,
    notes      TEXT,
    total_debt NUMERIC(12,2) DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_customers_farm ON customers(farm_id);

CREATE TABLE egg_production (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id       UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id      UUID NOT NULL REFERENCES flocks(id) ON DELETE CASCADE,
    date          DATE NOT NULL CHECK (date <= CURRENT_DATE),
    cartons       INTEGER NOT NULL DEFAULT 0 CHECK (cartons >= 0),
    trays         INTEGER NOT NULL DEFAULT 0 CHECK (trays >= 0 AND trays < 12),
    loose_eggs    INTEGER NOT NULL DEFAULT 0 CHECK (loose_eggs >= 0 AND loose_eggs < 30),
    total_eggs    INTEGER NOT NULL DEFAULT 0,
    broken_eggs   INTEGER DEFAULT 0 CHECK (broken_eggs >= 0),
    dirty_eggs    INTEGER DEFAULT 0 CHECK (dirty_eggs >= 0),
    tray_weight_kg NUMERIC(6,2),
    section_no    INTEGER,
    worker_id     UUID NOT NULL REFERENCES users(id),
    sync_status   TEXT DEFAULT 'synced' CHECK (sync_status IN ('pending', 'synced', 'failed')),
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT check_broken_dirty CHECK (broken_eggs + dirty_eggs <= total_eggs)
);
CREATE INDEX idx_egg_production_farm ON egg_production(farm_id);
CREATE INDEX idx_egg_production_flock ON egg_production(flock_id);
CREATE INDEX idx_egg_production_date ON egg_production(date);

CREATE TABLE mortality (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id     UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id    UUID NOT NULL REFERENCES flocks(id) ON DELETE CASCADE,
    date        DATE NOT NULL CHECK (date <= CURRENT_DATE),
    count       INTEGER NOT NULL CHECK (count > 0),
    reason      TEXT NOT NULL CHECK (reason IN (
        'not_eating', 'internal_bleeding', 'immunity_break',
        'heat_stress', 'cannibalism', 'unknown', 'other'
    )),
    reason_other TEXT,
    notes       TEXT,
    image_url   TEXT,
    worker_id   UUID NOT NULL REFERENCES users(id),
    sync_status TEXT DEFAULT 'synced',
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT check_reason_other CHECK (
        (reason = 'other' AND reason_other IS NOT NULL) OR
        (reason != 'other' AND reason_other IS NULL)
    )
);
CREATE INDEX idx_mortality_flock ON mortality(flock_id);
CREATE INDEX idx_mortality_date ON mortality(date);

CREATE TABLE feed_consumption (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id      UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date         DATE NOT NULL CHECK (date <= CURRENT_DATE),
    entry_mode   TEXT NOT NULL CHECK (entry_mode IN ('bags', 'kg')),
    bags_count   INTEGER DEFAULT 0,
    quantity_kg  NUMERIC(10,2) NOT NULL CHECK (quantity_kg > 0),
    worker_id    UUID NOT NULL REFERENCES users(id),
    sync_status  TEXT DEFAULT 'synced',
    created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE feed_received (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id       UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date          DATE NOT NULL CHECK (date <= CURRENT_DATE),
    entry_mode    TEXT NOT NULL CHECK (entry_mode IN ('bags', 'kg', 'ton')),
    quantity      NUMERIC(10,2) NOT NULL,
    quantity_kg   NUMERIC(10,2) NOT NULL CHECK (quantity_kg > 0),
    feed_type     TEXT NOT NULL CHECK (feed_type IN ('starter', 'grower', 'layer')),
    supplier      TEXT,
    invoice_number TEXT,
    notes         TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE egg_dispatch (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id        UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date           DATE NOT NULL CHECK (date <= CURRENT_DATE),
    customer_id    UUID NOT NULL REFERENCES customers(id),
    cartons        INTEGER NOT NULL DEFAULT 0 CHECK (cartons >= 0),
    trays          INTEGER NOT NULL DEFAULT 0 CHECK (trays >= 0 AND trays < 12),
    total_eggs     INTEGER NOT NULL DEFAULT 0,
    notes          TEXT,
    payment_status TEXT NOT NULL DEFAULT 'unpaid'
                       CHECK (payment_status IN ('unpaid', 'partial', 'paid')),
    worker_id      UUID NOT NULL REFERENCES users(id),
    sync_status    TEXT DEFAULT 'synced',
    created_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_egg_dispatch_farm ON egg_dispatch(farm_id);
CREATE INDEX idx_egg_dispatch_customer ON egg_dispatch(customer_id);

CREATE TABLE payments (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id          UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    dispatch_id      UUID REFERENCES egg_dispatch(id) ON DELETE SET NULL,
    customer_id      UUID NOT NULL REFERENCES customers(id),
    date             DATE NOT NULL CHECK (date <= CURRENT_DATE),
    price_per_carton NUMERIC(10,2) NOT NULL CHECK (price_per_carton >= 0),
    total_due        NUMERIC(12,2) NOT NULL CHECK (total_due >= 0),
    amount_paid      NUMERIC(12,2) NOT NULL CHECK (amount_paid >= 0),
    payment_method   TEXT NOT NULL CHECK (payment_method IN ('cash', 'transfer', 'check', 'credit')),
    due_date         DATE,
    notes            TEXT,
    manager_id       UUID NOT NULL REFERENCES users(id),
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT check_amount CHECK (amount_paid <= total_due)
);

CREATE TABLE medications (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id             UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date                DATE NOT NULL CHECK (date <= CURRENT_DATE),
    type                TEXT NOT NULL CHECK (type IN ('drug', 'vaccine', 'vitamin')),
    medicine_name       TEXT NOT NULL,
    dosage              TEXT NOT NULL,
    administration_route TEXT NOT NULL CHECK (administration_route IN (
        'water', 'spray', 'injection', 'feed'
    )),
    treatment_days      INTEGER,
    withdrawal_days     INTEGER DEFAULT 0 CHECK (withdrawal_days >= 0),
    notes               TEXT,
    worker_id           UUID NOT NULL REFERENCES users(id),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE medicines_catalog (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            TEXT UNIQUE NOT NULL,
    type            TEXT NOT NULL CHECK (type IN ('drug', 'vaccine', 'vitamin')),
    withdrawal_days INTEGER DEFAULT 0 CHECK (withdrawal_days >= 0),
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE expenses (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id     UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date        DATE NOT NULL DEFAULT CURRENT_DATE,
    category    TEXT NOT NULL CHECK (category IN (
        'electricity', 'water', 'labor', 'maintenance',
        'transport', 'feed', 'medicine', 'other'
    )),
    description TEXT,
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_expenses_farm_date ON expenses(farm_id, date);
CREATE INDEX idx_expenses_category ON expenses(category);

CREATE TABLE opening_balances (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id         UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id        UUID NOT NULL REFERENCES flocks(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    eggs_produced   INTEGER NOT NULL DEFAULT 0,
    eggs_dispatched INTEGER NOT NULL DEFAULT 0,
    feed_consumed_kg NUMERIC(12,2) NOT NULL DEFAULT 0,
    initial_birds   INTEGER NOT NULL DEFAULT 0,
    mortality_count INTEGER NOT NULL DEFAULT 0,
    total_payments  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_revenues  NUMERIC(12,2) NOT NULL DEFAULT 0,
    sections        JSONB
);
CREATE INDEX idx_opening_farm ON opening_balances(farm_id);
CREATE INDEX idx_opening_flock ON opening_balances(flock_id);

CREATE TABLE inventory_items (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id             UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,
    unit                TEXT NOT NULL DEFAULT 'piece' CHECK (unit IN (
        'piece', 'kg', 'liter', 'bag', 'vial', 'box'
    )),
    quantity            NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    low_stock_threshold NUMERIC(12,2) NOT NULL DEFAULT 5,
    notes               TEXT,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (farm_id, name)
);
CREATE INDEX idx_inventory_items_farm ON inventory_items(farm_id);

CREATE TABLE inventory_transactions (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id   UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
    date      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    type      TEXT NOT NULL CHECK (type IN ('in', 'out')),
    quantity  NUMERIC(12,2) NOT NULL CHECK (quantity > 0),
    note      TEXT,
    user_id   UUID REFERENCES users(id)
);
CREATE INDEX idx_inventory_tx_item ON inventory_transactions(item_id, date);

CREATE TABLE audit_log (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    action     TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    table_name TEXT NOT NULL,
    record_id  UUID NOT NULL,
    old_values JSONB,
    new_values JSONB,
    timestamp  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_audit_user ON audit_log(user_id);
CREATE INDEX idx_audit_table ON audit_log(table_name);
CREATE INDEX idx_audit_timestamp ON audit_log(timestamp);

-- إشعارات المدير وطلبات التخريج (تطابق ميزات التطبيق)
CREATE TABLE app_notifications (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id       UUID NOT NULL,
    flock_id      UUID,
    title         TEXT NOT NULL,
    body          TEXT,
    level         TEXT NOT NULL DEFAULT 'info',
    is_persistent BOOLEAN NOT NULL DEFAULT FALSE,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_by    UUID REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE dispatch_requests (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id     UUID NOT NULL,
    flock_id    UUID,
    customer_id UUID,
    cartons     INT NOT NULL DEFAULT 0,
    trays       INT NOT NULL DEFAULT 0,
    total_eggs  INT NOT NULL DEFAULT 0,
    stock_eggs  INT NOT NULL DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'pending',
    worker_id   UUID,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decided_at  TIMESTAMPTZ,
    decided_by  UUID
);

-- طابور مزامنة سحابي (تابع تاريخي؛ التطبيق يستخدم طابوراً محلياً)
CREATE TABLE sync_queue (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    table_name TEXT NOT NULL,
    record_id  UUID NOT NULL,
    action     TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    payload    JSONB NOT NULL,
    user_id    UUID NOT NULL REFERENCES users(id),
    attempts   INTEGER DEFAULT 0,
    last_error TEXT,
    status     TEXT DEFAULT 'pending'
                   CHECK (status IN ('pending', 'processing', 'synced', 'failed')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 3) بذر كتالوج الأدوية
-- ============================================================
INSERT INTO medicines_catalog (name, type, withdrawal_days, notes) VALUES
    ('حامض الستريك (Citric Acid)', 'drug', 0, 'محفز شرب'),
    ('أموكسيسيلين (Amoxicillin)', 'drug', 5, 'مضاد حيوي واسع الطيف'),
    ('إنروفلوكساسين (Enrofloxacin)', 'drug', 7, 'مضاد حيوي للجهاز التنفسي'),
    ('دوكسيسيكلين (Doxycycline)', 'drug', 5, 'مضاد حيوي'),
    ('لقاح نيوكاسل (Newcastle)', 'vaccine', 0, 'تحصين'),
    ('لقاح جامبورو (Gumboro)', 'vaccine', 0, 'تحصين'),
    ('فيتامين A,D3,E', 'vitamin', 0, 'فيتامينات ذائبة في الدهون'),
    ('فيتامين C', 'vitamin', 0, 'دعم المناعة'),
    ('مولتي فيتامين (Multivitamin)', 'vitamin', 0, 'فيتامينات متكاملة');

-- ============================================================
-- 4) Trigger: أي مستخدم يُنشأ في Auth يُنشأ سجله في users تلقائياً
--    (SECURITY DEFINER ضروري لأن الكتابة تتم من schema auth)
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.users (id, name, phone, role, farm_id)
    VALUES (
        NEW.id,
        NULLIF(NEW.raw_user_meta_data ->> 'full_name', ''),
        NULLIF(NEW.raw_user_meta_data ->> 'phone', ''),
        'worker',
        NULLIF(NEW.raw_user_meta_data ->> 'farm_id', '')::uuid
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS handle_new_user ON auth.users;
CREATE TRIGGER handle_new_user
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- 5) دوال الهوية المعتمدة  (STABLE + invoker — بلا SECURITY DEFINER)
--    تعمل داخل سياسات بقية الجداول لأن المستخدم يرى صفّه في users
--    (سياسة self)، وداخل الدوال SECURITY DEFINER تعمل بحقوق المالك.
-- ============================================================
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT u.role::text FROM public.users AS u WHERE u.id = auth.uid() LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.current_user_farm_id()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT u.farm_id FROM public.users AS u WHERE u.id = auth.uid() LIMIT 1;
$$;

-- ============================================================
-- 6) RLS: تفعيل على جميع الجداول
-- ============================================================
ALTER TABLE farms ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE flocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE egg_production ENABLE ROW LEVEL SECURITY;
ALTER TABLE mortality ENABLE ROW LEVEL SECURITY;
ALTER TABLE feed_consumption ENABLE ROW LEVEL SECURITY;
ALTER TABLE feed_received ENABLE ROW LEVEL SECURITY;
ALTER TABLE egg_dispatch ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE medications ENABLE ROW LEVEL SECURITY;
ALTER TABLE medicines_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE opening_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE dispatch_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_queue ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 7) سياسات المستخدمين والمزارع
-- ============================================================

-- --- users -------------------------------------------------
-- المرء يرى ويعدّل بياناته فقط
DROP POLICY IF EXISTS users_select_self ON users;
CREATE POLICY users_select_self ON users
    FOR SELECT TO authenticated
    USING (id = auth.uid());

DROP POLICY IF EXISTS users_update_self ON users;
CREATE POLICY users_update_self ON users
    FOR UPDATE TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());

-- المدير يرى مستخدمي مزرعته عبر حقول JWT (user_metadata)
-- (انظر الشرح التقني أعلى الملف: تجنّب التكرار اللانهائي لـ RLS
--  دون اللجوء إلى SECURITY DEFINER)
DROP POLICY IF EXISTS users_select_same_farm ON users;
CREATE POLICY users_select_same_farm ON users
    FOR SELECT TO authenticated
    USING (
        (auth.jwt() -> 'user_metadata' ->> 'role') = 'manager'
        AND farm_id = NULLIF(auth.jwt() -> 'user_metadata' ->> 'farm_id', '')::uuid
    );

-- --- farms -------------------------------------------------
-- قراءة عامة للمصادقين
DROP POLICY IF EXISTS farms_select_all ON farms;
CREATE POLICY farms_select_all ON farms
    FOR SELECT TO authenticated
    USING (true);

-- الكتابة (إضافة/تعديل/حذف) للمدير فقط
DROP POLICY IF EXISTS farms_insert_manager ON farms;
CREATE POLICY farms_insert_manager ON farms
    FOR INSERT TO authenticated
    WITH CHECK (current_user_role() = 'manager');

DROP POLICY IF EXISTS farms_update_manager ON farms;
CREATE POLICY farms_update_manager ON farms
    FOR UPDATE TO authenticated
    USING (current_user_role() = 'manager')
    WITH CHECK (current_user_role() = 'manager');

DROP POLICY IF EXISTS farms_delete_manager ON farms;
CREATE POLICY farms_delete_manager ON farms
    FOR DELETE TO authenticated
    USING (current_user_role() = 'manager');

-- ============================================================
-- 8) سياسات الجداول التشغيلية
-- قاعدة عامة: انتخاب/إدراج/تحديث لأعضاء المزرعة، حذف للمدير فقط
-- (تُطبق بالضبط على: flocks, customers, egg_production, mortality,
--  feed_consumption, feed_received, egg_dispatch, medications)
-- ============================================================
CREATE OR REPLACE FUNCTION public.ensure_operational_policies(p_table name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    EXECUTE format('DROP POLICY IF EXISTS op_select ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_insert ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_update ON %I', p_table);
    EXECUTE format('DROP POLICY IF EXISTS op_delete ON %I', p_table);
    EXECUTE format('CREATE POLICY op_select ON %I FOR SELECT TO authenticated USING (farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_insert ON %I FOR INSERT TO authenticated WITH CHECK (farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_update ON %I FOR UPDATE TO authenticated USING (farm_id = current_user_farm_id()) WITH CHECK (farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_delete ON %I FOR DELETE TO authenticated USING (farm_id = current_user_farm_id() AND current_user_role() = ''manager'')', p_table);
END;
$$;

SELECT public.ensure_operational_policies('flocks');
SELECT public.ensure_operational_policies('customers');
SELECT public.ensure_operational_policies('egg_production');
SELECT public.ensure_operational_policies('mortality');
SELECT public.ensure_operational_policies('feed_consumption');
SELECT public.ensure_operational_policies('feed_received');
SELECT public.ensure_operational_policies('egg_dispatch');
SELECT public.ensure_operational_policies('medications');

-- ============================================================
-- 9) سياسات الجداول المالية والإدارية (المدير فقط)
-- ============================================================
CREATE OR REPLACE FUNCTION public.ensure_manager_policies(p_table name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    EXECUTE format('DROP POLICY IF EXISTS mgr_all ON %I', p_table);
    EXECUTE format('CREATE POLICY mgr_all ON %I FOR ALL TO authenticated USING (current_user_role() = ''manager'') WITH CHECK (current_user_role() = ''manager'')', p_table);
END;
$$;

-- payments / expenses / opening_balances / inventory_items / audit_log
SELECT public.ensure_manager_policies('payments');
SELECT public.ensure_manager_policies('expenses');
SELECT public.ensure_manager_policies('opening_balances');
SELECT public.ensure_manager_policies('inventory_items');
SELECT public.ensure_manager_policies('audit_log');

-- inventory_transactions (بلا farm_id مباشرة): للمدير على عناصر مزرعته
DROP POLICY IF EXISTS mgr_tx ON inventory_transactions;
CREATE POLICY mgr_tx ON inventory_transactions
    FOR ALL TO authenticated
    USING (
        current_user_role() = 'manager'
        AND item_id IN (SELECT i.id FROM inventory_items i WHERE i.farm_id = current_user_farm_id())
    )
    WITH CHECK (
        current_user_role() = 'manager'
        AND item_id IN (SELECT i.id FROM inventory_items i WHERE i.farm_id = current_user_farm_id())
    );

-- medicines_catalog: قراءة للجميع، كتابة للمدير
DROP POLICY IF EXISTS catalog_select ON medicines_catalog;
CREATE POLICY catalog_select ON medicines_catalog
    FOR SELECT TO authenticated
    USING (true);

DROP POLICY IF EXISTS catalog_manager ON medicines_catalog;
CREATE POLICY catalog_manager ON medicines_catalog
    FOR ALL TO authenticated
    USING (current_user_role() = 'manager')
    WITH CHECK (current_user_role() = 'manager');

-- ============================================================
-- 10) سياسات الإشعارات وطلبات التخريج
-- ============================================================
-- app_notifications: قراءة لأعضاء المزرعة، كتابة للمدير
DROP POLICY IF EXISTS notif_read ON app_notifications;
CREATE POLICY notif_read ON app_notifications
    FOR SELECT TO authenticated
    USING (farm_id = current_user_farm_id());

DROP POLICY IF EXISTS notif_manager ON app_notifications;
CREATE POLICY notif_manager ON app_notifications
    FOR ALL TO authenticated
    USING (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    WITH CHECK (current_user_role() = 'manager' AND farm_id = current_user_farm_id());

-- dispatch_requests: قراءة وإدخال لأعضاء المزرعة، القرار/الحذف للمدير
DROP POLICY IF EXISTS dreq_select ON dispatch_requests;
CREATE POLICY dreq_select ON dispatch_requests
    FOR SELECT TO authenticated
    USING (farm_id = current_user_farm_id());

DROP POLICY IF EXISTS dreq_insert ON dispatch_requests;
CREATE POLICY dreq_insert ON dispatch_requests
    FOR INSERT TO authenticated
    WITH CHECK (farm_id = current_user_farm_id());

DROP POLICY IF EXISTS dreq_manager ON dispatch_requests;
CREATE POLICY dreq_manager ON dispatch_requests
    FOR UPDATE TO authenticated
    USING (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    WITH CHECK (current_user_role() = 'manager' AND farm_id = current_user_farm_id());

DROP POLICY IF EXISTS dreq_manager_delete ON dispatch_requests;
CREATE POLICY dreq_manager_delete ON dispatch_requests
    FOR DELETE TO authenticated
    USING (current_user_role() = 'manager' AND farm_id = current_user_farm_id());

-- sync_queue: مغلق تماماً (غير مستخدم من التطبيق)
DROP POLICY IF EXISTS sync_queue_block ON sync_queue;
CREATE POLICY sync_queue_block ON sync_queue
    FOR SELECT TO authenticated
    USING (false);

-- ============================================================
-- 11) الدوال المساعدة للمصادقة والإدارة (SECURITY DEFINER —
--     ضرورية: كتابة auth + التعامل مع المستخدمين قبل وبعد الدخول)
-- ============================================================
CREATE OR REPLACE FUNCTION public.app_user_email(p_uid uuid)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT p_uid::text || '@users.madjana.local';
$$;

CREATE OR REPLACE FUNCTION public.app_password_from_pin(p_pin text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT encode(extensions.digest(p_pin, 'sha256'), 'hex');
$$;

-- البحث بالهاتف قبل الدخول (يجب أن يرى أي مستخدم أياً كان)
CREATE OR REPLACE FUNCTION public.find_user_by_phone(p_phone text)
RETURNS TABLE (id uuid, name text, phone text, role text, farm_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.id::uuid, u.name::text, u.phone::text, u.role::text, u.farm_id::uuid
    FROM public.users AS u
    WHERE u.phone = p_phone
    LIMIT 1;
$$;

-- حارس: المدير فقط ومن نفس المزرعة
CREATE OR REPLACE FUNCTION public.assert_current_is_manager_of(p_farm_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF (SELECT public.current_user_role()) IS DISTINCT FROM 'manager' THEN
        RAISE EXCEPTION 'غير مصرح: هذه العملية للمدير فقط';
    END IF;
    IF (SELECT public.current_user_farm_id()) IS DISTINCT FROM p_farm_id THEN
        RAISE EXCEPTION 'غير مصرح: المستخدم ليس من مزرعتك';
    END IF;
    RETURN true;
END;
$$;

-- إنشاء أول مدجنة ومدير (مرة واحدة فقط عندما يكون users فارغاً)
CREATE OR REPLACE FUNCTION public.bootstrap_create_farm_and_manager(
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
    v_farm_id   uuid;
BEGIN
    IF EXISTS (SELECT 1 FROM users LIMIT 1) THEN
        RAISE EXCEPTION 'يوجد مستخدمون بالفعل — هذه الدالة للتهيئة الأولى فقط';
    END IF;
    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;

    INSERT INTO farms (name, location) VALUES (p_farm_name, NULLIF(p_location, ''))
        RETURNING id INTO v_farm_id;

    -- auth.users.id = users.id = v_auth_uuid (مطابقة تامة)
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
        v_auth_uuid::text, v_auth_uuid,
        jsonb_build_object('sub', v_auth_uuid::text),
        'email', NOW(), NOW(), NOW()
    );

    -- (الـ trigger قد أنشأ الصف أولاً بالدور worker — نكمله هنا)
    INSERT INTO users (id, name, phone, role, pin_hash, farm_id)
    VALUES (v_auth_uuid, p_manager_name, p_phone, 'manager',
            public.app_password_from_pin(p_pin), v_farm_id)
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        phone = EXCLUDED.phone,
        role = EXCLUDED.role,
        pin_hash = EXCLUDED.pin_hash,
        farm_id = EXCLUDED.farm_id;

    RETURN jsonb_build_object(
        'user_id', v_auth_uuid::text,
        'farm_id', v_farm_id::text,
        'email', public.app_user_email(v_auth_uuid)
    );
END;
$$;

-- إنشاء مستخدم (عامل/مشرف/مدير) — للمدير
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
BEGIN
    PERFORM public.assert_current_is_manager_of(p_farm_id::uuid);

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;
    IF p_role NOT IN ('worker', 'supervisor', 'manager') THEN
        RAISE EXCEPTION 'الدور غير صالح';
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

    INSERT INTO users (id, name, phone, role, pin_hash, farm_id)
    VALUES (v_auth_uuid, p_name, p_phone, p_role,
            public.app_password_from_pin(p_pin), p_farm_id::uuid)
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        phone = EXCLUDED.phone,
        role = EXCLUDED.role,
        pin_hash = EXCLUDED.pin_hash,
        farm_id = EXCLUDED.farm_id
    RETURNING * INTO v_row;

    RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_user(
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
    v_target_farm uuid;
BEGIN
    SELECT farm_id INTO v_target_farm FROM users WHERE id = p_uid::uuid;
    PERFORM public.assert_current_is_manager_of(v_target_farm);

    IF p_role IS NOT NULL AND p_role NOT IN ('worker', 'supervisor', 'manager') THEN
        RAISE EXCEPTION 'الدور غير صالح';
    END IF;
    IF p_phone IS NOT NULL AND EXISTS (SELECT 1 FROM users WHERE phone = p_phone AND id <> p_uid::uuid) THEN
        RAISE EXCEPTION 'رقم الهاتف مسجل مسبقاً';
    END IF;

    UPDATE users SET
        name = COALESCE(p_name, name),
        phone = COALESCE(p_phone, phone),
        role = COALESCE(p_role, role)
    WHERE id = p_uid::uuid;

    -- تحديث JWT metadata ليظهر الدور والمزرعة فوراً بعد إعادة الدخول
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
BEGIN
    IF p_new_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;
    SELECT farm_id INTO v_target_farm FROM users WHERE id = p_uid::uuid;
    PERFORM public.assert_current_is_manager_of(v_target_farm);

    UPDATE auth.users
    SET encrypted_password = extensions.crypt(public.app_password_from_pin(p_new_pin), extensions.gen_salt('bf')),
        updated_at = NOW()
    WHERE auth.users.id = p_uid::uuid;

    UPDATE users SET pin_hash = public.app_password_from_pin(p_new_pin)
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
BEGIN
    SELECT farm_id INTO v_target_farm FROM users WHERE id = p_uid::uuid;
    PERFORM public.assert_current_is_manager_of(v_target_farm);
    IF p_uid::uuid = auth.uid() THEN
        RAISE EXCEPTION 'لا يمكنك حذف حسابك الحالي';
    END IF;
    DELETE FROM auth.users WHERE auth.users.id = p_uid::uuid;
END;
$$;

-- ============================================================
-- 12) Triggers الحسابات والتدقيق (تُنشأ بعد الجداول)
-- ============================================================
CREATE OR REPLACE FUNCTION public.calc_total_eggs()
RETURNS TRIGGER AS $$
BEGIN
    NEW.total_eggs := (NEW.cartons * 360) + (NEW.trays * 30) + NEW.loose_eggs;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_calc_total_eggs
    BEFORE INSERT OR UPDATE ON egg_production
    FOR EACH ROW EXECUTE FUNCTION public.calc_total_eggs();

CREATE OR REPLACE FUNCTION public.calc_dispatch_total()
RETURNS TRIGGER AS $$
BEGIN
    NEW.total_eggs := (NEW.cartons * 360) + (NEW.trays * 30);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_calc_dispatch_total
    BEFORE INSERT OR UPDATE ON egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.calc_dispatch_total();

CREATE OR REPLACE FUNCTION public.update_flock_count_on_mortality()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE flocks
    SET current_count = current_count - NEW.count,
        updated_at = NOW()
    WHERE id = NEW.flock_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_flock_count
    AFTER INSERT ON mortality
    FOR EACH ROW EXECUTE FUNCTION public.update_flock_count_on_mortality();

CREATE OR REPLACE FUNCTION public.log_audit_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
BEGIN
    v_user_id := COALESCE(
        (SELECT u.id FROM public.users AS u WHERE u.id = auth.uid()),
        NEW.worker_id
    );
    INSERT INTO audit_log (user_id, action, table_name, record_id, old_values, new_values)
    VALUES (
        v_user_id, TG_OP, TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE TRIGGER trg_audit_egg_production
    AFTER INSERT OR UPDATE OR DELETE ON egg_production
    FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

CREATE TRIGGER trg_audit_mortality
    AFTER INSERT OR UPDATE OR DELETE ON mortality
    FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

CREATE TRIGGER trg_audit_payments
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

CREATE TRIGGER trg_audit_dispatch
    AFTER INSERT OR UPDATE OR DELETE ON egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

CREATE OR REPLACE FUNCTION public.audit_expenses_changes()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_log (user_id, action, table_name, record_id, new_values)
    VALUES (
        auth.uid(), TG_OP, 'expenses',
        COALESCE(NEW.id, OLD.id),
        to_jsonb(COALESCE(NEW, OLD))
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE TRIGGER expenses_audit_trigger
    AFTER INSERT OR UPDATE OR DELETE ON expenses
    FOR EACH ROW EXECUTE FUNCTION public.audit_expenses_changes();

-- ============================================================
-- 13) الصلاحيات العامة + إعادة تحميل مخطط PostgREST
-- ============================================================
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.find_user_by_phone(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bootstrap_create_farm_and_manager(text, text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_user(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_user(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_pin(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farm_id() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
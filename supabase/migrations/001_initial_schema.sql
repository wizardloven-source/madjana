-- ============================================================
-- نظام إدارة مداجن البيض - Schema كامل
-- التاريخ: 2026-08-19
-- ============================================================

-- تفعيل UUID
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- 1. جدول المداجن (farms)
-- ============================================================
CREATE TABLE farms (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    location TEXT,
    owner_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 2. جدول المستخدمين (users)
-- ============================================================
CREATE TABLE users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    phone TEXT UNIQUE NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('worker', 'supervisor', 'manager')),
    pin_hash TEXT NOT NULL, -- PIN مشفّر (4 أرقام)
    farm_id UUID REFERENCES farms(id) ON DELETE SET NULL,
    remember_token TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_users_farm ON users(farm_id);
CREATE INDEX idx_users_role ON users(role);

-- ============================================================
-- 3. جدول القطعان (flocks)
-- ============================================================
CREATE TABLE flocks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    breed TEXT NOT NULL,
    start_date DATE NOT NULL,
    initial_count INTEGER NOT NULL CHECK (initial_count > 0),
    current_count INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'depleted')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_flocks_farm ON flocks(farm_id);
CREATE INDEX idx_flocks_status ON flocks(status);

-- ============================================================
-- 4. جدول إنتاج البيض (egg_production)
-- ============================================================
CREATE TABLE egg_production (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id UUID NOT NULL REFERENCES flocks(id) ON DELETE CASCADE,
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    cartons INTEGER NOT NULL DEFAULT 0 CHECK (cartons >= 0),
    trays INTEGER NOT NULL DEFAULT 0 CHECK (trays >= 0 AND trays < 12),
    loose_eggs INTEGER NOT NULL DEFAULT 0 CHECK (loose_eggs >= 0 AND loose_eggs < 30),
    total_eggs INTEGER NOT NULL DEFAULT 0, -- يُحسب تلقائياً عبر Trigger
    broken_eggs INTEGER DEFAULT 0 CHECK (broken_eggs >= 0),
    dirty_eggs INTEGER DEFAULT 0 CHECK (dirty_eggs >= 0),
    tray_weight_kg NUMERIC(6,2),
    worker_id UUID NOT NULL REFERENCES users(id),
    sync_status TEXT DEFAULT 'synced' CHECK (sync_status IN ('pending', 'synced', 'failed')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT check_broken_dirty CHECK (broken_eggs + dirty_eggs <= total_eggs)
);

CREATE INDEX idx_egg_production_farm ON egg_production(farm_id);
CREATE INDEX idx_egg_production_flock ON egg_production(flock_id);
CREATE INDEX idx_egg_production_date ON egg_production(date);
CREATE INDEX idx_egg_production_sync ON egg_production(sync_status);

-- ============================================================
-- 5. جدول النفوق (mortality)
-- ============================================================
CREATE TABLE mortality (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id UUID NOT NULL REFERENCES flocks(id) ON DELETE CASCADE,
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    count INTEGER NOT NULL CHECK (count > 0),
    reason TEXT NOT NULL CHECK (reason IN (
        'not_eating', 'internal_bleeding', 'immunity_break',
        'heat_stress', 'cannibalism', 'unknown', 'other'
    )),
    reason_other TEXT,
    notes TEXT,
    image_url TEXT,
    worker_id UUID NOT NULL REFERENCES users(id),
    sync_status TEXT DEFAULT 'synced',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT check_reason_other CHECK (
        (reason = 'other' AND reason_other IS NOT NULL) OR
        (reason != 'other' AND reason_other IS NULL)
    )
);

CREATE INDEX idx_mortality_flock ON mortality(flock_id);
CREATE INDEX idx_mortality_date ON mortality(date);

-- ============================================================
-- 6. جدول استهلاك العلف (feed_consumption)
-- ============================================================
CREATE TABLE feed_consumption (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    entry_mode TEXT NOT NULL CHECK (entry_mode IN ('bags', 'kg')),
    bags_count INTEGER DEFAULT 0,
    quantity_kg NUMERIC(10,2) NOT NULL CHECK (quantity_kg > 0),
    worker_id UUID NOT NULL REFERENCES users(id),
    sync_status TEXT DEFAULT 'synced',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 7. جدول استلام العلف (feed_received)
-- ============================================================
CREATE TABLE feed_received (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    entry_mode TEXT NOT NULL CHECK (entry_mode IN ('bags', 'kg', 'ton')),
    quantity NUMERIC(10,2) NOT NULL,
    quantity_kg NUMERIC(10,2) NOT NULL CHECK (quantity_kg > 0),
    feed_type TEXT NOT NULL CHECK (feed_type IN ('starter', 'grower', 'layer')),
    supplier TEXT,
    invoice_number TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 8. جدول التخريج (egg_dispatch)
-- ============================================================
CREATE TABLE egg_dispatch (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    customer_id UUID NOT NULL REFERENCES customers(id),
    cartons INTEGER NOT NULL DEFAULT 0 CHECK (cartons >= 0),
    trays INTEGER NOT NULL DEFAULT 0 CHECK (trays >= 0 AND trays < 12),
    total_eggs INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    payment_status TEXT NOT NULL DEFAULT 'unpaid' 
        CHECK (payment_status IN ('unpaid', 'partial', 'paid')),
    worker_id UUID NOT NULL REFERENCES users(id),
    sync_status TEXT DEFAULT 'synced',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 9. جدول الزبائن (customers) - يجب إنشاؤه قبل egg_dispatch
-- ============================================================
CREATE TABLE customers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    phone TEXT NOT NULL,
    notes TEXT,
    total_debt NUMERIC(12,2) DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- إضافة FK بعد إنشاء الجدول
ALTER TABLE egg_dispatch 
    ADD CONSTRAINT fk_dispatch_customer 
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE RESTRICT;

-- ============================================================
-- 10. جدول المدفوعات (payments) - للمدير فقط
-- ============================================================
CREATE TABLE payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    dispatch_id UUID REFERENCES egg_dispatch(id) ON DELETE SET NULL,
    customer_id UUID NOT NULL REFERENCES customers(id),
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    price_per_carton NUMERIC(10,2) NOT NULL CHECK (price_per_carton >= 0),
    total_due NUMERIC(12,2) NOT NULL CHECK (total_due >= 0),
    amount_paid NUMERIC(12,2) NOT NULL CHECK (amount_paid >= 0),
    payment_method TEXT NOT NULL CHECK (payment_method IN ('cash', 'transfer', 'check', 'credit')),
    due_date DATE,
    notes TEXT,
    manager_id UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT check_amount CHECK (amount_paid <= total_due)
);

-- ============================================================
-- 11. جدول الأدوية (medications)
-- ============================================================
CREATE TABLE medications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    type TEXT NOT NULL CHECK (type IN ('drug', 'vaccine', 'vitamin')),
    medicine_name TEXT NOT NULL,
    dosage TEXT NOT NULL,
    administration_route TEXT NOT NULL CHECK (administration_route IN (
        'water', 'spray', 'injection', 'feed'
    )),
    treatment_days INTEGER,
    withdrawal_days INTEGER DEFAULT 0 CHECK (withdrawal_days >= 0),
    notes TEXT,
    worker_id UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 12. كتالوج الأدوية (medicines_catalog)
-- ============================================================
CREATE TABLE medicines_catalog (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT UNIQUE NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('drug', 'vaccine', 'vitamin')),
    withdrawal_days INTEGER DEFAULT 0 CHECK (withdrawal_days >= 0),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 13. سجل التدقيق (audit_log)
-- ============================================================
CREATE TABLE audit_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    action TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    old_values JSONB,
    new_values JSONB,
    timestamp TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_audit_user ON audit_log(user_id);
CREATE INDEX idx_audit_table ON audit_log(table_name);
CREATE INDEX idx_audit_timestamp ON audit_log(timestamp);

-- ============================================================
-- بذر كتالوج الأدوية (بيانات افتراضية)
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
-- 14. جدول طابور المزامنة (sync_queue) - محلي + سحابي
-- ============================================================
CREATE TABLE sync_queue (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    payload JSONB NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id),
    attempts INTEGER DEFAULT 0,
    last_error TEXT,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'synced', 'failed')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- TRIGGERS - العمليات التلقائية
-- ============================================================

-- Trigger 1: حساب total_eggs تلقائياً
CREATE OR REPLACE FUNCTION calc_total_eggs()
RETURNS TRIGGER AS $$
BEGIN
    NEW.total_eggs := (NEW.cartons * 360) + (NEW.trays * 30) + NEW.loose_eggs;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_calc_total_eggs
    BEFORE INSERT OR UPDATE ON egg_production
    FOR EACH ROW
    EXECUTE FUNCTION calc_total_eggs();

-- Trigger 2: حساب total_eggs في التخريج
CREATE OR REPLACE FUNCTION calc_dispatch_total()
RETURNS TRIGGER AS $$
BEGIN
    NEW.total_eggs := (NEW.cartons * 360) + (NEW.trays * 30);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_calc_dispatch_total
    BEFORE INSERT OR UPDATE ON egg_dispatch
    FOR EACH ROW
    EXECUTE FUNCTION calc_dispatch_total();

-- Trigger 3: تحديث current_count في flocks عند النفوق
CREATE OR REPLACE FUNCTION update_flock_count_on_mortality()
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
    FOR EACH ROW
    EXECUTE FUNCTION update_flock_count_on_mortality();

-- Trigger 4: تسجيل كل UPDATE/DELETE في audit_log
CREATE OR REPLACE FUNCTION log_audit_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id UUID;
BEGIN
    -- جلب user_id من auth.uid() أو من الحقل
    v_user_id := COALESCE(
        (SELECT id FROM users WHERE id = auth.uid()),
        NEW.worker_id
    );
    
    INSERT INTO audit_log (user_id, action, table_name, record_id, old_values, new_values)
    VALUES (
        v_user_id,
        TG_OP,
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END
    );
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_egg_production
    AFTER INSERT OR UPDATE OR DELETE ON egg_production
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();

CREATE TRIGGER trg_audit_mortality
    AFTER INSERT OR UPDATE OR DELETE ON mortality
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();

CREATE TRIGGER trg_audit_payments
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();

CREATE TRIGGER trg_audit_dispatch
    AFTER INSERT OR UPDATE OR DELETE ON egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();

-- ============================================================
-- ROW LEVEL SECURITY (RLS) - فصل الصلاحيات
-- ============================================================

ALTER TABLE farms ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE flocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE egg_production ENABLE ROW LEVEL SECURITY;
ALTER TABLE mortality ENABLE ROW LEVEL SECURITY;
ALTER TABLE feed_consumption ENABLE ROW LEVEL SECURITY;
ALTER TABLE feed_received ENABLE ROW LEVEL SECURITY;
ALTER TABLE egg_dispatch ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE medications ENABLE ROW LEVEL SECURITY;
ALTER TABLE medicines_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- دالة مساعدة لجلب دور المستخدم الحالي
CREATE OR REPLACE FUNCTION current_user_role()
RETURNS TEXT AS $$
    SELECT role FROM users WHERE id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION current_user_farm_id()
RETURNS UUID AS $$
    SELECT farm_id FROM users WHERE id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER;

-- سياسة المدير: يرى كل شيء في مزرعته
CREATE POLICY manager_all_access ON farms
    FOR ALL USING (
        current_user_role() = 'manager' AND 
        (owner_id = auth.uid() OR id = current_user_farm_id())
    );

-- سياسة العامل: يرى فقط السجلات التشغيلية (بدون prices)
CREATE POLICY worker_read_operational ON egg_production
    FOR SELECT USING (
        current_user_role() IN ('worker', 'supervisor', 'manager') AND
        farm_id = current_user_farm_id()
    );

CREATE POLICY worker_insert_operational ON egg_production
    FOR INSERT WITH CHECK (
        current_user_role() IN ('worker', 'supervisor') AND
        farm_id = current_user_farm_id() AND
        worker_id = auth.uid()
    );

-- العامل لا يرى جدول payments أبداً
CREATE POLICY manager_only_payments ON payments
    FOR ALL USING (
        current_user_role() = 'manager' AND
        farm_id = current_user_farm_id()
    );

-- العامل لا يرى الأسعار في dispatch (يُطبّق على مستوى التطبيق)
CREATE POLICY worker_read_dispatch ON egg_dispatch
    FOR SELECT USING (
        current_user_role() IN ('worker', 'supervisor', 'manager') AND
        farm_id = current_user_farm_id()
    );

-- ============================================================
-- FUNCTIONS - دوال مساعدة
-- ============================================================

-- دالة المزامنة الجماعية (تُستدعى من Edge Function)
CREATE OR REPLACE FUNCTION sync_records_batch(
    p_records JSONB,
    p_user_id UUID
) RETURNS JSONB AS $$
DECLARE
    v_record JSONB;
    v_table TEXT;
    v_action TEXT;
    v_result JSONB := '{"success": 0, "failed": 0}'::jsonb;
BEGIN
    FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
    LOOP
        v_table := v_record->>'table';
        v_action := v_record->>'action';
        
        BEGIN
            IF v_action = 'INSERT' THEN
                EXECUTE format(
                    'INSERT INTO %I SELECT * FROM jsonb_populate_record(null::%I, $1)',
                    v_table, v_table
                ) USING v_record->'data';
            END IF;
            
            v_result := jsonb_set(v_result, '{success}', 
                ((v_result->>'success')::int + 1)::text::jsonb);
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_set(v_result, '{failed}', 
                ((v_result->>'failed')::int + 1)::text::jsonb);
        END;
    END LOOP;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
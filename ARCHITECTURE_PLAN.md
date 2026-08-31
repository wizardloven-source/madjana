# خطة إعادة الهيكلة الشاملة - Madjana

##نظرة عامة
38 مشكلة معمارية مقسمة على 6 مراحل تنفيذية.

---

## المرحلة 1: الأمان وتكامل البيانات (الأولوية القصوى)
> المشاكل: #2, #3, #6, #7, #29, #30, #31

### 1.1 إصلاح sync_records_batch
**المشكلة:** الدالة تسمح بأي جدول وأي عملية بدون تحقق.
**الحل:**
```sql
-- حذف الدالة القديمة
DROP FUNCTION IF EXISTS sync_records_batch(jsonb, uuid);

-- دالة جديدة مع whitelist صارم
CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_record JSONB;
    v_table TEXT;
    v_action TEXT;
    v_record_id UUID;
    v_payload JSONB;
    v_allowed_tables TEXT[] := ARRAY[
        'egg_production', 'mortality', 'feed_consumption',
        'feed_received', 'egg_dispatch', 'medications',
        'customers', 'flocks', 'expenses', 'inventory_items',
        'inventory_transactions', 'opening_balances'
    ];
    v_blocked_tables TEXT[] := ARRAY[
        'users', 'payments', 'audit_log', 'farms',
        'sync_changes', 'medicines_catalog'
    ];
    v_success_ids UUID[] := ARRAY[]::UUID[];
    v_failed_ids UUID[] := ARRAY[]::UUID[];
    v_conflict_ids UUID[] := ARRAY[]::UUID[];
    v_user_farm_id UUID;
    v_existing_version BIGINT;
    v_new_version BIGINT;
BEGIN
    -- الحصول على مزرعة المستخدم من auth.uid()
    SELECT farm_id INTO v_user_farm_id
    FROM public.users WHERE id = auth.uid();

    IF v_user_farm_id IS NULL THEN
        RAISE EXCEPTION 'المستخدم غير مرتبط بأي مزرعة';
    END IF;

    FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
    LOOP
        v_table := v_record->>'table_name';
        v_action := v_record->>'operation';
        v_record_id := (v_record->>'record_id')::UUID;
        v_payload := v_record->>'payload';

        -- فحص 1: الجدول مسموح؟
        IF v_table = ANY(v_blocked_tables) THEN
            v_failed_ids := array_append(v_failed_ids, v_record_id);
            CONTINUE;
        END IF;

        IF NOT (v_table = ANY(v_allowed_tables)) THEN
            v_failed_ids := array_append(v_failed_ids, v_record_id);
            CONTINUE;
        END IF;

        -- فحص 2: العملية مسموحة؟
        IF v_action NOT IN ('INSERT', 'UPDATE', 'DELETE') THEN
            v_failed_ids := array_append(v_failed_ids, v_record_id);
            CONTINUE;
        END IF;

        -- فحص 3: farm_id مطابق؟
        IF (v_payload->>'farm_id')::UUID != v_user_farm_id THEN
            v_failed_ids := array_append(v_failed_ids, v_record_id);
            CONTINUE;
        END IF;

        -- معالجة حسب العملية
        IF v_action = 'INSERT' THEN
            -- فحص التكرار
            EXECUTE format('SELECT version FROM %I WHERE id = $1', v_table)
            INTO v_existing_version USING v_record_id;

            IF v_existing_version IS NOT NULL THEN
                v_conflict_ids := array_append(v_conflict_ids, v_record_id);
                CONTINUE;
            END IF;

            -- إدراج مع version
            v_payload := v_payload || jsonb_build_object(
                'version', 1,
                'server_version', nextval('global_sync_version')
            );
            EXECUTE format(
                'INSERT INTO %I SELECT * FROM jsonb_populate_record(null::%I, $1)',
                v_table, v_table
            ) USING v_payload;
            v_success_ids := array_append(v_success_ids, v_record_id);

        ELSIF v_action = 'UPDATE' THEN
            -- فحص الversion
            SELECT version INTO v_existing_version
            FROM egg_production WHERE id = v_record_id;

            IF v_existing_version IS NULL THEN
                v_failed_ids := array_append(v_failed_ids, v_record_id);
                CONTINUE;
            END IF;

            IF v_existing_version != (v_payload->>'previous_version')::BIGINT THEN
                v_conflict_ids := array_append(v_conflict_ids, v_record_id);
                CONTINUE;
            END IF;

            v_new_version := v_existing_version + 1;
            v_payload := v_payload || jsonb_build_object(
                'version', v_new_version,
                'server_version', nextval('global_sync_version')
            );
            v_payload := v_payload - 'previous_version';

            EXECUTE format(
                'UPDATE %I SET %s WHERE id = $1',
                v_table,
                string_agg(key || ' = $2->>''' || key || '''', ', ')
            ) USING v_record_id, v_payload;
            v_success_ids := array_append(v_success_ids, v_record_id);

        ELSIF v_action = 'DELETE' THEN
            EXECUTE format(
                'UPDATE %I SET deleted_at = NOW(), version = version + 1 WHERE id = $1',
                v_table
            ) USING v_record_id;
            v_success_ids := array_append(v_success_ids, v_record_id);
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'success_ids', to_jsonb(v_success_ids),
        'failed_ids', to_jsonb(v_failed_ids),
        'conflict_ids', to_jsonb(v_conflict_ids)
    );
END;
$$;
```

### 1.2 إصلاح trigger النفوق
**المشكلة:** لا يتعامل مع UPDATE/DELETE، ولا يمنع السالب.
**الحل:**
```sql
CREATE OR REPLACE FUNCTION public.update_flock_count_on_mortality()
RETURNS TRIGGER AS $$
DECLARE
    v_current_count INTEGER;
    v_delta INTEGER;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- فحص: هل العدد الكافي؟
        SELECT current_count INTO v_current_count
        FROM flocks WHERE id = NEW.flock_id;

        IF v_current_count < NEW.count THEN
            RAISE EXCEPTION 'عدد النفوق (%) يتجاوز العدد الحالي (%)',
                NEW.count, v_current_count;
        END IF;

        UPDATE flocks
        SET current_count = current_count - NEW.count,
            updated_at = NOW()
        WHERE id = NEW.flock_id;

    ELSIF TG_OP = 'UPDATE' THEN
        -- حساب الفرق
        v_delta := NEW.count - OLD.count;

        SELECT current_count INTO v_current_count
        FROM flocks WHERE id = NEW.flock_id;

        IF v_current_count - v_delta < 0 THEN
            RAISE EXCEPTION 'التعديل سيؤدي لعدد سالب (%)',
                v_current_count - v_delta;
        END IF;

        UPDATE flocks
        SET current_count = current_count - v_delta,
            updated_at = NOW()
        WHERE id = NEW.flock_id;

    ELSIF TG_OP = 'DELETE' THEN
        UPDATE flocks
        SET current_count = current_count + OLD.count,
            updated_at = NOW()
        WHERE id = OLD.flock_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- حذف القديم وإنشاء الجديد
DROP TRIGGER IF EXISTS trg_update_flock_count ON mortality;
CREATE TRIGGER trg_update_flock_count
    AFTER INSERT OR UPDATE OR DELETE ON mortality
    FOR EACH ROW EXECUTE FUNCTION public.update_flock_count_on_mortality();
```

### 1.3 إضافة version field للجداول
**الجداول المتأثرة:** egg_production, mortality, feed_consumption, feed_received, egg_dispatch, medications, customers, flocks, expenses

```sql
-- إضافة حقول version و sync metadata
ALTER TABLE egg_production ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE mortality ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE feed_consumption ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE feed_received ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE egg_dispatch ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE medications ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE payments ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;

-- فهارس للأداء
CREATE INDEX IF NOT EXISTS idx_egg_production_version ON egg_production(id, version);
CREATE INDEX IF NOT EXISTS idx_mortality_version ON mortality(id, version);
```

### 1.4 إصلاح SECURITY DEFINER
**المشكلة:** الدوال تستخدم auth.uid() لكن sync_records_batch تتلقى p_user_id من العميل.
**الحل:** إزالة p_user_id واستخدام auth.uid() دائماً.

### 1.5 حماية flock_id من cross-farm
**الحل:** إضافة trigger يتحقق أن flock.farm_id = egg_production.farm_id
```sql
CREATE OR REPLACE FUNCTION public.validate_flock_farm()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM flocks
        WHERE id = NEW.flock_id AND farm_id = NEW.farm_id
    ) THEN
        RAISE EXCEPTION 'القطيع لا ينتمي لهذه المزرعة';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_egg_flock
    BEFORE INSERT OR UPDATE ON egg_production
    FOR EACH ROW EXECUTE FUNCTION validate_flock_farm();

CREATE TRIGGER trg_validate_mortality_flock
    BEFORE INSERT OR UPDATE ON mortality
    FOR EACH ROW EXECUTE FUNCTION validate_flock_farm();
```

### 1.6 استخدام auth.uid() بدل Client
**الملفات المتأثرة:**
- `packages/data/lib/src/datasources/remote/supabase_auth_datasource.dart`
- `packages/data/lib/src/repositories/sync_repository_impl.dart`

**التغيير:** إزالة أي مكان يمرر user_id من الـ client، واستخدام auth.uid() في كل الدوال.

---

## المرحلة 2: تحسين هيكل قاعدة البيانات
> المشاكل: #8, #9, #10, #13, #22, #23, #24, #25, #26

### 2.1 تحسين نموذج القطيع
```sql
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS strain TEXT;
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS hatch_date DATE;
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS arrival_date DATE;
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS sex TEXT CHECK (sex IN ('male', 'female', 'mixed'));
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS house_id UUID;
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS supplier TEXT;
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS purchase_cost NUMERIC(12,2);
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS target_lay_start DATE;
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS depletion_date DATE;
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS notes TEXT;

-- عمر القطيع = Today - Hatch Date ( حساب مُشتق )
-- أو إضافة view
CREATE OR REPLACE VIEW flocks_with_age AS
SELECT f.*,
    CASE
        WHEN f.hatch_date IS NOT NULL THEN
            EXTRACT(DAY FROM (CURRENT_DATE - f.hatch_date)) / 7
        ELSE NULL
    END AS age_weeks,
    CASE
        WHEN f.hatch_date IS NOT NULL THEN
            CURRENT_DATE - f.hatch_date
        ELSE NULL
    END AS age_days
FROM flocks f;
```

### 2.2 إضافة houses/sections
```sql
CREATE TABLE IF NOT EXISTS houses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    capacity INTEGER,
    section_count INTEGER DEFAULT 1,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (farm_id, name)
);

CREATE TABLE IF NOT EXISTS house_sections (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    house_id UUID NOT NULL REFERENCES houses(id) ON DELETE CASCADE,
    section_number INTEGER NOT NULL,
    capacity INTEGER,
    current_flock_id UUID REFERENCES flocks(id),
    notes TEXT,
    UNIQUE (house_id, section_number)
);

-- ربط flocks بالـ houses
ALTER TABLE flocks ADD CONSTRAINT fk_flock_house
    FOREIGN KEY (house_id) REFERENCES houses(id) ON DELETE SET NULL;
```

### 2.3 إضافة shift للإنتاج
```sql
ALTER TABLE egg_production ADD COLUMN IF NOT EXISTS shift TEXT
    CHECK (shift IN ('morning', 'noon', 'evening'));

-- Unique constraint: سجل واحد لكل قطيع/تاريخ/وردية
ALTER TABLE egg_production ADD CONSTRAINT unique_flock_date_shift
    UNIQUE (flock_id, date, shift);
```

### 2.4 Egg Inventory Ledger
```sql
CREATE TABLE IF NOT EXISTS egg_inventory_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id UUID REFERENCES flocks(id),
    transaction_type TEXT NOT NULL CHECK (transaction_type IN (
        'PRODUCTION', 'DISPATCH', 'BREAKAGE', 'ADJUSTMENT',
        'RETURN', 'TRANSFER', 'OPENING'
    )),
    quantity INTEGER NOT NULL,
    reference_id UUID,
    reference_table TEXT,
    notes TEXT,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_egg_inv_farm ON egg_inventory_transactions(farm_id);
CREATE INDEX idx_egg_inv_flock ON egg_inventory_transactions(flock_id);
CREATE INDEX idx_egg_inv_date ON egg_inventory_transactions(created_at);

-- View: رصيد البيض الحالي
CREATE OR REPLACE VIEW egg_inventory_balance AS
SELECT
    farm_id,
    flock_id,
    SUM(CASE WHEN transaction_type IN ('PRODUCTION', 'RETURN', 'OPENING')
        THEN quantity ELSE 0 END) AS total_in,
    SUM(CASE WHEN transaction_type IN ('DISPATCH', 'BREAKAGE')
        THEN quantity ELSE 0 END) AS total_out,
    SUM(CASE WHEN transaction_type = 'ADJUSTMENT'
        THEN quantity ELSE 0 END) AS adjustments,
    SUM(CASE WHEN transaction_type IN ('PRODUCTION', 'RETURN', 'OPENING')
        THEN quantity ELSE 0 END)
    - SUM(CASE WHEN transaction_type IN ('DISPATCH', 'BREAKAGE')
        THEN quantity ELSE 0 END)
    AS balance
FROM egg_inventory_transactions
GROUP BY farm_id, flock_id;
```

### 2.5 نقل الطيور
```sql
CREATE TABLE IF NOT EXISTS bird_transfers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id UUID NOT NULL REFERENCES flocks(id),
    from_house_id UUID REFERENCES houses(id),
    from_section INTEGER,
    to_house_id UUID REFERENCES houses(id),
    to_section INTEGER,
    count INTEGER NOT NULL CHECK (count > 0),
    transfer_date DATE NOT NULL,
    reason TEXT,
    performed_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 2.6 شراء/بيع الطيور
```sql
CREATE TABLE IF NOT EXISTS bird_movements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id UUID NOT NULL REFERENCES flocks(id),
    movement_type TEXT NOT NULL CHECK (movement_type IN (
        'PURCHASE', 'SALE', 'TRANSFER_IN', 'TRANSFER_OUT', 'ADJUSTMENT'
    )),
    count INTEGER NOT NULL,
    unit_price NUMERIC(10,2),
    total_cost NUMERIC(12,2),
    movement_date DATE NOT NULL,
    supplier_or_buyer TEXT,
    notes TEXT,
    performed_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_bird_movements_flock ON bird_movements(flock_id);
```

### 2.7 دورة حياة القطيع
```sql
-- إضافة lifecycle_status
ALTER TABLE flocks ADD COLUMN IF NOT EXISTS lifecycle_status TEXT
    CHECK (lifecycle_status IN (
        'PURCHASED', 'RECEIVED', 'ACTIVE', 'LAYING',
        'TRANSFERRED', 'PARTIALLY_SOLD', 'DEPLETED'
    )) DEFAULT 'PURCHASED';

-- تحديث تلقائي
CREATE OR REPLACE FUNCTION public.update_flock_lifecycle()
RETURNS TRIGGER AS $$
BEGIN
    -- إذا كان هناك إنتاج بيض، يصبح LAYING
    IF EXISTS (SELECT 1 FROM egg_production WHERE flock_id = NEW.flock_id) THEN
        UPDATE flocks SET lifecycle_status = 'LAYING'
        WHERE id = NEW.flock_id AND lifecycle_status = 'ACTIVE';
    END IF;

    -- إذا عدده الحالي = 0، يصبح DEPLETED
    IF NEW.current_count <= 0 THEN
        UPDATE flocks SET lifecycle_status = 'DEPLETED', depletion_date = CURRENT_DATE
        WHERE id = NEW.flock_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

---

## المرحلة 3: تحسين النماذج ومنطق الأعمال
> المشاكل: #11, #12, #14, #15, #16, #37, #38

### 3.1 تكوين تعبئة البيض (قابل للتعديل)
```sql
-- إعدادات المزرعة (بالفعل في farms)
-- eggs_per_carton = 360
-- eggs_per_tray = 30
-- feed_bag_weight_kg = 50.0

-- تحديث calc_total_eggs لاستخدام إعدادات المزرعة
CREATE OR REPLACE FUNCTION public.calc_total_eggs()
RETURNS TRIGGER AS $$
DECLARE
    v_eggs_per_tray INTEGER;
    v_trays_per_carton INTEGER;
BEGIN
    SELECT eggs_per_tray INTO v_eggs_per_tray
    FROM farms WHERE id = NEW.farm_id;

    v_eggs_per_tray := COALESCE(v_eggs_per_tray, 30);
    v_trays_per_carton := 360 / v_eggs_per_tray;

    NEW.total_eggs := (NEW.cartons * v_eggs_per_tray * v_trays_per_carton)
                    + (NEW.trays * v_eggs_per_tray)
                    + NEW.loose_eggs;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### 3.2 تحسين كسر/تلوث البيض
```sql
ALTER TABLE egg_production ADD COLUMN IF NOT EXISTS rejected_eggs INTEGER DEFAULT 0;
ALTER TABLE egg_production ADD COLUMN IF NOT EXISTS sellable_eggs INTEGER;

-- trigger حساب sellable
CREATE OR REPLACE FUNCTION public.calc_sellable_eggs()
RETURNS TRIGGER AS $$
BEGIN
    NEW.sellable_eggs := NEW.total_eggs - NEW.broken_eggs - NEW.dirty_eggs - NEW.rejected_eggs;
    IF NEW.sellable_eggs < 0 THEN
        RAISE EXCEPTION 'البيض الصالح لا يمكن أن يكون سالباً';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### 3.3 Customer Ledger
```sql
CREATE TABLE IF NOT EXISTS customer_ledger (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    customer_id UUID NOT NULL REFERENCES customers(id),
    transaction_type TEXT NOT NULL CHECK (transaction_type IN (
        'DEBIT', 'CREDIT', 'ADJUSTMENT'
    )),
    amount NUMERIC(12,2) NOT NULL,
    reference_id UUID,
    reference_table TEXT,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- View: أرصدة الزبائن
CREATE OR REPLACE VIEW customer_balances AS
SELECT
    customer_id,
    farm_id,
    SUM(CASE WHEN transaction_type = 'DEBIT' THEN amount ELSE 0 END)
    - SUM(CASE WHEN transaction_type = 'CREDIT' THEN amount ELSE 0 END)
    AS balance
FROM customer_ledger
GROUP BY customer_id, farm_id;
```

### 3.4 تحسين الدفعات (Factoring而不是solo record)
```sql
-- جدول الفواتير
CREATE TABLE IF NOT EXISTS sales_invoices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    dispatch_id UUID NOT NULL REFERENCES egg_dispatch(id),
    customer_id UUID NOT NULL REFERENCES customers(id),
    total_amount NUMERIC(12,2) NOT NULL,
    paid_amount NUMERIC(12,2) DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'unpaid'
        CHECK (status IN ('unpaid', 'partial', 'paid')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- جدول دفعات الزبائن
CREATE TABLE IF NOT EXISTS customer_payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    invoice_id UUID NOT NULL REFERENCES sales_invoices(id),
    customer_id UUID NOT NULL REFERENCES customers(id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    payment_method TEXT NOT NULL CHECK (payment_method IN (
        'cash', 'transfer', 'check', 'credit'
    )),
    payment_date DATE NOT NULL,
    notes TEXT,
    recorded_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 3.5 ربط الدواء بالقطيع
```sql
CREATE TABLE IF NOT EXISTS medication_treatments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id UUID NOT NULL REFERENCES flocks(id),
    house_id UUID REFERENCES houses(id),
    section INTEGER,
    medicine_name TEXT NOT NULL,
    medicine_type TEXT NOT NULL CHECK (medicine_type IN ('drug', 'vaccine', 'vitamin')),
    dosage TEXT NOT NULL,
    administration_route TEXT NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE,
    treatment_days INTEGER,
    withdrawal_until DATE,
    bird_count INTEGER,
    administered_by UUID REFERENCES users(id),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 3.6 تطبيع كمية العلف المستلمة
```sql
-- feed_received: quantity و quantity_kg
-- quantity_kg يُحسب من quantity × تحويلات الوحدة
CREATE OR REPLACE FUNCTION public.normalize_feed_received()
RETURNS TRIGGER AS $$
BEGIN
    NEW.quantity_kg := CASE
        WHEN NEW.entry_mode = 'bags' THEN NEW.quantity * 50  -- kgPerBag from farm settings
        WHEN NEW.entry_mode = 'kg' THEN NEW.quantity
        WHEN NEW.entry_mode = 'ton' THEN NEW.quantity * 1000
    END;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_normalize_feed_received
    BEFORE INSERT OR UPDATE ON feed_received
    FOR EACH ROW EXECUTE FUNCTION normalize_feed_received();
```

### 3.7 Master Data Tables
```sql
CREATE TABLE IF NOT EXISTS suppliers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    phone TEXT,
    specialty TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (farm_id, name)
);

CREATE TABLE IF NOT EXISTS feed_types (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT UNIQUE NOT NULL,
    description TEXT,
    category TEXT CHECK (category IN ('starter', 'grower', 'layer', 'main'))
);

-- بذور feed_types
INSERT INTO feed_types (name, description, category) VALUES
    ('بادئ', 'علف مرحلة البادئ', 'starter'),
    ('نامي', 'علف مرحلة النمو', 'grower'),
    ('بياض', 'علف مرحلة البياض', 'layer'),
    ('علف رئيسي', 'علف رئيسي', 'main');
```

---

## المرحلة 4: KPIs والتحليلات
> المشاكل: #19, #20, #21, #22

### 4.1 Hen-Day Egg Production %
```sql
CREATE OR REPLACE VIEW hen_day_production AS
SELECT
    ep.farm_id,
    ep.flock_id,
    f.breed,
    f.hatch_date,
    EXTRACT(DAY FROM (CURRENT_DATE - f.hatch_date)) / 7 AS age_weeks,
    ep.date,
    ep.total_eggs,
    f.current_count AS live_birds,
    CASE
        WHEN f.current_count > 0 THEN
            ROUND((ep.total_eggs::NUMERIC / f.current_count) * 100, 2)
        ELSE 0
    END AS hen_day_pct
FROM egg_production ep
JOIN flocks f ON f.id = ep.flock_id
WHERE ep.deleted_at IS NULL;
```

### 4.2 Feed Conversion Ratio (FCR)
```sql
CREATE OR REPLACE VIEW feed_conversion_ratio AS
SELECT
    fc.farm_id,
    fc.date,
    SUM(fc.quantity_kg) AS total_feed_kg,
    SUM(ep.total_eggs) AS total_eggs,
    -- كتلة البيض ≈ عدد البيض × 60g / 1000
    ROUND(SUM(ep.total_eggs) * 0.060, 2) AS egg_mass_kg,
    CASE
        WHEN SUM(ep.total_eggs) > 0 THEN
            ROUND(SUM(fc.quantity_kg) / (SUM(ep.total_eggs) * 0.060), 2)
        ELSE NULL
    END AS fcr
FROM feed_consumption fc
LEFT JOIN egg_production ep ON ep.farm_id = fc.farm_id AND ep.date = fc.date
WHERE fc.deleted_at IS NULL
GROUP BY fc.farm_id, fc.date;
```

### 4.3 Mortality Rates
```sql
CREATE OR REPLACE VIEW mortality_rates AS
SELECT
    m.farm_id,
    m.flock_id,
    f.breed,
    f.initial_count,
    f.current_count,
    m.date,
    m.count,
    -- معدل اليومي
    ROUND((m.count::NUMERIC / GREATEST(f.current_count, 1)) * 100, 3) AS daily_rate_pct,
    -- الإجمالي التراكمي
    ROUND(
        (SELECT SUM(m2.count)::NUMERIC / f.initial_count * 100
         FROM mortality m2 WHERE m2.flock_id = m.flock_id AND m2.date <= m.date),
        2
    ) AS cumulative_rate_pct
FROM mortality m
JOIN flocks f ON f.id = m.flock_id;

-- View: ملخص أسبوعي
CREATE OR REPLACE VIEW mortality_weekly_summary AS
SELECT
    m.farm_id,
    m.flock_id,
    DATE_TRUNC('week', m.date) AS week_start,
    SUM(m.count) AS weekly_deaths,
    ROUND(
        (SUM(m.count)::NUMERIC / (SELECT f.initial_count FROM flocks f WHERE f.id = m.flock_id)) * 100,
        2
    ) AS weekly_rate_pct
FROM mortality m
GROUP BY m.farm_id, m.flock_id, DATE_TRUNC('week', m.date);
```

### 4.4 Feed per Hen
```sql
CREATE OR REPLACE VIEW feed_per_hen AS
SELECT
    fc.farm_id,
    fc.date,
    SUM(fc.quantity_kg) AS total_feed_kg,
    AVG(f.current_count) AS avg_live_birds,
    CASE
        WHEN AVG(f.current_count) > 0 THEN
            ROUND(SUM(fc.quantity_kg) / AVG(f.current_count), 3)
        ELSE NULL
    END AS feed_per_hen_kg
FROM feed_consumption fc
JOIN flocks f ON f.farm_id = fc.farm_id
WHERE fc.deleted_at IS NULL AND f.status = 'active'
GROUP BY fc.farm_id, fc.date;
```

### 4.5 Dashboard Views
```sql
-- ملخص يومي شامل
CREATE OR REPLACE VIEW daily_farm_summary AS
SELECT
    f.farm_id,
    f.id AS flock_id,
    f.breed,
    f.current_count,
    EXTRACT(DAY FROM (CURRENT_DATE - f.hatch_date)) / 7 AS age_weeks,
    COALESCE(ep_stats.total_eggs, 0) AS eggs_produced,
    COALESCE(m_stats.total_mortality, 0) AS deaths,
    COALESCE(fc_stats.total_feed_kg, 0) AS feed_kg,
    CASE
        WHEN f.current_count > 0 THEN
            ROUND((COALESCE(ep_stats.total_eggs, 0)::NUMERIC / f.current_count) * 100, 2)
        ELSE 0
    END AS hen_day_pct,
    CASE
        WHEN f.current_count > 0 THEN
            ROUND((COALESCE(fc_stats.total_feed_kg, 0) / (COALESCE(ep_stats.total_eggs, 0) * 0.060)), 2)
        ELSE NULL
    END AS fcr
FROM flocks f
LEFT JOIN (
    SELECT flock_id, SUM(total_eggs) AS total_eggs
    FROM egg_production WHERE date = CURRENT_DATE
    GROUP BY flock_id
) ep_stats ON ep_stats.flock_id = f.id
LEFT JOIN (
    SELECT flock_id, SUM(count) AS total_mortality
    FROM mortality WHERE date = CURRENT_DATE
    GROUP BY flock_id
) m_stats ON m_stats.flock_id = f.id
LEFT JOIN (
    SELECT farm_id, SUM(quantity_kg) AS total_feed_kg
    FROM feed_consumption WHERE date = CURRENT_DATE
    GROUP BY farm_id
) fc_stats ON fc_stats.farm_id = f.farm_id
WHERE f.status = 'active';
```

---

## المرحلة 5: الأمان والتدقيق
> المشاكل: #28, #29, #32, #33, #34, #35, #36

### 5.1 Worker Dispatch View
```sql
CREATE OR REPLACE VIEW worker_dispatch_view AS
SELECT
    d.id,
    d.farm_id,
    d.date,
    c.name AS customer_name,
    d.cartons,
    d.trays,
    d.total_eggs,
    d.payment_status
FROM egg_dispatch d
JOIN customers c ON c.id = d.customer_id;

-- سياسة: العامل يرى view فقط
CREATE POLICY worker_dispatch_read ON egg_dispatch
    FOR SELECT TO authenticated
    USING (
        current_user_role() = 'worker'
        AND farm_id = current_user_farm_id()
    );
```

### 5.2 تحسين Audit Log
```sql
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS farm_id UUID REFERENCES farms(id);
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS device_id TEXT;
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS ip_address INET;
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS request_id UUID;
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS reason TEXT;

-- إصلاح trigger لتسجيل auth.uid() دائماً
CREATE OR REPLACE FUNCTION public.log_audit_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL AND TG_OP != 'INSERT' THEN
        v_user_id := OLD.worker_id;
    END IF;
    IF v_user_id IS NULL THEN
        v_user_id := NEW.worker_id;
    END IF;

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
```

### 5.3 تغطية كل الجداول بالتدقيق
```sql
-- إضافة triggers للجداول المفقودة
CREATE TRIGGER trg_audit_feed_consumption
    AFTER INSERT OR UPDATE OR DELETE ON feed_consumption
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();

CREATE TRIGGER trg_audit_feed_received
    AFTER INSERT OR UPDATE OR DELETE ON feed_received
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();

CREATE TRIGGER trg_audit_medications
    AFTER INSERT OR UPDATE OR DELETE ON medications
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();

CREATE TRIGGER trg_audit_flocks
    AFTER INSERT OR UPDATE OR DELETE ON flocks
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();

CREATE TRIGGER trg_audit_customers
    AFTER INSERT OR UPDATE OR DELETE ON customers
    FOR EACH ROW EXECUTE FUNCTION log_audit_changes();
```

### 5.4 إزالة remember_token من users
```sql
-- نقله للـ session فقط (بالفعل موجود في session table)
ALTER TABLE users DROP COLUMN IF EXISTS remember_token;
```

### 5.5 تحسين PIN (ملف Flutter فقط)
**لا يتطلب تغيير قاعدة البيانات.**
**التغييرات في كود Dart:**
- استخدام `bcrypt` بدلاً من SHA-256
- إضافة rate limiting بعد 3 محاولات خاطئة
- إضافة lockout لمدة 5 دقائق

---

## المرحلة 6: بروتوكول المزامنة
> المشاكل: #2, #3, #4, #5

### 6.1 استخدام Version-based Conflict Detection
**النماذج المتأثرة (Dart):**
```dart
// إضافة version field لكل النماذج
abstract class SyncableModel {
  int? get version;
  int? get previousVersion;
}

// في كل نموذج:
class EggProductionModel {
  // ... الحقول الموجودة
  final int? version;
  final int? previousVersion;
}
```

### 6.2 معالجة UPDATE/DELETE في المزامنة
**الحل:** استخدام `deleted_at` field (Soft Delete) بدلاً من DELETE الفعلي.
```sql
-- كل جدول له deleted_at
ALTER TABLE egg_production ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE mortality ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE feed_consumption ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
-- ... إلخ
```

### 6.3 Pull Remote Changes
```sql
CREATE OR REPLACE FUNCTION public.pull_remote_changes(
    p_farm_id UUID,
    p_last_version BIGINT DEFAULT 0
)
RETURNS TABLE (
    table_name TEXT,
    record_id UUID,
    operation TEXT,
    payload JSONB,
    server_version BIGINT
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        sc.table_name,
        sc.record_id,
        sc.operation,
        sc.payload,
        sc.server_version
    FROM sync_changes sc
    WHERE sc.farm_id = p_farm_id
      AND sc.server_version > p_last_version
    ORDER BY sc.server_version ASC;
$$;
```

---

## ترتيب التنفيذ المقترح

| المرحلة | المدة التقريبية | الملفات المتأثرة |
|---------|----------------|-----------------|
| 1. الأمان | 2-3 أيام | SQL + Dart sync |
| 2. هيكل قاعدة البيانات | 3-4 أيام | SQL + Models + DAOs |
| 3. نماذج ومنطق الأعمال | 2-3 أيام | Models + Repositories |
| 4. KPIs والتحليلات | 1-2 أيام | SQL + Dashboard |
| 5. الأمان والتدقيق | 1-2 أيام | SQL + Auth |
| 6. بروتوكول المزامنة | 2-3 أيام | Dart sync layer |
| **المجموع** | **11-17 يوم** | |

---

## ملاحظات التنفيذ

1. **كل مرحلة يمكن تنفيذها بشكل مستقل** بدون كسر المراحل الأخرى
2. **الrenames additions فقط** — لا يُحذف شيء قديم
3. **Backward compatible** — النماذج القديمة تتعامل مع الحقول الجديدة كـ nullable
4. **local DB migration** — يجب تحديث `local_database.dart` مع كل مرحلة
5. **Sync layer** — المرحلة 6 تتطلب تحديث `sync_repository_impl.dart` بالكامل

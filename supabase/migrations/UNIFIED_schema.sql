-- ============================================================
-- UNIFIED MIGRATION: Madjana Database Schema
-- Generated: 2026-09-06 15:27
-- Replaces: 20250101000000_initial_sql + all subsequent migrations
-- Tables: 26 | Functions: merged to latest | Policies: merged to latest
-- ============================================================

BEGIN;

-- ============================================================
-- SECTION 1: TABLES (from initial schema, cleaned)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- 0) تنظيف أي بقايا
-- ============================================================
DROP TRIGGER IF EXISTS handle_new_user ON auth.users;
DROP FUNCTION IF EXISTS public.handle_new_user();

DROP FUNCTION IF EXISTS calc_total_eggs(), calc_dispatch_total(),
    update_flock_count_on_mortality(), audit_expenses_changes(), log_audit_changes() CASCADE;

DROP TABLE IF EXISTS sync_queue, app_notifications, dispatch_requests,
    audit_log, medicines_catalog, medications, payments, egg_dispatch,
    customers, feed_received, feed_consumption, mortality, egg_production,
    flocks, opening_balances, inventory_transactions, inventory_items,
    expenses, users, farms, sync_changes, sync_checkpoint,
    idempotency_log, app_settings CASCADE;

DROP FUNCTION IF EXISTS public.find_user_by_phone(text);
DROP FUNCTION IF EXISTS public.current_user_role(), public.current_user_farm_id(),
    public.current_role_safe(), public.current_farm_safe() CASCADE;
DROP FUNCTION IF EXISTS public.app_user_email(uuid), public.app_password_from_pin(text) CASCADE;
DROP FUNCTION IF EXISTS public.assert_current_is_manager_of(uuid) CASCADE;
DROP FUNCTION IF EXISTS public.bootstrap_create_farm_and_manager(text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.admin_create_user(text, text, text, text, text);
DROP FUNCTION IF EXISTS public.admin_update_user(text, text, text, text, boolean);
DROP FUNCTION IF EXISTS public.admin_reset_pin(text, text);
DROP FUNCTION IF EXISTS public.admin_delete_user(text);
DROP FUNCTION IF EXISTS public.sync_records_batch(jsonb);
DROP FUNCTION IF EXISTS public.pull_remote_changes(uuid, bigint);
DROP FUNCTION IF EXISTS public.cleanup_old_sync_changes(int, uuid);
DROP FUNCTION IF EXISTS public.maintain_sync_changes(int, uuid);
DROP FUNCTION IF EXISTS public.compact_sync_changes(uuid);
DROP FUNCTION IF EXISTS public.refresh_sync_checkpoint(uuid);
DROP FUNCTION IF EXISTS public.auto_maintain_sync();
DROP FUNCTION IF EXISTS public.ensure_operational_policies(name);
DROP FUNCTION IF EXISTS public.ensure_manager_policies(name);
DROP FUNCTION IF EXISTS public.update_updated_at_column();

DROP SEQUENCE IF EXISTS global_sync_version;

-- ============================================================
-- 1) التسلسل العام للمزامنة
-- ============================================================
CREATE SEQUENCE global_sync_version START WITH 1 INCREMENT BY 1;

-- ============================================================
-- 2) المزارع والمستخدمون
-- ============================================================
CREATE TABLE farms (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name       TEXT NOT NULL,
    location   TEXT,
    owner_id   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    feed_bag_weight_kg   NUMERIC(6,2) NOT NULL DEFAULT 50.0,
    eggs_per_carton      INTEGER NOT NULL DEFAULT 360,
    eggs_per_tray        INTEGER NOT NULL DEFAULT 30,
    default_mortality_rate NUMERIC(5,2) NOT NULL DEFAULT 0.0,
    carton_low_threshold INTEGER NOT NULL DEFAULT 100,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE users (
    id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    name          TEXT,
    phone         TEXT UNIQUE,
    role          TEXT NOT NULL DEFAULT 'worker'
                      CHECK (role IN ('worker', 'manager', 'system_admin')),
    pin_hash      TEXT,
    farm_id       UUID REFERENCES farms(id) ON DELETE SET NULL,
    remember_token TEXT,
    is_active     BOOLEAN NOT NULL DEFAULT true,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    locked_until  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_users_farm ON users(farm_id);
CREATE INDEX idx_users_role ON users(role);
CREATE INDEX idx_users_phone ON users(phone);

-- علاقة مجموعة-إلى-مجموعة بين المستخدمين والمداجن (ربط بدون تحويل)
CREATE TABLE user_farms (
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    farm_id    UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, farm_id)
);

CREATE INDEX idx_user_farms_farm ON user_farms(farm_id);

-- ============================================================
-- 3) الجداول التشغيلية
-- ============================================================
CREATE TABLE flocks (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id        UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    breed          TEXT NOT NULL,
    start_date     DATE NOT NULL,
    initial_count  INTEGER NOT NULL CHECK (initial_count > 0),
    current_count  INTEGER NOT NULL CHECK (current_count >= 0),
    status         TEXT NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'depleted')),
    sections_count INTEGER NOT NULL DEFAULT 1,
    version        BIGINT NOT NULL DEFAULT 1,
    created_at     TIMESTAMPTZ DEFAULT NOW(),
    updated_at     TIMESTAMPTZ DEFAULT NOW(),
    deleted_at     TIMESTAMPTZ
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
    is_global  BOOLEAN NOT NULL DEFAULT false,
    version    BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);
CREATE INDEX idx_customers_farm ON customers(farm_id);

-- نطاق الزبون: المدير/مدير النظام يضيف زبوناً "عاماً" يظهر لكل المداجن،
-- أما العامل فيظل الزبون محصوراً في مدجنته فقط.
CREATE OR REPLACE FUNCTION public.customers_scope_guard()
RETURNS TRIGGER AS $$
BEGIN
    NEW.is_global := COALESCE(current_user_role() IN ('manager', 'system_admin'), false);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_customers_scope_guard ON customers;
CREATE TRIGGER trg_customers_scope_guard
    BEFORE INSERT ON customers
    FOR EACH ROW EXECUTE FUNCTION public.customers_scope_guard();

CREATE TABLE egg_production (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id        UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id       UUID NOT NULL REFERENCES flocks(id) ON DELETE CASCADE,
    date           DATE NOT NULL CHECK (date <= CURRENT_DATE),
    cartons        INTEGER NOT NULL DEFAULT 0 CHECK (cartons >= 0),
    trays          INTEGER NOT NULL DEFAULT 0 CHECK (trays >= 0 AND trays < 12),
    loose_eggs     INTEGER NOT NULL DEFAULT 0 CHECK (loose_eggs >= 0 AND loose_eggs < 30),
    total_eggs     INTEGER NOT NULL DEFAULT 0,
    broken_eggs    INTEGER DEFAULT 0 CHECK (broken_eggs >= 0),
    dirty_eggs     INTEGER DEFAULT 0 CHECK (dirty_eggs >= 0),
    tray_weight_kg NUMERIC(6,2),
    section_no     INTEGER,
    worker_id      UUID NOT NULL REFERENCES users(id),
    sync_status    TEXT DEFAULT 'synced'
                       CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    version        BIGINT NOT NULL DEFAULT 1,
    created_at     TIMESTAMPTZ DEFAULT NOW(),
    updated_at     TIMESTAMPTZ DEFAULT NOW(),
    deleted_at     TIMESTAMPTZ,
    CONSTRAINT check_broken_dirty CHECK (broken_eggs + dirty_eggs <= total_eggs)
);
CREATE INDEX idx_egg_production_farm ON egg_production(farm_id);
CREATE INDEX idx_egg_production_flock ON egg_production(flock_id);
CREATE INDEX idx_egg_production_date ON egg_production(date);
CREATE UNIQUE INDEX idx_egg_production_flock_date_section ON egg_production(flock_id, date, COALESCE(section_no, 0)) WHERE deleted_at IS NULL;
DROP INDEX IF EXISTS idx_egg_production_flock_date;

CREATE TABLE mortality (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id      UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id     UUID NOT NULL REFERENCES flocks(id) ON DELETE CASCADE,
    date         DATE NOT NULL CHECK (date <= CURRENT_DATE),
    count        INTEGER NOT NULL CHECK (count > 0),
    reason       TEXT NOT NULL CHECK (reason IN (
        'not_eating', 'internal_bleeding', 'immunity_break',
        'heat_stress', 'cannibalism', 'unknown', 'other'
    )),
    reason_other TEXT,
    notes        TEXT,
    image_url    TEXT,
    section_no   INTEGER,
    worker_id    UUID NOT NULL REFERENCES users(id),
    sync_status  TEXT DEFAULT 'synced'
                     CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_at   TIMESTAMPTZ DEFAULT NOW(),
    version      BIGINT NOT NULL DEFAULT 1,
    deleted_at   TIMESTAMPTZ,
    CONSTRAINT check_reason_other CHECK (
        (reason = 'other' AND reason_other IS NOT NULL AND length(trim(reason_other)) > 0) OR
        (reason != 'other' AND reason_other IS NULL)
    )
);
CREATE INDEX idx_mortality_flock ON mortality(flock_id);
CREATE INDEX idx_mortality_date ON mortality(date);

CREATE TABLE feed_consumption (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id      UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id     UUID REFERENCES flocks(id) ON DELETE SET NULL,
    date         DATE NOT NULL CHECK (date <= CURRENT_DATE),
    entry_mode   TEXT NOT NULL CHECK (entry_mode IN ('bags', 'kg')),
    bags_count   INTEGER DEFAULT 0,
    quantity_kg  NUMERIC(10,2) NOT NULL CHECK (quantity_kg > 0),
    section_no   INTEGER,
    worker_id    UUID NOT NULL REFERENCES users(id),
    sync_status  TEXT DEFAULT 'synced'
                     CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_at   TIMESTAMPTZ DEFAULT NOW(),
    version      BIGINT NOT NULL DEFAULT 1,
    deleted_at   TIMESTAMPTZ,
    CONSTRAINT check_feed_consumption_mode CHECK (
        (entry_mode = 'kg') OR
        (entry_mode = 'bags' AND bags_count > 0 AND quantity_kg = bags_count * 24)
    )
);

CREATE TABLE feed_received (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id        UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id       UUID REFERENCES flocks(id),
    date           DATE NOT NULL CHECK (date <= CURRENT_DATE),
    entry_mode     TEXT NOT NULL CHECK (entry_mode IN ('bags', 'kg', 'ton')),
    quantity       NUMERIC(10,2) NOT NULL,
    quantity_kg    NUMERIC(10,2) NOT NULL CHECK (quantity_kg > 0),
    feed_type      TEXT NOT NULL CHECK (feed_type IN ('main', 'starter', 'grower', 'layer')),
    supplier       TEXT,
    invoice_number TEXT,
    notes          TEXT,
    price_per_kg   NUMERIC(10,2),
    section_no     INTEGER,
    worker_id      UUID NOT NULL REFERENCES users(id),
    sync_status  TEXT DEFAULT 'synced'
                     CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    version      BIGINT NOT NULL DEFAULT 1,
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_at   TIMESTAMPTZ DEFAULT NOW(),
    deleted_at   TIMESTAMPTZ,
    CONSTRAINT check_feed_received_mode CHECK (
        (quantity > 0) AND (
            (entry_mode = 'bags' AND quantity_kg = quantity * 24) OR
            (entry_mode = 'kg'   AND quantity_kg = quantity) OR
            (entry_mode = 'ton'  AND quantity_kg = quantity * 1000)
        )
    )
);

CREATE TABLE egg_dispatch (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id         UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id        UUID REFERENCES flocks(id),
    date            DATE NOT NULL CHECK (date <= CURRENT_DATE),
    customer_id     UUID NOT NULL REFERENCES customers(id),
    cartons         INTEGER NOT NULL DEFAULT 0 CHECK (cartons >= 0),
    trays           INTEGER NOT NULL DEFAULT 0 CHECK (trays >= 0 AND trays < 12),
    total_eggs      INTEGER NOT NULL DEFAULT 0,
    tray_weight_kg  NUMERIC(6,2),
    notes           TEXT,
    payment_status  TEXT NOT NULL DEFAULT 'unpaid'
                        CHECK (payment_status IN ('unpaid', 'partial', 'paid')),
    worker_id       UUID NOT NULL REFERENCES users(id),
    sync_status  TEXT DEFAULT 'synced'
                     CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    version      BIGINT NOT NULL DEFAULT 1,
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
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
    currency         TEXT NOT NULL DEFAULT 'dollar' CHECK (currency IN ('dollar', 'lira')),
    exchange_rate    NUMERIC(12,4),
    due_date         DATE,
    notes            TEXT,
    manager_id       UUID NOT NULL REFERENCES users(id),
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    updated_at       TIMESTAMPTZ DEFAULT NOW(),
    deleted_at       TIMESTAMPTZ,
    sync_status      TEXT DEFAULT 'synced'
                         CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    version          BIGINT NOT NULL DEFAULT 1,
    CONSTRAINT check_amount CHECK (amount_paid <= total_due)
);

CREATE TABLE medications (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id              UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    flock_id             UUID REFERENCES flocks(id) ON DELETE SET NULL,
    date                 DATE NOT NULL CHECK (date <= CURRENT_DATE),
    type                 TEXT NOT NULL CHECK (type IN ('drug', 'vaccine', 'vitamin')),
    medicine_name        TEXT NOT NULL,
    dosage               TEXT NOT NULL,
    administration_route TEXT NOT NULL CHECK (administration_route IN (
        'water', 'spray', 'injection', 'feed'
    )),
    treatment_days       INTEGER,
    withdrawal_days      INTEGER DEFAULT 0 CHECK (withdrawal_days >= 0),
    notes                TEXT,
    worker_id            UUID NOT NULL REFERENCES users(id),
    created_at           TIMESTAMPTZ DEFAULT NOW(),
    updated_at           TIMESTAMPTZ DEFAULT NOW(),
    deleted_at           TIMESTAMPTZ,
    sync_status          TEXT DEFAULT 'synced'
                             CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    version              BIGINT NOT NULL DEFAULT 1
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
        'transport', 'feed', 'medicine', 'carton', 'other'
    )),
    description TEXT,
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    currency    TEXT NOT NULL DEFAULT 'dollar' CHECK (currency IN ('dollar', 'lira')),
    exchange_rate NUMERIC(12,4),
    carton_bundles INTEGER,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,
    sync_status TEXT DEFAULT 'synced'
                    CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    version     BIGINT NOT NULL DEFAULT 1
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
    version             BIGINT NOT NULL DEFAULT 1,
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
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id        UUID REFERENCES farms(id) ON DELETE SET NULL,
    user_id        UUID REFERENCES users(id) ON DELETE SET NULL,
    action         TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    table_name     TEXT NOT NULL,
    record_id      UUID NOT NULL,
    old_values     JSONB,
    new_values     JSONB,
    device_id      TEXT,
    ip_address     TEXT,
    correlation_id TEXT,
    created_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_audit_user ON audit_log(user_id);
CREATE INDEX idx_audit_table ON audit_log(table_name);
CREATE INDEX idx_audit_timestamp ON audit_log(created_at);
CREATE INDEX idx_audit_farm ON audit_log(farm_id);

CREATE TABLE idempotency_log (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    operation_id    TEXT NOT NULL UNIQUE,
    user_id         UUID REFERENCES users(id),
    farm_id         UUID REFERENCES farms(id),
    table_name      TEXT NOT NULL,
    record_id       UUID NOT NULL,
    operation       TEXT NOT NULL,
    status          TEXT NOT NULL,
    result          JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_idempotency_op ON idempotency_log(operation_id);
CREATE INDEX idx_idempotency_user ON idempotency_log(user_id, operation_id);

CREATE TABLE app_settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO app_settings (key, value, updated_at)
SELECT 'secure.bootstrap_token',
       md5(gen_random_uuid()::text || clock_timestamp()::text),
       NOW()
WHERE NOT EXISTS (SELECT 1 FROM app_settings WHERE key = 'secure.bootstrap_token');

INSERT INTO app_settings (key, value, updated_at) VALUES
    ('sync.retention_days', '30', NOW()),
    ('sync.maintenance_interval_minutes', '360', NOW())
ON CONFLICT (key) DO NOTHING;

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

CREATE TABLE sync_changes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    table_name      TEXT NOT NULL,
    record_id       UUID NOT NULL,
    operation       TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    farm_id         UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    device_id       TEXT,
    user_id         UUID REFERENCES auth.users(id),
    payload         JSONB,
    server_version  BIGINT DEFAULT nextval('global_sync_version'),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_sync_changes_farm_server ON sync_changes(farm_id, server_version);
CREATE INDEX idx_sync_changes_record ON sync_changes(table_name, record_id);

CREATE TABLE sync_checkpoint (
    farm_id           UUID PRIMARY KEY REFERENCES farms(id) ON DELETE CASCADE,
    latest_version    BIGINT NOT NULL DEFAULT 0,
    purged_below      BIGINT NOT NULL DEFAULT 0,
    last_maintenance  TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_sync_checkpoint_latest ON sync_checkpoint(latest_version);

-- ============================================================
-- 4) بذرة كتالوج الأدوية
-- ============================================================
INSERT INTO medicines_catalog (name, type, withdrawal_days, notes) VALUES
    ('حامض الستريك (Citric Acid)', 'drug', 0, 'محفظ شرب'),
    ('أموكسيسيلين (Amoxicillin)', 'drug', 5, 'مضاد حيوي واسع الطيف'),
    ('إنروفلوكساسين (Enrofloxacin)', 'drug', 7, 'مضاد حيوي للجهاز التنفسي'),
    ('دوكسيسيكلين (Doxycycline)', 'drug', 5, 'مضاد حيوي'),
    ('لقاح نيوكاسل (Newcastle)', 'vaccine', 0, 'تحصين'),
    ('لقاح جامبورو (Gumboro)', 'vaccine', 0, 'تحصين'),
    ('فيتامين A,D3,E', 'vitamin', 0, 'فيتامينات ذائبة في الدهون'),
    ('فيتامين C', 'vitamin', 0, 'دعم المناعة'),
    ('مولتي فيتامين (Multivitamin)', 'vitamin', 0, 'فيتامينات متكاملة');

-- ============================================================
-- 5) الدوال الأساسية
-- ============================================================

-- تحديث updated_at تلقائياً
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- دوال الهوية
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

-- جميع المداجن المرتبط بها المستخدم الحالي (مصفوفة معرّفات)
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

-- المداجن المرتبط بها المستخدم الحالي مع أسمائها (لمبدّل المداجن)
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

-- تحديد المدجنة النشطة للمستخدم الحالي (عضو في المدجنة أو system_admin)
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

-- تحويل PIN إلى كلمة مرور
CREATE OR REPLACE FUNCTION public.app_password_from_pin(p_pin text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT 'madjana$' || p_pin;
$$;

-- بريد اصطناعي لكل حساب
CREATE OR REPLACE FUNCTION public.app_user_email(p_uid uuid)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_uid::text || '@users.madjana.local';
$$;

-- ============================================================
-- 6) الحماية من تعداد أرقام الهاتف (phone enumeration)
-- ============================================================

CREATE TABLE IF NOT EXISTS login_throttle (
    key         TEXT PRIMARY KEY,
    hits        INTEGER NOT NULL DEFAULT 0,
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_hit    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION public.throttle_max_hits()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 10; $$;

CREATE OR REPLACE FUNCTION public.throttle_window_seconds()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 60; $$;

CREATE OR REPLACE FUNCTION public.throttle_exceeded(
    p_key text,
    p_max int DEFAULT 10,
    p_window_seconds int DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_hits int;
BEGIN
    INSERT INTO login_throttle (key, hits, window_start, last_hit)
    VALUES (p_key, 1, NOW(), NOW())
    ON CONFLICT (key) DO UPDATE SET
        last_hit = NOW(),
        hits = CASE
            WHEN login_throttle.window_start < NOW() - (p_window_seconds || ' seconds')::interval THEN 1
            ELSE login_throttle.hits + 1
        END,
        window_start = CASE
            WHEN login_throttle.window_start < NOW() - (p_window_seconds || ' seconds')::interval THEN NOW()
            ELSE login_throttle.window_start
        END
    RETURNING hits INTO v_hits;

    RETURN v_hits > p_max;
END;
$$;

GRANT EXECUTE ON FUNCTION public.throttle_exceeded(text, int, int) TO anon, authenticated;

-- ============================================================
-- 7) حماية تسجيل الدخول: قفل الحساب + حدّ معدل المحاولات
-- ============================================================

CREATE OR REPLACE FUNCTION public.login_lock_max_attempts()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 5; $$;

CREATE OR REPLACE FUNCTION public.login_lock_duration_seconds()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 900; $$;

CREATE OR REPLACE FUNCTION public.check_login_allowed(p_phone text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_max     int := public.login_lock_max_attempts();
    v_lock_s  int := public.login_lock_duration_seconds();
    v_failed  int;
    v_locked  timestamptz;
    v_now     timestamptz := NOW();
    v_left    int;
    v_rem     int := 0;
BEGIN
    p_phone := regexp_replace(p_phone, '[^0-9]', '', 'g');

    SELECT failed_attempts, locked_until INTO v_failed, v_locked
    FROM public.users WHERE phone = p_phone LIMIT 1;

    v_failed := COALESCE(v_failed, 0);
    v_locked := COALESCE(v_locked, NULL);

    IF v_locked IS NOT NULL AND v_locked > v_now THEN
        v_rem := GREATEST(1, EXTRACT(EPOCH FROM (v_locked - v_now)))::int;
        RETURN jsonb_build_object('allowed', false, 'locked', true, 'lock_seconds', v_rem, 'attempts_left', 0);
    END IF;

    v_left := GREATEST(0, v_max - v_failed);
    RETURN jsonb_build_object('allowed', true, 'locked', false, 'lock_seconds', 0, 'attempts_left', v_left);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_login_failure(p_phone text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_max     int := public.login_lock_max_attempts();
    v_lock_s  int := public.login_lock_duration_seconds();
    v_failed  int;
BEGIN
    p_phone := regexp_replace(p_phone, '[^0-9]', '', 'g');

    IF NOT EXISTS (SELECT 1 FROM public.users WHERE phone = p_phone) THEN
        RETURN jsonb_build_object('locked', false, 'attempts_left', -1);
    END IF;

    UPDATE public.users
    SET failed_attempts = failed_attempts + 1,
        locked_until = CASE
            WHEN (failed_attempts + 1) >= v_max THEN NOW() + (v_lock_s || ' seconds')::interval
            ELSE locked_until
        END,
        updated_at = NOW()
    WHERE phone = p_phone
    RETURNING failed_attempts INTO v_failed;

    IF v_failed >= v_max THEN
        RETURN jsonb_build_object('locked', true, 'attempts_left', 0);
    END IF;
    RETURN jsonb_build_object('locked', false, 'attempts_left', GREATEST(0, v_max - v_failed));
END;
$$;

CREATE OR REPLACE FUNCTION public.record_login_success(p_uid uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_uid IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: معرف غير صالح';
    END IF;
    UPDATE public.users SET
        failed_attempts = 0,
        locked_until = NULL,
        updated_at = NOW()
    WHERE id = p_uid AND is_active = true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_login_allowed(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_login_success(uuid) TO anon, authenticated;

-- ============================================================
-- 8) Triggers الحسابات
-- ============================================================

CREATE OR REPLACE FUNCTION public.calc_total_eggs()
RETURNS TRIGGER AS $$
DECLARE
    v_carton int;
    v_tray   int;
BEGIN
    SELECT fr.eggs_per_carton, fr.eggs_per_tray
    INTO v_carton, v_tray
    FROM flocks f
    JOIN farms fr ON fr.id = f.farm_id
    WHERE f.id = NEW.flock_id;
    v_carton := COALESCE(v_carton, 360);
    v_tray   := COALESCE(v_tray, 30);
    NEW.total_eggs := (COALESCE(NEW.cartons, 0) * v_carton)
                    + (COALESCE(NEW.trays, 0) * v_tray)
                    + COALESCE(NEW.loose_eggs, 0);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_calc_total_eggs
    BEFORE INSERT OR UPDATE ON egg_production
    FOR EACH ROW EXECUTE FUNCTION public.calc_total_eggs();

CREATE OR REPLACE FUNCTION public.calc_dispatch_total()
RETURNS TRIGGER AS $$
DECLARE
    v_carton int;
    v_tray   int;
BEGIN
    SELECT fr.eggs_per_carton, fr.eggs_per_tray
    INTO v_carton, v_tray
    FROM farms fr
    WHERE fr.id = NEW.farm_id;
    v_carton := COALESCE(v_carton, 360);
    v_tray   := COALESCE(v_tray, 30);
    NEW.total_eggs := (COALESCE(NEW.cartons, 0) * v_carton)
                    + (COALESCE(NEW.trays, 0) * v_tray);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_calc_dispatch_total
    BEFORE INSERT OR UPDATE ON egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.calc_dispatch_total();

-- ============================================================
-- 9) find_user_by_phone
-- ============================================================
CREATE OR REPLACE FUNCTION public.find_user_by_phone(p_phone text)
RETURNS TABLE (id uuid)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.id::uuid
    FROM public.users AS u
    WHERE u.phone = p_phone
      AND u.is_active = true
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.find_user_by_phone(text) TO anon, authenticated;

-- ============================================================
-- 10) is_system_admin
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_system_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users
        WHERE id = auth.uid()
          AND role = 'system_admin'
          AND is_active = true
    );
$$;

GRANT EXECUTE ON FUNCTION public.is_system_admin() TO anon, authenticated;

-- ============================================================
-- 11) assert_current_is_manager_of
-- ============================================================
CREATE OR REPLACE FUNCTION public.assert_current_is_manager_of(p_farm_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF public.is_system_admin() THEN
        RETURN true;
    END IF;

    IF (SELECT public.current_user_role()) IS DISTINCT FROM 'manager' THEN
        RAISE EXCEPTION 'غير مصرح: هذه العملية للمدير فقط';
    END IF;
    IF (SELECT public.current_user_farm_id()) IS DISTINCT FROM p_farm_id THEN
        RAISE EXCEPTION 'غير مصرح: المستخدم ليس من مزرعتك';
    END IF;
    RETURN true;
END;
$$;

-- ============================================================
-- 12) handle_new_user
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role text;
BEGIN
    v_role := NULLIF(NEW.raw_user_meta_data ->> 'role', '');
    IF v_role = 'supervisor' THEN v_role := 'manager'; END IF;
    IF v_role IS NULL THEN v_role := 'worker'; END IF;

    INSERT INTO public.users (id, name, phone, role, farm_id, is_active)
    VALUES (
        NEW.id,
        NULLIF(NEW.raw_user_meta_data ->> 'full_name', ''),
        NULLIF(NEW.raw_user_meta_data ->> 'phone', ''),
        v_role,
        NULLIF(NEW.raw_user_meta_data ->> 'farm_id', '')::uuid,
        true
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
-- 13) validate_flock_farm - حماية ضد cross-farm operations
-- ============================================================
CREATE OR REPLACE FUNCTION public.validate_flock_farm()
RETURNS TRIGGER AS $$
DECLARE
    v_farm_id uuid;
BEGIN
    IF NEW.flock_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT farm_id INTO v_farm_id FROM flocks WHERE id = NEW.flock_id;
    IF v_farm_id IS NULL THEN
        RAISE EXCEPTION 'الدجاجة غير موجودة: %', NEW.flock_id;
    END IF;
    IF v_farm_id != NEW.farm_id THEN
        RAISE EXCEPTION 'الدجاجة لا تنتمي لهذه المزرعة';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_validate_flock_farm ON egg_production;
CREATE TRIGGER trg_validate_flock_farm
    BEFORE INSERT OR UPDATE ON egg_production
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_mortality ON mortality;
CREATE TRIGGER trg_validate_flock_mortality
    BEFORE INSERT OR UPDATE ON mortality
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_feed ON feed_consumption;
CREATE TRIGGER trg_validate_flock_feed
    BEFORE INSERT OR UPDATE ON feed_consumption
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_med ON medications;
CREATE TRIGGER trg_validate_flock_med
    BEFORE INSERT OR UPDATE ON medications
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_ob ON opening_balances;
CREATE TRIGGER trg_validate_flock_ob
    BEFORE INSERT OR UPDATE ON opening_balances
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

-- ============================================================
-- 14) validate_dispatch_refs
-- ============================================================
CREATE OR REPLACE FUNCTION public.validate_dispatch_refs()
RETURNS TRIGGER AS $$
DECLARE
    v_flock_farm uuid;
    v_cust_farm  uuid;
BEGIN
    IF NEW.flock_id IS NOT NULL THEN
        SELECT farm_id INTO v_flock_farm FROM flocks WHERE id = NEW.flock_id;
        IF v_flock_farm IS NULL THEN
            RAISE EXCEPTION 'القطيع غير موجود: %', NEW.flock_id;
        END IF;
        IF v_flock_farm != NEW.farm_id THEN
            RAISE EXCEPTION 'القطيع لا ينتمي لهذه المزرعة';
        END IF;
    END IF;
    IF NEW.customer_id IS NOT NULL THEN
        SELECT farm_id INTO v_cust_farm FROM customers WHERE id = NEW.customer_id;
        IF v_cust_farm IS NULL THEN
            RAISE EXCEPTION 'الزبون غير موجود: %', NEW.customer_id;
        END IF;
        IF v_cust_farm != NEW.farm_id THEN
            RAISE EXCEPTION 'الزبون لا ينتمي لهذه المزرعة';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_validate_dispatch_refs ON dispatch_requests;
CREATE TRIGGER trg_validate_dispatch_refs
    BEFORE INSERT OR UPDATE ON dispatch_requests
    FOR EACH ROW EXECUTE FUNCTION public.validate_dispatch_refs();

-- ============================================================
-- 15) الصلاحيات العامة + إعادة تحميل مخطط PostgREST
-- ============================================================
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;

-- ============================================================
-- 16) RLS للجداول الجديدة
-- ============================================================
ALTER TABLE idempotency_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS idemp_only_owner ON idempotency_log;
CREATE POLICY idemp_only_owner ON idempotency_log
    FOR ALL TO authenticated
    USING (user_id = auth.uid());

DROP POLICY IF EXISTS audit_select_manager ON audit_log;
CREATE POLICY audit_select_manager ON audit_log
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR (farm_id = current_user_farm_id() AND current_user_role() = 'manager')
    );

-- ============================================================
-- 17) قيود المجال المالية
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_payment_refs()
RETURNS TRIGGER AS $$
DECLARE
    v_dispatch_customer uuid;
    v_dispatch_farm     uuid;
    v_customer_farm     uuid;
BEGIN
    SELECT farm_id INTO v_customer_farm FROM customers WHERE id = NEW.customer_id;
    IF v_customer_farm IS NULL THEN
        RAISE EXCEPTION 'الزبون غير موجود: %', NEW.customer_id;
    END IF;
    IF v_customer_farm != NEW.farm_id THEN
        RAISE EXCEPTION 'الزبون لا ينتمي لهذه المزرعة';
    END IF;

    IF NEW.dispatch_id IS NOT NULL THEN
        SELECT c.farm_id, d.customer_id
        INTO v_dispatch_farm, v_dispatch_customer
        FROM egg_dispatch d
        JOIN customers c ON c.id = d.customer_id
        WHERE d.id = NEW.dispatch_id;
        IF v_dispatch_customer IS NULL THEN
            RAISE EXCEPTION 'الطلب غير موجود: %', NEW.dispatch_id;
        END IF;
        IF v_dispatch_customer != NEW.customer_id THEN
            RAISE EXCEPTION 'الدفع مرتبط بطلب زبون آخر';
        END IF;
        IF v_dispatch_farm != NEW.farm_id THEN
            RAISE EXCEPTION 'الطلب لا ينتمي لهذه المزرعة';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_payment_refs ON payments;
CREATE TRIGGER trg_validate_payment_refs
    BEFORE INSERT OR UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION public.validate_payment_refs();

CREATE OR REPLACE FUNCTION public.guard_customers_total_debt()
RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('app.allow_debt_update', true) IS NULL THEN
        NEW.total_debt := OLD.total_debt;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_guard_customer_debt ON customers;
CREATE TRIGGER trg_guard_customer_debt
    BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION public.guard_customers_total_debt();

CREATE OR REPLACE FUNCTION public.recalc_customer_debt()
RETURNS TRIGGER AS $$
DECLARE
    v_new_cust uuid;
    v_old_cust uuid;
    v_custs uuid[];
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_custs := ARRAY[OLD.customer_id];
    ELSIF TG_OP = 'INSERT' THEN
        v_custs := ARRAY[NEW.customer_id];
    ELSE
        v_custs := ARRAY[OLD.customer_id, NEW.customer_id];
    END IF;

    PERFORM set_config('app.allow_debt_update', 'on', true);
    FOR v_new_cust IN
        SELECT DISTINCT unnest(v_custs) WHERE unnest(v_custs) IS NOT NULL
    LOOP
        UPDATE customers
        SET total_debt = COALESCE((
            SELECT SUM(total_due - amount_paid)
            FROM payments
            WHERE customer_id = v_new_cust AND deleted_at IS NULL
        ), 0),
        updated_at = NOW()
        WHERE id = v_new_cust;
    END LOOP;
    PERFORM set_config('app.allow_debt_update', 'off', true);
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_recalc_customer_debt ON payments;
CREATE TRIGGER trg_recalc_customer_debt
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION public.recalc_customer_debt();

-- ============================================================
-- 18) سياسات Storage
-- ============================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('farm-images', 'farm-images', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS farm_images_insert_farm_scoped ON storage.objects;
CREATE POLICY farm_images_insert_farm_scoped ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'farm-images'
        AND (storage.foldername(name))[1] = 'farms'
        AND (storage.foldername(name))[2] = COALESCE(current_user_farm_id()::text, '')
        AND (storage.foldername(name))[3] = 'mortality'
    );

DROP POLICY IF EXISTS farm_images_update_farm_scoped ON storage.objects;
CREATE POLICY farm_images_update_farm_scoped ON storage.objects
    FOR UPDATE TO authenticated
    USING (
        bucket_id = 'farm-images'
        AND (storage.foldername(name))[1] = 'farms'
        AND (storage.foldername(name))[2] = COALESCE(current_user_farm_id()::text, '')
    )
    WITH CHECK (
        bucket_id = 'farm-images'
        AND (storage.foldername(name))[1] = 'farms'
        AND (storage.foldername(name))[2] = COALESCE(current_user_farm_id()::text, '')
    );

DROP POLICY IF EXISTS farm_images_delete_farm_scoped ON storage.objects;
CREATE POLICY farm_images_delete_farm_scoped ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'farm-images'
        AND (storage.foldername(name))[1] = 'farms'
        AND (storage.foldername(name))[2] = COALESCE(current_user_farm_id()::text, '')
    );

-- ============================================================
-- 19) آلية السحب من الخادم (Server → Client Push)
-- ============================================================

CREATE OR REPLACE FUNCTION public.populate_sync_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
    v_farm_id uuid;
    v_op      text;
    v_payload jsonb;
BEGIN
    IF current_setting('app.skip_sync_trigger', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    v_user_id := auth.uid();
    IF v_user_id IS NULL OR v_user_id::text = '00000000-0000-0000-0000-000000000000' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    v_farm_id := COALESCE(NEW.farm_id, OLD.farm_id);
    IF v_farm_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' THEN v_op := 'INSERT';
    ELSIF TG_OP = 'UPDATE' THEN v_op := 'UPDATE';
    ELSE v_op := 'DELETE';
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_payload := to_jsonb(OLD);
    ELSE
        v_payload := to_jsonb(NEW);
    END IF;
    v_payload := v_payload - 'sync_status' - 'deleted_at';

    INSERT INTO sync_changes (table_name, record_id, operation, farm_id, user_id, payload)
    VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), v_op, v_farm_id, v_user_id, v_payload);

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'flocks', 'customers', 'egg_production', 'mortality',
        'feed_consumption', 'feed_received', 'egg_dispatch', 'medications',
        'expenses', 'inventory_items', 'inventory_transactions',
        'opening_balances', 'dispatch_requests', 'payments',
        'app_settings', 'app_notifications'
    ] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_populate_sync ON %I; ' ||
            'CREATE TRIGGER trg_populate_sync ' ||
            'AFTER INSERT OR UPDATE OR DELETE ON %I ' ||
            'FOR EACH ROW EXECUTE FUNCTION public.populate_sync_changes()',
            t, t
        );
    END LOOP;
END $$;

-- ============================================================
-- 20) sync_can_write / sync_can_read
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_can_write(p_role text, p_table text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE p_role
            WHEN 'worker' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications'
            )
            WHEN 'manager' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'flocks', 'expenses', 'payments',
                'inventory_items', 'inventory_transactions',
                'opening_balances'
            )
            WHEN 'system_admin' THEN p_table NOT IN ('users', 'farms')
            ELSE false
        END;
$$;

CREATE OR REPLACE FUNCTION public.sync_can_read(p_role text, p_table text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE p_role
            WHEN 'worker' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications'
            )
            WHEN 'manager' THEN p_table IN (
                'egg_production', 'mortality', 'feed_consumption',
                'feed_received', 'egg_dispatch', 'medications',
                'customers', 'flocks', 'expenses', 'payments',
                'inventory_items', 'inventory_transactions',
                'opening_balances'
            )
            WHEN 'system_admin' THEN p_table NOT IN ('users', 'farms')
            ELSE false
        END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_can_write(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_read(text, text) TO authenticated;

-- ============================================================
-- 21) sync_records_batch (مصحح)
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    DECLARE
        v_result jsonb := '[]'::jsonb;
        v_record jsonb;
        v_data jsonb;
        v_table_name text;
        v_record_id uuid;
        v_operation text;
        v_operation_id text;
        v_user_farm uuid;
        v_user_role text;
        v_existing_record jsonb;
        v_new_version bigint;
        v_affected int := 0;
        v_skipped int := 0;
        v_errors int := 0;
        v_col text;
        v_allowed_cols text[];
        v_cols text[];
        v_vals text[];
        v_set_parts text[];
        v_sql text;
        v_upd_count int;
    BEGIN
        PERFORM set_config('app.skip_sync_trigger', 'on', true);

        v_user_farm := public.current_user_farm_id();
        v_user_role := public.current_user_role();
        IF v_user_farm IS NULL THEN
            RAISE EXCEPTION 'لا يمكن تحديد المزرعة للمستخدم الحالي';
        END IF;

        FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
        LOOP
            v_table_name  := v_record->>'table_name';
            v_record_id   := (v_record->>'record_id')::uuid;
            v_operation   := v_record->>'operation';
            v_operation_id := v_record->>'operation_id';
            v_data        := v_record->>'data';

            PERFORM set_config('app.device_id', COALESCE(v_record->>'device_id', ''), true);
            PERFORM set_config('app.correlation_id', COALESCE(v_record->>'correlation_id', ''), true);

            IF v_data IS NULL THEN
                v_data := '{}'::jsonb;
            END IF;

            IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                DECLARE
                    v_prev_result jsonb;
                    v_mismatch int;
                BEGIN
                    SELECT result INTO v_prev_result
                    FROM idempotency_log
                    WHERE operation_id = v_operation_id
                      AND user_id = auth.uid()
                      AND farm_id = v_user_farm
                      AND table_name = v_table_name
                      AND record_id = v_record_id
                      AND operation = v_operation
                      AND status = 'done'
                    LIMIT 1;
                    IF v_prev_result IS NOT NULL THEN
                        v_result := v_result || v_prev_result;
                        CONTINUE;
                    END IF;

                    SELECT 1 INTO v_mismatch
                    FROM idempotency_log
                    WHERE operation_id = v_operation_id
                      AND NOT (
                          user_id = auth.uid()
                          AND farm_id = v_user_farm
                          AND table_name = v_table_name
                          AND record_id = v_record_id
                          AND operation = v_operation
                      )
                    LIMIT 1;
                    IF v_mismatch IS NOT NULL THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'status', 'error',
                            'message', 'operation_id مستخدم بالفعل لعملية أخرى'
                        );
                        CONTINUE;
                    END IF;
                END;
            END IF;

            IF v_table_name IN ('users', 'farms') THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', 'جدول ممنوع للمزامنة عبر RPC: ' || v_table_name
                );
                CONTINUE;
            END IF;

            IF NOT public.sync_can_write(v_user_role, v_table_name) THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', 'الدور الحالي لا يملك صلاحية المزامنة للجدول: ' || v_table_name
                );
                CONTINUE;
            END IF;

            IF v_operation IN ('update', 'delete') THEN
                EXECUTE format(
                    'SELECT to_jsonb(t) FROM %I t WHERE t.id = $1 AND t.farm_id = $2',
                    v_table_name
                ) INTO v_existing_record
                USING v_record_id, v_user_farm;

                IF v_existing_record IS NULL THEN
                    v_skipped := v_skipped + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'status', 'skipped',
                        'message', 'السجل غير موجود أو لا ينتمي للمزرعة'
                    );
                    CONTINUE;
                END IF;
            END IF;

            IF v_operation = 'update' AND v_existing_record IS NOT NULL THEN
                IF (v_record->>'previous_version') IS NOT NULL
                   AND (v_existing_record->>'version')::bigint > (v_record->>'previous_version')::bigint
                THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'status', 'conflict',
                        'server_version', (v_existing_record->>'version')::bigint,
                        'client_version', (v_record->>'previous_version')::bigint
                    );
                    CONTINUE;
                END IF;
            END IF;

            IF v_user_role = 'worker' AND v_operation IN ('update', 'delete') THEN
                IF (v_existing_record->>'worker_id') IS DISTINCT FROM auth.uid()::text THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'status', 'error',
                        'message', 'غير مصرح: لا يمكن تعديل/حذف سجل ليس من إنشائك'
                    );
                    CONTINUE;
                END IF;
            END IF;

            IF v_operation = 'delete' AND v_user_role <> 'manager' THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', 'غير مصرح: الحذف للمدير فقط'
                );
                CONTINUE;
            END IF;

            CASE v_table_name
                WHEN 'egg_production' THEN v_allowed_cols := ARRAY['flock_id','date','cartons','trays','loose_eggs','broken_eggs','dirty_eggs','tray_weight_kg','section_no','worker_id'];
                WHEN 'mortality' THEN v_allowed_cols := ARRAY['flock_id','date','count','reason','reason_other','notes','image_url','worker_id','section_no'];
                WHEN 'feed_consumption' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','bags_count','quantity_kg','worker_id','section_no'];
                WHEN 'feed_received' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','quantity','quantity_kg','feed_type','supplier','invoice_number','notes','price_per_kg','section_no','worker_id'];
                WHEN 'egg_dispatch' THEN v_allowed_cols := ARRAY['flock_id','date','customer_id','cartons','trays','tray_weight_kg','notes','payment_status','worker_id'];
                WHEN 'medications' THEN v_allowed_cols := ARRAY['flock_id','date','type','medicine_name','dosage','administration_route','treatment_days','withdrawal_days','notes','worker_id'];
                WHEN 'customers' THEN v_allowed_cols := ARRAY['name','phone','notes'];
                WHEN 'flocks' THEN v_allowed_cols := ARRAY['breed','start_date','initial_count','status','sections_count'];
                WHEN 'expenses' THEN v_allowed_cols := ARRAY['date','category','description','amount','currency','exchange_rate','carton_bundles'];
                WHEN 'inventory_items' THEN v_allowed_cols := ARRAY['name','unit','low_stock_threshold','notes'];
                WHEN 'inventory_transactions' THEN v_allowed_cols := ARRAY['item_id','date','type','quantity','note','user_id'];
                WHEN 'opening_balances' THEN v_allowed_cols := ARRAY['flock_id','eggs_produced','eggs_dispatched','feed_consumed_kg','initial_birds','mortality_count','total_payments','total_revenues','sections'];
                WHEN 'payments' THEN v_allowed_cols := ARRAY['dispatch_id','customer_id','date','price_per_carton','total_due','amount_paid','payment_method','currency','exchange_rate','due_date','notes','manager_id'];
                ELSE v_allowed_cols := ARRAY[]::text[];
            END CASE;

            IF v_user_role <> 'manager' THEN
                IF v_table_name = 'feed_received' THEN
                    v_allowed_cols := array_remove(v_allowed_cols, 'price_per_kg');
                ELSIF v_table_name = 'egg_dispatch' THEN
                    v_allowed_cols := array_remove(v_allowed_cols, 'payment_status');
                ELSIF v_table_name IN ('flocks', 'customers') THEN
                    v_allowed_cols := ARRAY[]::text[];
                END IF;
                v_allowed_cols := array_remove(v_allowed_cols, 'worker_id');
            END IF;

            IF v_operation IN ('insert', 'update') THEN
                IF v_table_name = 'egg_dispatch' AND (v_data ? 'customer_id') THEN
                    IF NOT EXISTS (SELECT 1 FROM customers WHERE id = (v_data->>'customer_id')::uuid AND farm_id = v_user_farm) THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id, 'status', 'error',
                            'message', 'customer_id لا ينتمي لمزرعتك'
                        );
                        CONTINUE;
                    END IF;
                END IF;

                IF v_table_name IN ('egg_production', 'mortality', 'feed_consumption', 'medications', 'opening_balances', 'feed_received', 'egg_dispatch')
                   AND (v_data ? 'flock_id') AND (v_data->>'flock_id') IS NOT NULL AND (v_data->>'flock_id') <> 'null' THEN
                    IF NOT EXISTS (SELECT 1 FROM flocks WHERE id = (v_data->>'flock_id')::uuid AND farm_id = v_user_farm) THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id, 'status', 'error',
                            'message', 'flock_id لا ينتمي لمزرعتك'
                        );
                        CONTINUE;
                    END IF;
                END IF;

                IF v_table_name = 'inventory_transactions' AND (v_data ? 'item_id') THEN
                    IF NOT EXISTS (SELECT 1 FROM inventory_items WHERE id = (v_data->>'item_id')::uuid AND farm_id = v_user_farm) THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id, 'status', 'error',
                            'message', 'item_id لا ينتمي لمزرعتك'
                        );
                        CONTINUE;
                    END IF;
                END IF;
            END IF;

            BEGIN
                IF v_operation = 'insert' THEN
                    -- منع الرفع المزدوج: إن وُجد السجل أصلاً بنفس id لنفس المزرعة
                    -- (أدخله مسار REST المباشر قبل الطابور) نعتبر المزامنة ناجحة.
                    EXECUTE format(
                        'SELECT to_jsonb(t) FROM %I t WHERE t.id = $1 AND t.farm_id = $2',
                        v_table_name
                    ) INTO v_existing_record
                    USING v_record_id, v_user_farm;

                    IF v_existing_record IS NOT NULL THEN
                        v_affected := v_affected + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'table_name', v_table_name,
                            'status', 'ok',
                            'new_version', COALESCE((v_existing_record->>'version')::bigint, 1)
                        );
                        CONTINUE;
                    END IF;

                    v_cols := ARRAY['id', 'farm_id', 'version'];
                    v_vals := ARRAY[
                        quote_literal(v_record_id::text),
                        quote_literal(v_user_farm::text),
                        '1'
                    ];
                    FOR v_col IN SELECT jsonb_object_keys(v_data)
                    LOOP
                        IF v_col = ANY(v_allowed_cols) AND NOT (v_col = 'worker_id' AND v_user_role <> 'manager') THEN
                            v_cols := array_append(v_cols, v_col);
                            v_vals := array_append(v_vals, quote(v_data->>v_col));
                        END IF;
                    END LOOP;
                    IF v_user_role <> 'manager' THEN
                        v_cols := array_append(v_cols, 'worker_id');
                        v_vals := array_append(v_vals, quote_literal(auth.uid()::text));
                    END IF;
                    v_sql := format(
                        'INSERT INTO %I (%s) VALUES (%s)',
                        v_table_name,
                        array_to_string(v_cols, ', '),
                        array_to_string(v_vals, ', ')
                    );
                    EXECUTE v_sql;
                    v_affected := v_affected + 1;

                ELSIF v_operation = 'update' THEN
                    v_new_version := (v_existing_record->>'version')::bigint + 1;
                    v_set_parts := ARRAY[format('version = %s', v_new_version::text), 'updated_at = NOW()'];
                    FOR v_col IN SELECT jsonb_object_keys(v_data)
                    LOOP
                        IF v_col = ANY(v_allowed_cols) THEN
                            v_set_parts := array_append(v_set_parts, format('%I = %s', v_col, quote(v_data->>v_col)));
                        END IF;
                    END LOOP;
                    v_sql := format(
                        'UPDATE %I SET %s WHERE id = %s AND farm_id = %s AND version = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote(v_record_id::text),
                        quote(v_user_farm::text),
                        quote((v_record->>'previous_version')::text)
                    );
                    EXECUTE v_sql;
                    GET DIAGNOSTICS v_upd_count = ROW_COUNT;
                    IF v_upd_count = 0 THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'status', 'conflict',
                            'message', 'تعارض في الإصدار أثناء التحديث'
                        );
                        CONTINUE;
                    END IF;
                    v_affected := v_affected + v_upd_count;

                ELSIF v_operation = 'delete' THEN
                    EXECUTE format(
                        'UPDATE %I SET deleted_at = NOW(), updated_at = NOW(), version = version + 1 WHERE id = $1 AND farm_id = $2 AND version = $3 AND deleted_at IS NULL',
                        v_table_name
                    ) USING v_record_id, v_user_farm, (v_record->>'previous_version')::bigint;
                    GET DIAGNOSTICS v_upd_count = ROW_COUNT;
                    IF v_upd_count = 0 THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'status', 'conflict',
                            'message', 'تعارض في الإصدار أثناء الحذف'
                        );
                        CONTINUE;
                    END IF;
                    v_affected := v_affected + v_upd_count;
                END IF;

                DECLARE
                    v_sc_record jsonb;
                    v_sc_payload jsonb;
                BEGIN
                    EXECUTE format(
                        'SELECT to_jsonb(t) FROM %I t WHERE t.id = $1 AND t.farm_id = $2',
                        v_table_name
                    ) INTO v_sc_record
                    USING v_record_id, v_user_farm;

                    IF v_sc_record IS NOT NULL THEN
                        v_sc_payload := v_sc_record - 'sync_status' - 'deleted_at';
                    ELSE
                        v_sc_payload := jsonb_build_object('id', v_record_id);
                    END IF;

                    INSERT INTO sync_changes (table_name, record_id, operation, farm_id, user_id, payload)
                    VALUES (v_table_name, v_record_id, upper(v_operation), v_user_farm, auth.uid(), v_sc_payload);
                END;

                DECLARE
                    v_detail jsonb;
                BEGIN
                    v_detail := jsonb_build_object(
                        'record_id', v_record_id,
                        'table_name', v_table_name,
                        'status', 'ok',
                        'new_version', COALESCE(v_new_version, 1)
                    );
                    v_result := v_result || v_detail;

                    IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                        INSERT INTO idempotency_log (operation_id, user_id, farm_id, table_name, record_id, operation, status, result)
                        VALUES (v_operation_id, auth.uid(), v_user_farm, v_table_name, v_record_id, v_operation, 'done', v_detail);
                    END IF;
                END;

            EXCEPTION WHEN OTHERS THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', SQLERRM
                );
            END;
        END LOOP;

        RETURN jsonb_build_object(
            'affected', v_affected,
            'skipped', v_skipped,
            'errors', v_errors,
            'details', v_result
        );
    END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb) TO authenticated;

-- ============================================================
-- 22) pull_remote_changes (مصحح)
-- ============================================================
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

GRANT EXECUTE ON FUNCTION public.pull_remote_changes(uuid, bigint) TO authenticated;

-- ============================================================
-- 23) cleanup_old_sync_changes
-- ============================================================
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

-- ============================================================
-- 24) compact_sync_changes
-- ============================================================
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

-- ============================================================
-- 25) refresh_sync_checkpoint
-- ============================================================
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

-- ============================================================
-- 26) auto_maintain_sync
-- ============================================================
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

-- ============================================================
-- 27) sync_conflicts
-- ============================================================
CREATE TABLE IF NOT EXISTS sync_conflicts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    farm_id UUID NOT NULL,
    local_data JSONB NOT NULL,
    remote_data JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'resolved', 'ignored')),
    resolution TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_status ON sync_conflicts(status);
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_farm ON sync_conflicts(farm_id);
ALTER TABLE sync_conflicts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS conflicts_manager ON sync_conflicts;
CREATE POLICY conflicts_manager ON sync_conflicts
    FOR ALL TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    )
    WITH CHECK (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    );

-- ============================================================
-- 28) RPCs لنظام الإدارة
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_sync_health(
    p_online_window_minutes int DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: هذه البيانات لـ system_admin فقط';
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'farm_id',       h.farm_id,
        'farm_name',     h.farm_name,
        'device_count',  h.device_count,
        'online_devices', h.online_devices,
        'offline_devices', (h.device_count - h.online_devices),
        'pending_conflicts', h.pending_conflicts,
        'last_sync',     h.last_sync,
        'latest_version', h.latest_version
    )), '[]'::jsonb) INTO v_result
    FROM (
        SELECT
            f.id   AS farm_id,
            f.name AS farm_name,
            COALESCE(d.device_count, 0)   AS device_count,
            COALESCE(d.online_devices, 0) AS online_devices,
            COALESCE(c.pending_conflicts, 0) AS pending_conflicts,
            COALESCE(d.last_sync, f.created_at) AS last_sync,
            COALESCE(cp.latest_version, 0) AS latest_version
        FROM public.farms f
        LEFT JOIN (
            SELECT
                dd.farm_id,
                COUNT(*)   AS device_count,
                COUNT(*) FILTER (WHERE dd.last_seen >= NOW() - (p_online_window_minutes * interval '1 minute'))
                           AS online_devices,
                MAX(dd.last_seen) AS last_sync
            FROM (
                SELECT
                    sc.farm_id,
                    sc.device_id,
                    MAX(sc.created_at) AS last_seen
                FROM public.sync_changes sc
                WHERE sc.device_id IS NOT NULL AND sc.device_id <> ''
                GROUP BY sc.farm_id, sc.device_id
            ) dd
            GROUP BY dd.farm_id
        ) d ON d.farm_id = f.id
        LEFT JOIN (
            SELECT farm_id, COUNT(*) AS pending_conflicts
            FROM public.sync_conflicts
            WHERE status = 'pending'
            GROUP BY farm_id
        ) c ON c.farm_id = f.id
        LEFT JOIN public.sync_checkpoint cp ON cp.farm_id = f.id
        ORDER BY f.created_at
    ) h;

    IF v_result IS NULL THEN v_result := '[]'::jsonb; END IF;
    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_sync_health(int) TO authenticated;

-- ============================================================
-- 29) admin_create_user
-- ============================================================
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

GRANT EXECUTE ON FUNCTION public.admin_create_user(text, text, text, text, text) TO authenticated;

-- ============================================================
-- 30) admin_update_user
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

GRANT EXECUTE ON FUNCTION public.admin_update_user(text, text, text, text, boolean) TO authenticated;

-- ============================================================
-- 31) admin_reset_pin
-- ============================================================
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

GRANT EXECUTE ON FUNCTION public.admin_reset_pin(text, text) TO authenticated;

-- ============================================================
-- 32) admin_delete_user
-- ============================================================
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

GRANT EXECUTE ON FUNCTION public.admin_delete_user(text) TO authenticated;

-- ============================================================
-- 33) bootstrap_create_farm_and_manager
-- ============================================================
CREATE OR REPLACE FUNCTION public.bootstrap_create_farm_and_manager(
    p_farm_name text,
    p_location text,
    p_manager_name text,
    p_phone text,
    p_pin text,
    p_provision_token text
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
    PERFORM pg_advisory_xact_lock(hashtext('madjana_bootstrap'));

    IF EXISTS (SELECT 1 FROM users LIMIT 1) THEN
        RAISE EXCEPTION 'يوجد مستخدمون بالفعل — هذه الدالة للتهيئة الأولى فقط';
    END IF;

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;

    INSERT INTO farms (name, location)
    VALUES (p_farm_name, NULLIF(p_location, ''))
    RETURNING id INTO v_farm_id;

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
            'role', 'system_admin',
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
    VALUES (
        v_auth_uuid, p_manager_name, p_phone, 'system_admin',
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

    RETURN jsonb_build_object(
        'user_id', v_auth_uuid,
        'farm_id', v_farm_id,
        'email', public.app_user_email(v_auth_uuid),
        'name', p_manager_name,
        'phone', p_phone
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.bootstrap_create_farm_and_manager(text, text, text, text, text, text) TO anon, authenticated;

-- ============================================================
-- 33b) has_system_admin — هل النظام مهيأ بوجود سوبر أدمن؟
-- ============================================================

CREATE OR REPLACE FUNCTION public.has_system_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM users
        WHERE role = 'system_admin' AND is_active = true
    );
$$;

GRANT EXECUTE ON FUNCTION public.has_system_admin() TO anon, authenticated;

-- ============================================================
-- 33c) create_first_admin — إنشاء أول سوبر أدمن من التطبيق
-- (بدون رمز تزويد خارجي؛ يُقرأ داخلياً، ومحجوب عندما يوجد مستخدمون)
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_first_admin(
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
    v_expected text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('madjana_bootstrap'));

    IF EXISTS (SELECT 1 FROM users LIMIT 1) THEN
        RAISE EXCEPTION 'يوجد مستخدمون بالفعل — هذه الدالة للتهيئة الأولى فقط';
    END IF;

    SELECT value INTO v_expected FROM app_settings WHERE key = 'secure.bootstrap_token';

    RETURN public.bootstrap_create_farm_and_manager(
        p_farm_name, p_location, p_manager_name, p_phone, p_pin, v_expected
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_first_admin(text, text, text, text, text) TO anon, authenticated;

-- ============================================================
-- 34) create_farm_with_manager
-- ============================================================
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

GRANT EXECUTE ON FUNCTION public.create_farm_with_manager(text, text, text, text, text) TO authenticated;

-- ============================================================
-- 34b) admin_create_farm: إنشاء مدجنة فقط (بدون مدير)
-- ============================================================
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

GRANT EXECUTE ON FUNCTION public.admin_create_farm(text, text) TO authenticated;

-- ============================================================
-- 34c) admin_assign_user_to_farm: إضافة ربط مستخدم بمدجنة (بدون تحويل)
-- ============================================================
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

    -- إضافة علاقة الربط (المستخدم قد يكون مرتبطاً بعدة مداجن)
    INSERT INTO public.user_farms (user_id, farm_id)
    VALUES (p_uid::uuid, v_farm_uuid)
    ON CONFLICT (user_id, farm_id) DO NOTHING;

    -- إذا لم تكن للمستخدم مدجنة نشطة بعد، اجعل هذه المدجنة هي النشطة
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

GRANT EXECUTE ON FUNCTION public.admin_assign_user_to_farm(text, text) TO authenticated;

-- ============================================================
-- 34d) admin_unassign_user_from_farm: فكّ ربط مستخدم بمدجنة محددة
-- ============================================================
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

GRANT EXECUTE ON FUNCTION public.admin_unassign_user_from_farm(text, text) TO authenticated;

-- ============================================================
-- 34e) admin_select_all_users_with_farms: كل المستخدمين مع مداجنهم
-- ============================================================
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

GRANT EXECUTE ON FUNCTION public.admin_select_all_users_with_farms() TO authenticated;

-- ============================================================
-- 35) admin_select_all_users
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_select_all_users()
RETURNS SETOF users
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.*
    FROM public.users u
    WHERE public.is_system_admin()
    ORDER BY u.created_at;
$$;

GRANT EXECUTE ON FUNCTION public.admin_select_all_users() TO authenticated;

-- ============================================================
-- 36) admin_select_all_farms
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_select_all_farms()
RETURNS SETOF farms
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT f.*
    FROM public.farms f
    WHERE public.is_system_admin()
    ORDER BY f.created_at;
$$;

GRANT EXECUTE ON FUNCTION public.admin_select_all_farms() TO authenticated;

-- ============================================================
-- 37) update_flock_count_on_mortality
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_flock_count_on_mortality()
RETURNS TRIGGER AS $$
DECLARE
    v_affected INTEGER;
    v_delta INTEGER;
    v_target_flock UUID;
BEGIN
    v_target_flock := COALESCE(NEW.flock_id, OLD.flock_id);
    IF v_target_flock IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' THEN
        UPDATE flocks
        SET current_count = current_count - NEW.count, updated_at = NOW()
        WHERE id = NEW.flock_id
          AND current_count >= NEW.count;

        GET DIAGNOSTICS v_affected = ROW_COUNT;
        IF v_affected = 0 THEN
            RAISE EXCEPTION 'عدد النفوق (%) يتجاوز العدد الحالي في القطيع', NEW.count;
        END IF;

    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.flock_id IS DISTINCT FROM OLD.flock_id THEN
            RAISE EXCEPTION 'لا يمكن تغيير القطيع بعد إنشاء سجل النفوق';
        END IF;

        IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            UPDATE flocks
            SET current_count = current_count + OLD.count, updated_at = NOW()
            WHERE id = OLD.flock_id;
        ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
            UPDATE flocks
            SET current_count = current_count - NEW.count, updated_at = NOW()
            WHERE id = NEW.flock_id
              AND current_count >= NEW.count;

            GET DIAGNOSTICS v_affected = ROW_COUNT;
            IF v_affected = 0 THEN
                RAISE EXCEPTION 'العودة من الحذف: العدد المطلوب (%) يتجاوز الحالي', NEW.count;
            END IF;
        ELSE
            v_delta := NEW.count - OLD.count;

            IF v_delta > 0 THEN
                UPDATE flocks
                SET current_count = current_count - v_delta, updated_at = NOW()
                WHERE id = NEW.flock_id
                  AND current_count >= v_delta;

                GET DIAGNOSTICS v_affected = ROW_COUNT;
                IF v_affected = 0 THEN
                    RAISE EXCEPTION 'التعديل سيؤدي لعدد سالب (الفرق: %)', v_delta;
                END IF;
            ELSIF v_delta < 0 THEN
                UPDATE flocks
                SET current_count = current_count + ABS(v_delta), updated_at = NOW()
                WHERE id = NEW.flock_id;
            END IF;
        END IF;

    ELSIF TG_OP = 'DELETE' THEN
        UPDATE flocks
        SET current_count = current_count + OLD.count, updated_at = NOW()
        WHERE id = OLD.flock_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_flock_count ON mortality;
CREATE TRIGGER trg_update_flock_count
    AFTER INSERT OR UPDATE OR DELETE ON mortality
    FOR EACH ROW EXECUTE FUNCTION public.update_flock_count_on_mortality();

-- ============================================================
-- 38) protect_inventory_quantity
-- ============================================================
CREATE OR REPLACE FUNCTION public.protect_inventory_quantity()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
        RAISE EXCEPTION 'لا يمكن تعديل الرصيد مباشرة. استخدم معاملات المخزون';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_protect_inventory_quantity ON inventory_items;
CREATE TRIGGER trg_protect_inventory_quantity
    BEFORE UPDATE ON inventory_items
    FOR EACH ROW EXECUTE FUNCTION public.protect_inventory_quantity();

-- ============================================================
-- 39) ensure_operational_policies
-- ============================================================
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
        -- الزبائن: الفلاحون يظهرون في كل المداجن، وعمال المزرعة يرونها
        -- إضافة إلى زبائن مدجنتهم فقط.
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

SELECT public.ensure_operational_policies('flocks');
SELECT public.ensure_operational_policies('customers');
SELECT public.ensure_operational_policies('egg_production');
SELECT public.ensure_operational_policies('mortality');
SELECT public.ensure_operational_policies('feed_consumption');
SELECT public.ensure_operational_policies('feed_received');
SELECT public.ensure_operational_policies('egg_dispatch');
SELECT public.ensure_operational_policies('medications');

-- ============================================================
-- 40) ensure_manager_policies
-- ============================================================
CREATE OR REPLACE FUNCTION public.ensure_manager_policies(p_table name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    EXECUTE format('DROP POLICY IF EXISTS mgr_all ON %I', p_table);
    EXECUTE format('CREATE POLICY mgr_all ON %I FOR ALL TO authenticated USING (is_system_admin() OR current_user_role() = ''manager'') WITH CHECK (is_system_admin() OR current_user_role() = ''manager'')', p_table);
END;
$$;

SELECT public.ensure_manager_policies('payments');
SELECT public.ensure_manager_policies('expenses');
SELECT public.ensure_manager_policies('opening_balances');
SELECT public.ensure_manager_policies('inventory_items');

DROP POLICY IF EXISTS mgr_all ON audit_log;

DROP POLICY IF EXISTS mgr_tx ON inventory_transactions;
CREATE POLICY mgr_tx ON inventory_transactions
    FOR ALL TO authenticated
    USING (
        is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND item_id IN (SELECT i.id FROM inventory_items i WHERE i.farm_id = current_user_farm_id())
        )
    )
    WITH CHECK (
        is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND item_id IN (SELECT i.id FROM inventory_items i WHERE i.farm_id = current_user_farm_id())
        )
    );

-- ============================================================
-- 41) سياسات extra
-- ============================================================
DROP POLICY IF EXISTS catalog_select ON medicines_catalog;
CREATE POLICY catalog_select ON medicines_catalog
    FOR SELECT TO authenticated
    USING (true);

DROP POLICY IF EXISTS catalog_manager ON medicines_catalog;
CREATE POLICY catalog_manager ON medicines_catalog
    FOR ALL TO authenticated
    USING (is_system_admin() OR current_user_role() = 'manager')
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager');

DROP POLICY IF EXISTS app_settings_manager_select ON app_settings;
CREATE POLICY app_settings_manager_select ON app_settings
    FOR SELECT TO authenticated
    USING (is_system_admin() OR current_user_role() = 'manager');

DROP POLICY IF EXISTS app_settings_manager_write ON app_settings;
CREATE POLICY app_settings_manager_write ON app_settings
    FOR INSERT TO authenticated
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager');

DROP POLICY IF EXISTS app_settings_manager_update ON app_settings;
CREATE POLICY app_settings_manager_update ON app_settings
    FOR UPDATE TO authenticated
    USING (is_system_admin() OR current_user_role() = 'manager')
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager');

DROP POLICY IF EXISTS notif_read ON app_notifications;
CREATE POLICY notif_read ON app_notifications
    FOR SELECT TO authenticated
    USING (is_system_admin() OR farm_id = current_user_farm_id());

DROP POLICY IF EXISTS notif_manager ON app_notifications;
CREATE POLICY notif_manager ON app_notifications
    FOR ALL TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    )
    WITH CHECK (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    );

DROP POLICY IF EXISTS dreq_select ON dispatch_requests;
CREATE POLICY dreq_select ON dispatch_requests
    FOR SELECT TO authenticated
    USING (is_system_admin() OR farm_id = current_user_farm_id());

DROP POLICY IF EXISTS dreq_insert ON dispatch_requests;
CREATE POLICY dreq_insert ON dispatch_requests
    FOR INSERT TO authenticated
    WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id());

DROP POLICY IF EXISTS dreq_manager ON dispatch_requests;
CREATE POLICY dreq_manager ON dispatch_requests
    FOR UPDATE TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    )
    WITH CHECK (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    );

DROP POLICY IF EXISTS dreq_manager_delete ON dispatch_requests;
CREATE POLICY dreq_manager_delete ON dispatch_requests
    FOR DELETE TO authenticated
    USING (
        is_system_admin()
        OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id())
    );

DROP POLICY IF EXISTS sync_changes_select ON sync_changes;
CREATE POLICY sync_changes_select ON sync_changes
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR farm_id = current_user_farm_id()
    );

-- ============================================================
-- 42) farms و users RLS
-- ============================================================
DROP POLICY IF EXISTS farms_select_own ON farms;
CREATE POLICY farms_select_own ON farms
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR id = current_user_farm_id()
    );

DROP POLICY IF EXISTS farms_insert_manager ON farms;
CREATE POLICY farms_insert_manager ON farms
    FOR INSERT TO authenticated
    WITH CHECK (is_system_admin());

DROP POLICY IF EXISTS farms_update_manager ON farms;
CREATE POLICY farms_update_manager ON farms
    FOR UPDATE TO authenticated
    USING (is_system_admin() OR current_user_role() = 'manager')
    WITH CHECK (is_system_admin() OR current_user_role() = 'manager');

DROP POLICY IF EXISTS farms_delete_manager ON farms;
CREATE POLICY farms_delete_manager ON farms
    FOR DELETE TO authenticated
    USING (is_system_admin());

DROP POLICY IF EXISTS users_select_self ON users;
CREATE POLICY users_select_self ON users
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

DROP POLICY IF EXISTS users_update_self ON users;
CREATE POLICY users_update_self ON users
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
-- 42b) user_farms RLS: المستخدم يرى روابطه فقط، والإدارة للمدير العام
-- ============================================================
ALTER TABLE user_farms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_farms_select_own ON user_farms;
CREATE POLICY user_farms_select_own ON user_farms
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

DROP POLICY IF EXISTS user_farms_admin_write ON user_farms;
CREATE POLICY user_farms_admin_write ON user_farms
    FOR INSERT TO authenticated
    WITH CHECK (is_system_admin());

DROP POLICY IF EXISTS user_farms_admin_delete ON user_farms;
CREATE POLICY user_farms_admin_delete ON user_farms
    FOR DELETE TO authenticated
    USING (is_system_admin());

-- ============================================================
-- 43) إضافة version للجداول الناقصة
-- ============================================================
ALTER TABLE inventory_items
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;

ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- ============================================================
-- 44) تحديث قيد الدور
-- ============================================================
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
    CHECK (role IN ('worker', 'manager', 'system_admin'));

-- ============================================================
-- 45) Grant permissions
-- ============================================================
GRANT EXECUTE ON FUNCTION public.is_system_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_farm_with_manager(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_select_all_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_select_all_farms() TO authenticated;
GRANT EXECUTE ON FUNCTION public.bootstrap_create_farm_and_manager(text, text, text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.app_password_from_pin(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.app_user_email(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farm_id() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farm_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farms_with_names() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_active_farm(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_select_all_users_with_farms() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unassign_user_from_farm(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_old_sync_changes(int, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.compact_sync_changes(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
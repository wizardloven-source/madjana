-- ============================================================
-- UNIFIED MIGRATION: Madjana Database Schema
-- Generated: 2026-09-06 15:27
-- Replaces: 20250101000000_initial_schema.sql + all subsequent migrations
-- Tables: 26 | Functions: merged to latest | Policies: merged to latest
-- ============================================================

BEGIN;

-- ============================================================
-- SECTION 1: TABLES (from initial schema, cleaned)
-- ============================================================
-- ============================================================
-- Madjana - ظ†ط¸ط§ظ… ط¥ط¯ط§ط±ط© ط§ظ„ظ…ط¯ط¬ظ†ط©
-- ظ…ط®ط·ط· ظ‚ط§ط¹ط¯ط© ط§ظ„ط¨ظٹط§ظ†ط§طھ ط§ظ„ظ…ظˆط­ط¯ - ط§ظ„ظ…ط±ط­ظ„ط© 1 (ط§ظ„ط£ظ…ط§ظ† + طھظƒط§ظ…ظ„ ط§ظ„ط¨ظٹط§ظ†ط§طھ)
--
-- ط¥ط¶ط§ظپط§طھ ط§ظ„ظ…ط±ط­ظ„ط© 1:
--   - version BIGINT ظ„ظƒظ„ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹط© (version-based conflict detection)
--   - deleted_at ظ„ظ„ظ€ Soft Delete
--   - sync_records_batch ظ…ط¹ whitelist + auth.uid()
--   - trigger ط§ظ„ظ†ظپظˆظ‚ ظ…ط¹ UPDATE/DELETE + ظ…ظ†ط¹ ط§ظ„ط³ط§ظ„ط¨
--   - validate_flock_farm trigger (cross-farm protection)
--   - mortality.section_no / feed_consumption.section_no / feed_received.section_no
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- 0) طھظ†ط¸ظٹظپ ط£ظٹ ط¨ظ‚ط§ظٹط§
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
    expenses, users, farms, sync_changes, sync_checkpoint CASCADE;

DROP FUNCTION IF EXISTS public.find_user_by_phone(text);
DROP FUNCTION IF EXISTS public.current_user_role(), public.current_user_farm_id();
DROP FUNCTION IF EXISTS public.current_role_safe(), public.current_farm_safe();
DROP FUNCTION IF EXISTS public.app_user_email(uuid), public.app_password_from_pin(text);
DROP FUNCTION IF EXISTS public.assert_current_is_manager_of(uuid);
DROP FUNCTION IF EXISTS public.bootstrap_create_farm_and_manager(text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.admin_create_user(text, text, text, text, text);
DROP FUNCTION IF EXISTS public.admin_update_user(text, text, text, text);
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
-- 1) ط§ظ„طھط³ظ„ط³ظ„ ط§ظ„ط¹ط§ظ… ظ„ظ„ظ…ط²ط§ظ…ظ†ط©
-- ============================================================
CREATE SEQUENCE global_sync_version START WITH 1 INCREMENT BY 1;

-- ============================================================
-- 2) ط§ظ„ظ…ط²ط§ط±ط¹ ظˆط§ظ„ظ…ط³طھط®ط¯ظ…ظˆظ†
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

-- ============================================================
-- 3) ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹط©
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
    version    BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);
CREATE INDEX idx_customers_farm ON customers(farm_id);

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
-- P0/9: ظپظ‡ط±ط³ ظپط±ظٹط¯ ط¨ظˆط­ط¯ط§طھ ط§ظ„ط£ظ‚ط³ط§ظ… â€” ظ…ط²ط±ط¹ط© ط§ظ„ط£ظ‚ط³ط§ظ… طھط³طھط·ظٹط¹ طھط³ط¬ظٹظ„ ط¥ظ†طھط§ط¬ ظ„ظƒظ„ ظ‚ط³ظ…
-- ظپظٹ ظ†ظپط³ ط§ظ„ظٹظˆظ…ط› ط¨ط¯ظˆظ† ط£ظ‚ط³ط§ظ… (section_no = NULL â†’ 0) ظٹط¨ظ‚ظ‰ ط³ط¬ظ„ ظˆط§ط­ط¯ ظپظ‚ط· ظ„ظ„ظٹظˆظ….
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
    -- (13) طھظˆط­ظٹط¯ version/deleted_at ظ„ظƒظ„ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„ظ…طھط²ط§ظ…ظ†ط© (OCC + soft delete)
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
    -- (13) version ظ„طھظپط¹ظٹظ„ OCC ظپظٹ sync_records_batch
    version      BIGINT NOT NULL DEFAULT 1,
    deleted_at   TIMESTAMPTZ,
    -- P0/10: ط§طھط³ط§ظ‚ ظˆط¶ط¹ ط§ظ„ط¥ط¯ط®ط§ظ„ â€” ط¨ظˆط¶ط¹ ط§ظ„ط£ظƒظٹط§ط³ ظٹط¬ط¨ ط£ظ† ظٹظƒظˆظ† ط§ظ„ط¹ط¯ط¯ > 0
    -- ظˆط£ظ† طھظƒظˆظ† ط§ظ„ظƒظ…ظٹط§طھ ظ…ط·ط§ط¨ظ‚ط© (ظƒظٹط³ = 24 ظƒط؛طŒ ظˆظ‡ظˆ ط«ط§ط¨طھ AppConstants.kgPerBag).
    -- ط¨ظˆط¶ط¹ ط§ظ„ظƒظٹظ„ظˆط؛ط±ط§ظ… ظ„ط§ ظ‚ظٹط¯ ط¥ط¶ط§ظپظٹ ظ„ط£ظ† ط§ظ„ظƒظ…ظٹط© طھظڈط¯ط®ظ„ ظ…ط¨ط§ط´ط±ط©.
    CONSTRAINT check_feed_consumption_mode CHECK (
        (entry_mode = 'kg') OR
        (entry_mode = 'bags' AND bags_count > 0 AND quantity_kg = bags_count * 24)
    )
);

CREATE TABLE feed_received (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id        UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
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
    -- P0: worker_id ط¥ظ„ط²ط§ظ…ظٹ (ظ„ط§ UUID ظˆظ‡ظ…ظٹ) â€” ط§ظ„ظ…ط§ظ„ظƒ ط§ظ„ط­ظ‚ظٹظ‚ظٹ ظ„ظ„ط³ط¬ظ„
    worker_id      UUID NOT NULL REFERENCES users(id),
    sync_status  TEXT DEFAULT 'synced'
                     CHECK (sync_status IN ('pending', 'synced', 'failed', 'processing', 'conflict')),
    version      BIGINT NOT NULL DEFAULT 1,
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_at   TIMESTAMPTZ DEFAULT NOW(),
    deleted_at   TIMESTAMPTZ,
    -- P0/11: ط§طھط³ط§ظ‚ ظˆط¶ط¹ ط§ظ„ط¥ط¯ط®ط§ظ„ ظپظٹ ط§ظ„ط§ط³طھظ„ط§ظ… â€” quantity = ظˆط­ط¯ط© ط§ظ„ظˆط¶ط¹طŒ
    -- ظˆ quantity_kg ظٹظڈط­ط³ط¨ ظ…ظ†ظ‡ط§ (ظƒظٹط³=24طŒ ط·ظ†=1000). ظ†ظپط³ ط«ظˆط§ط¨طھ ط§ظ„طھط·ط¨ظٹظ‚.
    CONSTRAINT check_feed_received_mode CHECK (
        (quantity > 0) AND (
            (entry_mode = 'bags' AND quantity_kg = quantity * 24) OR
            (entry_mode = 'kg'   AND quantity_kg = quantity)     OR
            (entry_mode = 'ton'  AND quantity_kg = quantity * 1000)
        )
    )
);

CREATE TABLE egg_dispatch (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    farm_id         UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
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
        'transport', 'feed', 'medicine', 'other'
    )),
    description TEXT,
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
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

-- ============================================================
-- ط¥ط¹ط¯ط§ط¯ط§طھ ط§ظ„ظ†ط¸ط§ظ… (ظ…ط·ظ„ظˆط¨ط© ط¨ظˆط§ط³ط·ط© bootstrap_create_farm_and_manager)
-- ============================================================
-- P0: ظƒط§ظ† bootstrap ظٹط´ظٹط± ط¥ظ„ظ‰ app_settings ط¯ظˆظ† ط¥ظ†ط´ط§ط¦ظ‡طŒ ظپظƒط§ظ† ظٹظپط´ظ„
-- ظˆظ‚طھ ط§ظ„طھط´ط؛ظٹظ„. ط§ظ„ط¢ظ† ط§ظ„ط¬ط¯ظˆظ„ ظ…ظˆط¬ظˆط¯ ظˆظٹظڈط²ط±ط¹ ظپظٹظ‡ طھظˆظƒظ† طھظ‡ظٹط¦ط© ط¹ط´ظˆط§ط¦ظٹ ظ‚ظˆظٹ
-- ظپظٹ ظƒظ„ ظ‚ط§ط¹ط¯ط© ط¬ط¯ظٹط¯ط© (128-bit ط¹ط¨ط± md5(gen_random_uuid())). ظٹط¬ط¨ ط¹ظ„ظ‰
-- ط§ظ„ظ…ط³ط¤ظˆظ„ ط§ط³طھط¨ط¯ط§ظ„ ط§ظ„ظ‚ظٹظ…ط© ط¨ظ€ SECRET ظ‚ظˆظٹ ظ‚ط¨ظ„ ط§ظ„ظ†ط´ط± ط§ظ„ظپط¹ظ„ظٹطŒ ط£ظˆ ط§ط³طھط®ط¯ط§ظ…
-- ط§ظ„ظ‚ظٹظ…ط© ط§ظ„ظ…ظˆظ„ط¯ط© طھظ„ظ‚ط§ط¦ظٹط§ظ‹ ط¹ظ†ط¯ طھظ‡ظٹط¦ط© ط£ظˆظ„ ظ…ط²ط±ط¹ط©.
CREATE TABLE app_settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);
-- طھظˆظƒظ† طھظ‡ظٹط¦ط© ط¹ط´ظˆط§ط¦ظٹ (ظ…ط®طھظ„ظپ ظ„ظƒظ„ ظ‚ط§ط¹ط¯ط©) â€” ظٹظڈظ‚ط±ط£ ظ…ط±ط© ظˆط§ط­ط¯ط© ط£ط«ظ†ط§ط، bootstrap
INSERT INTO app_settings (key, value, updated_at)
SELECT 'secure.bootstrap_token',
       md5(gen_random_uuid()::text || clock_timestamp()::text),
       NOW()
WHERE NOT EXISTS (SELECT 1 FROM app_settings WHERE key = 'secure.bootstrap_token');

-- (21) ط¥ط¹ط¯ط§ط¯ط§طھ ط§ظ„ط§ط­طھظپط§ط¸ ط¨ط§ظ„ظ…ط²ط§ظ…ظ†ط© â€” ظ‚ط§ط¨ظ„ط© ظ„ظ„ط¶ط¨ط· ط¯ظˆظ† طھط¹ط¯ظٹظ„ ط§ظ„ظƒظˆط¯.
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

-- Checkpoint ظ„ظƒظ„ ظ…ط²ط±ط¹ط©: ظٹظ„ط®ظ‘طµ ط­ط§ظ„ط© ط¬ط¯ظˆظ„ ط§ظ„ظ…ط²ط§ظ…ظ†ط© ظ„طھط¬ظ†ظ‘ط¨ ظپط­ظˆطµ MIN/MAX
-- ط§ظ„ظ…ظƒظ„ظپط© ظپظٹ ظƒظ„ ط³ط­ط¨طŒ ظˆظ„ط¥ط¯ط§ط±ط© watermark (purged_below) ط§ظ„ط®ط§طµ ط¨ط§ظ„ط§ط­طھظپط§ط¸/ط§ظ„ط¶ط؛ط·.
--   latest_version  = ط£ط­ط¯ط« server_version ظ…ظڈط³ط¬ظژظ‘ظ„ ظ„ظ„ظ…ط²ط±ط¹ط©.
--   purged_below    = ط£ظ‚ظ„ server_version ظ…ط­طھط¬ط²ط§ظ‹ ط¨ط¹ط¯ ط§ظ„طھظ†ط¸ظٹظپ/ط§ظ„ط¶ط؛ط·ط›
--                     ط£ظٹ ط¬ظ‡ط§ط² ظٹطھظ‚ط¯ظ… ط¥ظ„ظ‰ ظ…ط§ ط¯ظˆظ†ظ‡ ظٹطھط·ظ„ط¨ ط¥ط¹ط§ط¯ط© ظ…ط²ط§ظ…ظ†ط© ظƒط§ظ…ظ„ط©.
CREATE TABLE sync_checkpoint (
    farm_id           UUID PRIMARY KEY REFERENCES farms(id) ON DELETE CASCADE,
    latest_version    BIGINT NOT NULL DEFAULT 0,
    purged_below      BIGINT NOT NULL DEFAULT 0,
    last_maintenance  TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_sync_checkpoint_latest ON sync_checkpoint(latest_version);

-- ============================================================
-- 4) ط¨ط°ط± ظƒطھط§ظ„ظˆط¬ ط§ظ„ط£ط¯ظˆظٹط©
-- ============================================================
INSERT INTO medicines_catalog (name, type, withdrawal_days, notes) VALUES
    ('ط­ط§ظ…ط¶ ط§ظ„ط³طھط±ظٹظƒ (Citric Acid)', 'drug', 0, 'ظ…ط­ظپط² ط´ط±ط¨'),
    ('ط£ظ…ظˆظƒط³ظٹط³ظٹظ„ظٹظ† (Amoxicillin)', 'drug', 5, 'ظ…ط¶ط§ط¯ ط­ظٹط¨ظٹ ظˆط§ط³ط¹ ط§ظ„ط·ظٹظپ'),
    ('ط¥ظ†ط±ظˆظپظ„ظˆظƒط³ط§ط³ظٹظ† (Enrofloxacin)', 'drug', 7, 'ظ…ط¶ط§ط¯ ط­ظٹط¨ظٹ ظ„ظ„ط¬ظ‡ط§ط² ط§ظ„طھظ†ظپط³ظٹ'),
    ('ط¯ظˆظƒط³ظٹط³ظٹظƒظ„ظٹظ† (Doxycycline)', 'drug', 5, 'ظ…ط¶ط§ط¯ ط­ظٹط¨ظٹ'),
    ('ظ„ظ‚ط§ط­ ظ†ظٹظˆظƒط§ط³ظ„ (Newcastle)', 'vaccine', 0, 'طھط­طµظٹظ†'),
    ('ظ„ظ‚ط§ط­ ط¬ط§ظ…ط¨ظˆط±ظˆ (Gumboro)', 'vaccine', 0, 'طھط­طµظٹظ†'),
    ('ظپظٹطھط§ظ…ظٹظ† A,D3,E', 'vitamin', 0, 'ظپظٹطھط§ظ…ظٹظ†ط§طھ ط°ط§ط¦ط¨ط© ظپظٹ ط§ظ„ط¯ظ‡ظˆظ†'),
    ('ظپظٹطھط§ظ…ظٹظ† C', 'vitamin', 0, 'ط¯ط¹ظ… ط§ظ„ظ…ظ†ط§ط¹ط©'),
    ('ظ…ظˆظ„طھظٹ ظپظٹطھط§ظ…ظٹظ† (Multivitamin)', 'vitamin', 0, 'ظپظٹطھط§ظ…ظٹظ†ط§طھ ظ…طھظƒط§ظ…ظ„ط©');

-- ============================================================
-- 5) ط§ظ„ط¯ظˆط§ظ„
-- ============================================================

-- طھط­ط¯ظٹط« updated_at طھظ„ظ‚ط§ط¦ظٹط§ظ‹
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS handle_new_user ON auth.users;
CREATE TRIGGER handle_new_user
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ط¯ظˆط§ظ„ ط§ظ„ظ‡ظˆظٹط© (STABLE + invoker)
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

-- طھط­ظˆظٹظ„ PIN ط¥ظ„ظ‰ "ظƒظ„ظ…ط© ظ…ط±ظˆط±" طھظڈط³ظ„ظ‘ظ… ظ„ظ€ GoTrue ظ„طھط­ظ‚ظ‚ ظ…ظ†ظ‡ط§ ط¨ظ€ bcrypt
-- طھظڈط¶ط§ظپ "pepper" (ط³ط§ظ„ظپ طھط·ط¨ظٹظ‚ظٹ) ظ‚ط¨ظ„ ط§ظ„ظ€PIN ظ„ظ…ظ†ط¹ ظ‡ط¬ظˆظ… ط§ظ„ظ‚ظˆط© ط§ظ„ط¹ظ…ظٹط§ط، ط¯ظˆظ† ط§طھطµط§ظ„
-- ط¹ظ„ظ‰ ط±ظ‚ظ… PIN ظ…ظ† 4 ط®ط§ظ†ط§طھ. ظٹط¬ط¨ ط£ظ† ظٹط·ط§ط¨ظ‚ ط¥ط¹ط¯ط§ط¯ Flutter ظپظٹ supabase_auth_datasource.
CREATE OR REPLACE FUNCTION public.app_password_from_pin(p_pin text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT 'madjana$' || p_pin;
$$;

-- ط¨ط±ظٹط¯ ط§طµط·ظ†ط§ط¹ظٹ ظ„ظƒظ„ ط­ط³ط§ط¨ (ظٹط¬ط¨ ط£ظ† ظٹط·ط§ط¨ظ‚ _authEmail ظپظٹ Flutter)
CREATE OR REPLACE FUNCTION public.app_user_email(p_uid uuid)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_uid::text || '@users.madjana.local';
$$;

-- ============================================================
-- 21) ط§ظ„ط­ظ…ط§ظٹط© ظ…ظ† طھط¹ط¯ط§ط¯ ط£ط±ظ‚ط§ظ… ط§ظ„ظ‡ط§طھظپ (phone enumeration)
-- ============================================================

-- ط¬ط¯ظˆظ„ ط­ط¯ظ‘ ظ…ط¹ط¯ظ„ ط§ظ„ط§ط³طھط¹ظ„ط§ظ…ط§طھ: طھط­ط¯ظ‘ ظ…ظ† ط³ط±ط¹ط© ظ…ط³ط­ ط§ظ„ط£ط±ظ‚ط§ظ… (brute force / enumeration)
-- ظƒظ„ ظ…ظپطھط§ط­ ظٹظ…ط«ظ„ "ظ†ط§ظپط°ط© ط²ظ…ظ†ظٹط©" ظ…ظ†ط³ط¯ظ„ط© (ظ…ط«ظ„: ظƒظ„ ط±ظ‚ظ… ط¹ظ„ظ‰ ط­ط¯ط© ظپظٹ ط¯ظ‚ظٹظ‚ط©)
CREATE TABLE IF NOT EXISTS login_throttle (
    key         TEXT PRIMARY KEY,
    hits        INTEGER NOT NULL DEFAULT 0,
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_hit    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ط§ظ„ط­ط¯ظ‘ ط§ظ„ط¥ط¬ظ…ط§ظ„ظٹ ظ„ظ„ط§ط³طھط¹ظ„ط§ظ…ط§طھ ظپظٹ ط§ظ„ظ†ط§ظپط°ط© ط§ظ„ظˆط§ط­ط¯ط© ظˆظ…ط¯ط© ط§ظ„ظ†ط§ظپط°ط©
CREATE OR REPLACE FUNCTION public.throttle_max_hits()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 10; $$;

CREATE OR REPLACE FUNCTION public.throttle_window_seconds()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 60; $$;

-- ظپط§ط­طµ ط§ظ„ط­ط¯ظ‘ ط§ظ„ط¹ط§ظ… (ط¨ظ„ط§ ظ…ظپطھط§ط­ ط®ط§طµ): ظٹط¨ط·ط¦ طھط¹ط¯ط§ط¯ ط§ظ„ط£ط±ظ‚ط§ظ… ط¹ط¨ط± ط§ط³طھط¹ظ„ط§ظ…ط§طھ ظ…طھط¹ط§ظ‚ط¨ط©
-- طھظڈط¯ظ…ط¬ ط§ظ„ط§ط³طھط¯ط¹ط§ط،ط§طھ ظپظٹ ظ†ط§ظپط°ط© ظ…ط´طھط±ظƒط© ط­طھظ‰ ظ„ط§ ظٹط³طھط·ظٹط¹ ط§ظ„ظ…ظ‡ط§ط¬ظ… ط§ظ„ظ…ط³ط­ ط§ظ„ط³ط±ظٹط¹.
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
    -- ط¥ط¯ط±ط§ط¬/ط¥ط¹ط§ط¯ط© طھط¹ظٹظٹظ† ط§ظ„ظ†ط§ظپط°ط© ط¹ظ†ط¯ ط§ظ„ط­ط§ط¬ط©
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

-- ط§ظ„ط¨ط­ط« ط¨ط§ظ„ظ‡ط§طھظپ â€” ظٹط³طھط®ط¯ظ…ظ‡ طھط·ط¨ظٹظ‚ طھط³ط¬ظٹظ„ ط§ظ„ط¯ط®ظˆظ„ ظ„ط±ط¨ط· ط±ظ‚ظ… ط§ظ„ظ‡ط§طھظپ ط¨ظ€ auth uid.
-- P0: ظ„ط§ ظٹط¹ظˆط¯ ط¨ط§ظ„ط£ط¯ظˆط§ط±/ط§ظ„ظ…ط²ط§ط±ط¹ ظ„طھظپط§ط¯ظٹ طھط³ط±ظٹط¨ ظ…ط¹ظ„ظˆظ…ط§طھط› ظˆظٹظ…ظ†ط¹ ط§ظ„ظˆطµظˆظ„ ط§ظ„ط¹ط§ظ… (anon).
-- ============================================================
-- 22) ط­ظ…ط§ظٹط© طھط³ط¬ظٹظ„ ط§ظ„ط¯ط®ظˆظ„: ظ‚ظپظ„ ط§ظ„ط­ط³ط§ط¨ + ط­ط¯ظ‘ ظ…ط¹ط¯ظ‘ظ„ ط§ظ„ظ…ط­ط§ظˆظ„ط§طھ
-- (ظٹظڈط³طھط¯ط¹ظ‰ ظ…ظ† طھط·ط¨ظٹظ‚ ط§ظ„ظ…ظˆط¨ط§ظٹظ„ ط­ظˆظ„ login ظ„ظ„ط­ط¯ظ‘ ظ…ظ† ظ‡ط¬ظˆظ… ط§ظ„ظ‚ظˆط© ط§ظ„ط¹ظ…ظٹط§ط،)
-- ============================================================

-- ط­ط¯ظ‘ ط§ظ„ظ…ط­ط§ظˆظ„ط§طھ ط§ظ„ظپط§ط´ظ„ط© ظ‚ط¨ظ„ ط§ظ„ظ‚ظپظ„طŒ ظˆظ…ط¯ط© ط§ظ„ظ‚ظپظ„ ط¨ط§ظ„ط«ظˆط§ظ†ظٹ
CREATE OR REPLACE FUNCTION public.login_lock_max_attempts()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 5; $$;

CREATE OR REPLACE FUNCTION public.login_lock_duration_seconds()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 900; $$;

-- ظپط­طµ: ظ‡ظ„ ظٹظڈط³ظ…ط­ ظ„ظ„ظ…ط³طھط®ط¯ظ… ط¨ظ…ط­ط§ظˆظ„ط© طھط³ط¬ظٹظ„ ط§ظ„ط¯ط®ظˆظ„طں
-- ظٹظڈط±ط¬ط¹: allowed (طµط­ظٹط­/ط®ط·ط£), attempts_left, lock_seconds_remaining
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
    -- ظ„ط§ ط¨ط­ط« ط¹ظ† ظ…ط²ط±ط¹ط©/ط¯ظˆط± ظ‡ظ†ط§: ظ†ط·ط¨ظٹط¹ ط§ظ„ظ‡ط§طھظپ ظپظ‚ط·
    p_phone := regexp_replace(p_phone, '[^0-9]', '', 'g');

    SELECT failed_attempts, locked_until INTO v_failed, v_locked
    FROM public.users WHERE phone = p_phone LIMIT 1;

    -- ط­ط³ط§ط¨ ط؛ظٹط± ظ…ظˆط¬ظˆط¯: ظ†ظڈط¨ظ‚ظٹ ط§ظ„ط±ط¯ ظ…طھط·ط§ط¨ظ‚ط§ظ‹ ظ…ط¹ ط§ظ„ط­ط§ظ„ط§طھ ط§ظ„ظ…ظ…ظƒظ†ط© ظ„ط¥ط¨ط·ط§ط، ط§ظ„طھط¹ط¯ط§ط¯
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

-- طھط³ط¬ظٹظ„ ظ…ط­ط§ظˆظ„ط© ظپط§ط´ظ„ط©: ظٹط²ظٹط¯ ط§ظ„ط¹ط¯ظ‘ط§ط¯ ظˆظٹظ‚ظپظ„ ط§ظ„ط­ط³ط§ط¨ ط¨ط¹ط¯ طھط¬ط§ظˆط² ط§ظ„ط­ط¯ظ‘
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

-- طھط³ط¬ظٹظ„ ظ†ط¬ط§ط­: طھظڈطµظپظژظ‘ط± ط§ظ„ظ…ط­ط§ظˆظ„ط§طھ ظˆظڈظٹط±ظپط¹ ط§ظ„ظ‚ظپظ„
CREATE OR REPLACE FUNCTION public.record_login_success(p_uid uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_uid IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: ظ…ط¹ط±ظ‘ظپ ط؛ظٹط± طµط§ظ„ط­';
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

-- ط¥ظ†ط´ط§ط، ط£ظˆظ„ ظ…ط¯ط¬ظ†ط© ظˆظ…ط¯ظٹط±
-- P0: ط¨ظˆط§ط¨ط© ط³ط±ظٹ + ظ‚ظپظ„ ط§ط³طھط´ط§ط±ظٹ ظ„ظ…ظ†ط¹ ط§ظ„ط³ط¨ط§ظ‚.
--   - ظٹطھط·ظ„ط¨ p_provision_token ظٹط·ط§ط¨ظ‚ value ط¶ظ…ظ† app_settings (ظ…ظپطھط§ط­ secure.bootstrap_token)
--     ظٹظڈط¶ط¨ط· ظٹط¯ظˆظٹط§ظ‹ ط¹ظ†ط¯ ط§ظ„طھظ‡ظٹط¦ط© ط§ظ„ط£ظˆظ„ظ‰. ط¨ط¯ظˆظ† ط§ظ„طھظˆظƒظ† â†’ ط±ظپط¶.
--   - pg_advisory_xact_lock ظٹظ…ظ†ط¹ ط¥ظ†ط´ط§ط، ظ…ط²ط±ط¹ط©/ظ…ط¯ظٹط± ظ…ط²ط¯ظˆط¬ ط¹ظ†ط¯ ط·ظ„ط¨ط§طھ ظ…طھط²ط§ظ…ظ†ط©.
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
    v_expected  text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('madjana_bootstrap'));

    IF EXISTS (SELECT 1 FROM users LIMIT 1) THEN
        RAISE EXCEPTION 'ظٹظˆط¬ط¯ ظ…ط³طھط®ط¯ظ…ظˆظ† ط¨ط§ظ„ظپط¹ظ„ â€” ظ‡ط°ظ‡ ط§ظ„ط¯ط§ظ„ط© ظ„ظ„طھظ‡ظٹط¦ط© ط§ظ„ط£ظˆظ„ظ‰ ظپظ‚ط·';
    END IF;

    -- ============================================================
-- 6) Triggers ط§ظ„ط­ط³ط§ط¨ط§طھ
-- ============================================================
CREATE OR REPLACE FUNCTION public.calc_total_eggs()
RETURNS TRIGGER AS $$
DECLARE
    v_carton int;
    v_tray   int;
BEGIN
    -- P0/8: ظ‚ط±ط§ط،ط© ط¥ط¹ط¯ط§ط¯ط§طھ ط§ظ„ظ…ط²ط±ط¹ط© (farms.eggs_per_carton/eggs_per_tray)
    -- ط¨ط¯ظ„ط§ظ‹ ظ…ظ† 360/30 ط§ظ„ظ…ط«ط¨طھط© ظƒظˆط¯ظٹط§ظ‹ â€” ظ…ط¹ fallback ظ„ظ„ظ‚ظٹظ… ط§ظ„ط§ظپطھط±ط§ط¶ظٹط©.
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
    -- ظ‡ظ„ ظٹظ…ظ„ظƒ ط§ظ„ط¯ظˆط± طµظ„ط§ط­ظٹط© ظ‚ط±ط§ط،ط© (ط³ط­ط¨) ظ„ط¬ط¯ظˆظ„ ط¹ط¨ط± ط§ظ„ظ…ط²ط§ظ…ظ†ط©طں
GRANT EXECUTE ON FUNCTION public.sync_can_write(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_can_read(text, text) TO authenticated;

-- ============================================================
-- 13) sync_records_batch - ظ…ط¹ whitelist + auth.uid() + version
-- ============================================================
-- 14) validate_flock_farm - ط­ظ…ط§ظٹط© ط¶ط¯ cross-farm operations
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
        RAISE EXCEPTION 'ط§ظ„ط¯ط¬ط§ط¬ط© ط؛ظٹط± ظ…ظˆط¬ظˆط¯ط©: %', NEW.flock_id;
    END IF;
    IF v_farm_id != NEW.farm_id THEN
        RAISE EXCEPTION 'ط§ظ„ط¯ط¬ط§ط¬ط© ظ„ط§ طھظ†طھظ…ظٹ ظ„ظ‡ط°ظ‡ ط§ظ„ظ…ط²ط±ط¹ط©';
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

-- P0/13: طھط؛ط·ظٹط© ط¨ط§ظ‚ظٹ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھظٹ طھط­ظ…ظ„ flock_id â€” same cross-farm guard
DROP TRIGGER IF EXISTS trg_validate_flock_med ON medications;
CREATE TRIGGER trg_validate_flock_med
    BEFORE INSERT OR UPDATE ON medications
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

DROP TRIGGER IF EXISTS trg_validate_flock_ob ON opening_balances;
CREATE TRIGGER trg_validate_flock_ob
    BEFORE INSERT OR UPDATE ON opening_balances
    FOR EACH ROW EXECUTE FUNCTION public.validate_flock_farm();

-- P0/13: ط·ظ„ط¨ ط§ظ„طھظˆط²ظٹط¹ â€” ظٹظڈظ…ظ„ظƒ flock_id ظˆ customer_id ظ…ط¹ط§ظ‹ط›
-- ظٹط¬ط¨ ط£ظ† ظٹظ†طھظ…ظٹ ظƒظ„ط§ظ‡ظ…ط§ ظ„ظ†ظپط³ ط§ظ„ظ…ط²ط±ط¹ط© (RLS ظˆط­ط¯ظ‡ ظ„ط§ ظٹطھط­ظ‚ظ‚ ظ…ظ† ط§ظ„طµظپظˆظپ ط§ظ„ظ…ط±ط¬ط¹ظٹط©).
CREATE OR REPLACE FUNCTION public.validate_dispatch_refs()
RETURNS TRIGGER AS $$
DECLARE
    v_flock_farm uuid;
    v_cust_farm  uuid;
BEGIN
    IF NEW.flock_id IS NOT NULL THEN
        SELECT farm_id INTO v_flock_farm FROM flocks WHERE id = NEW.flock_id;
        IF v_flock_farm IS NULL THEN
            RAISE EXCEPTION 'ط§ظ„ظ‚ط·ظٹط¹ ط؛ظٹط± ظ…ظˆط¬ظˆط¯: %', NEW.flock_id;
        END IF;
        IF v_flock_farm != NEW.farm_id THEN
            RAISE EXCEPTION 'ط§ظ„ظ‚ط·ظٹط¹ ظ„ط§ ظٹظ†طھظ…ظٹ ظ„ظ‡ط°ظ‡ ط§ظ„ظ…ط²ط±ط¹ط©';
        END IF;
    END IF;
    IF NEW.customer_id IS NOT NULL THEN
        SELECT farm_id INTO v_cust_farm FROM customers WHERE id = NEW.customer_id;
        IF v_cust_farm IS NULL THEN
            RAISE EXCEPTION 'ط§ظ„ط²ط¨ظˆظ† ط؛ظٹط± ظ…ظˆط¬ظˆط¯: %', NEW.customer_id;
        END IF;
        IF v_cust_farm != NEW.farm_id THEN
            RAISE EXCEPTION 'ط§ظ„ط²ط¨ظˆظ† ظ„ط§ ظٹظ†طھظ…ظٹ ظ„ظ‡ط°ظ‡ ط§ظ„ظ…ط²ط±ط¹ط©';
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
-- 15) ط§ظ„طµظ„ط§ط­ظٹط§طھ ط§ظ„ط¹ط§ظ…ط© + ط¥ط¹ط§ط¯ط© طھط­ظ…ظٹظ„ ظ…ط®ط·ط· PostgREST
-- ============================================================
GRANT USAGE ON SCHEMA public TO anon, authenticated;
-- P0/20: anon ظ„ط§ ظٹط­طµظ„ ط¹ظ„ظ‰ ط£ظٹ CRUD ط¹ظ„ظ‰ ط§ظ„ط¬ط¯ط§ظˆظ„ â€” ظٹطµظ„ ظپظ‚ط· ط¹ط¨ط± ط§ظ„ط¯ظˆط§ظ„ RPC
-- ط§ظ„ط¶ط±ظˆط±ظٹط© ط§ظ„ظ…ظ…ظ†ظˆط­ط© ط£ط¯ظ†ط§ظ‡. RLS ظ‡ظˆ ظپظ‚ط· ط¹ط²ظ„ ط§ظ„طµظپظˆظپ ط¨ظٹظ† ط§ظ„ظ€ tenantsط›
-- ظˆظ„ظٹط³ ط·ط¨ظ‚ط© ط­ظ…ط§ظٹط© anon ظ…ظ† ط§ظ„ظˆطµظˆظ„ ظ„ظ„ط¬ط¯ط§ظˆظ„. authenticated ظٹط¨ظ‚ظ‰ ط¹ظ„ظ‰ CRUD
-- (ظ…ظڈظ‚ظژظٹظژظ‘ط¯ ط¨ط§ظ„ظƒط§ظ…ظ„ ط¹ط¨ط± RLS).
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
-- find_user_by_phone ظٹظڈط³طھط¯ط¹ظ‰ ظ‚ط¨ظ„ Auth (ظ„طھط³ط¬ظٹظ„ ط§ظ„ط¯ط®ظˆظ„)طŒ ظ„ط°ط§ ظٹظڈطھط§ط­ ظ„ظ€ anonطŒ
-- ظ„ظƒظ†ظ‡ ظ„ط§ ظٹط¹ظٹط¯ ط¥ظ„ط§ id (ظ…ط·ظ„ظˆط¨ ظ„طھط³ط¬ظٹظ„ ط§ظ„ط¯ط®ظˆظ„) â€” ظ„ط§ ط§ط³ظ…/ظ‡ط§طھظپ ظ„ظ…ظ†ط¹ ط§ظ„طھط¹ط¯ط§ط¯.
GRANT EXECUTE ON FUNCTION public.find_user_by_phone(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bootstrap_create_farm_and_manager(text, text, text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_user(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_user(text, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_pin(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_farm_id() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_system_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.app_password_from_pin(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.app_user_email(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pull_remote_changes(uuid, bigint) TO authenticated;
-- cleanup/compact: ظ„ط§ ظٹظڈظ…ظ†ط­ ظ„ظ„ظ…ط³طھط®ط¯ظ…ظٹظ†. ظٹظڈط³طھط¯ط¹ظ‰ ط¹ط¨ط± Edge Function/pg_cron ط¨طµظ„ط§ط­ظٹط©
-- service_role ط£ظˆ manager ظپظ‚ط·طŒ ظˆطھظ†ظپظ‘ط°ظ‡ auto_maintain_sync ط¯ط§ط®ظ„ظٹط§ظ‹ ط¨ط§ظ„ط³ط­ط¨.
GRANT EXECUTE ON FUNCTION public.cleanup_old_sync_changes(int, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.compact_sync_changes(uuid) TO authenticated;

-- ============================================================
-- 16) RLS ظ„ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„ط¬ط¯ظٹط¯ط©
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

-- (19) audit_log append-only ظˆظ…ظڈظ†ط´ط£ ط­طµط±ظٹط§ظ‹ ط¹ط¨ط± ط§ظ„ظ†ط¸ط§ظ…:
-- ظ„ط§ طھظˆط¬ط¯ ط³ظٹط§ط³ط© INSERT ظ„ط£ظٹ ظ…ط³طھط®ط¯ظ… (ط­طھظ‰ ط§ظ„ظ…ط¯ظٹط±) â€” ظ„ط§ ظٹظ…ظƒظ† ظ„ط£ظٹ طھط·ط¨ظٹظ‚
-- طھطµظ†ظٹط¹ ط³ط¬ظ„ط§طھ طھط¯ظ‚ظٹظ‚طŒ ظˆظ„ط§ طھط¹ط¯ظٹظ„/ط­ط°ظپ (ظ„ط§ طھظˆط¬ط¯ ط³ظٹط§ط³ط§طھ UPDATE/DELETE).
-- ط§ظ„ظˆط­ظٹط¯ ط§ظ„ط°ظٹ ظٹظƒطھط¨ ظ‡ظˆ trigger ط§ظ„ط¯ط§ظ„ط© SECURITY DEFINER log_audit_changes.
DROP POLICY IF EXISTS audit_insert_manager ON audit_log;
DROP POLICY IF EXISTS audit_insert_system ON audit_log;

-- ============================================================
-- 17) ظ‚ظٹظˆط¯ ط§ظ„ظ…ط¬ط§ظ„ ط§ظ„ظ…ط§ظ„ظٹط© (P0/25 + P0/26)
--    - payments â†’ egg_dispatch: ظ†ظپط³ ط§ظ„ط²ط¨ظˆظ† ظˆظ†ظپط³ ط§ظ„ظ…ط²ط±ط¹ط©.
--    - customers.total_debt ظ…ظڈط´طھظ‚ ظˆظ„ط§ ظٹظڈظƒطھط¨ ظ…ط¨ط§ط´ط±ط© (ظٹظ…ظ†ط¹ ط§ظ„ط§ظ†ط¬ط±ط§ظپ).
-- ============================================================

-- ط­ط§ط±ط³ ط§ظ„ط¹ظ…ظ„ظٹط§طھ (25): طھط´ط؛ظٹظ„ ظ‚ط¨ظ„ ط¥ط¯ط±ط§ط¬/طھط­ط¯ظٹط« payment ظ„ط¶ظ…ط§ظ†
-- طھط·ط§ط¨ظ‚ ط§ظ„ط²ط¨ظˆظ†/ط§ظ„ط·ظ„ط¨/ط§ظ„ظ…ط²ط±ط¹ط©.
CREATE OR REPLACE FUNCTION public.validate_payment_refs()
RETURNS TRIGGER AS $$
DECLARE
    v_dispatch_customer uuid;
    v_dispatch_farm     uuid;
    v_customer_farm     uuid;
BEGIN
    -- payment.customer_id ظٹط¬ط¨ ط£ظ† ظٹظ†طھظ…ظٹ ظ„ظ†ظپط³ ظ…ط²ط±ط¹ط© ط§ظ„طµظپ
    SELECT farm_id INTO v_customer_farm FROM customers WHERE id = NEW.customer_id;
    IF v_customer_farm IS NULL THEN
        RAISE EXCEPTION 'ط§ظ„ط²ط¨ظˆظ† ط؛ظٹط± ظ…ظˆط¬ظˆط¯: %', NEW.customer_id;
    END IF;
    IF v_customer_farm != NEW.farm_id THEN
        RAISE EXCEPTION 'ط§ظ„ط²ط¨ظˆظ† ظ„ط§ ظٹظ†طھظ…ظٹ ظ„ظ‡ط°ظ‡ ط§ظ„ظ…ط²ط±ط¹ط©';
    END IF;

    -- ط¥ظ† ط§ط±طھط¨ط· ط¨ظ€ dispatch ظپظٹط¬ط¨ ط£ظ† ظٹظƒظˆظ† ظ„ظ†ظپط³ ط§ظ„ط²ط¨ظˆظ† ظˆظ†ظپط³ ط§ظ„ظ…ط²ط±ط¹ط© (25)
    IF NEW.dispatch_id IS NOT NULL THEN
        SELECT c.farm_id, d.customer_id
        INTO v_dispatch_farm, v_dispatch_customer
        FROM egg_dispatch d
        JOIN customers c ON c.id = d.customer_id
        WHERE d.id = NEW.dispatch_id;
        IF v_dispatch_customer IS NULL THEN
            RAISE EXCEPTION 'ط§ظ„ط·ظ„ط¨ ط؛ظٹط± ظ…ظˆط¬ظˆط¯: %', NEW.dispatch_id;
        END IF;
        IF v_dispatch_customer != NEW.customer_id THEN
            RAISE EXCEPTION 'ط§ظ„ط¯ظپط¹ ظ…ط±طھط¨ط· ط¨ط·ظ„ط¨ ط²ط¨ظˆظ† ط¢ط®ط±';
        END IF;
        IF v_dispatch_farm != NEW.farm_id THEN
            RAISE EXCEPTION 'ط§ظ„ط·ظ„ط¨ ظ„ط§ ظٹظ†طھظ…ظٹ ظ„ظ‡ط°ظ‡ ط§ظ„ظ…ط²ط±ط¹ط©';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_payment_refs ON payments;
CREATE TRIGGER trg_validate_payment_refs
    BEFORE INSERT OR UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION public.validate_payment_refs();

-- (26): total_debt ظ„ط§ ظٹظڈظƒطھط¨ ظ…ط¨ط§ط´ط±ط© â€” ظپظ‚ط· ظٹظڈط¹ط§ط¯ ط­ط³ط§ط¨ظ‡ ظ…ظ† payments.
-- ط§ظ„ط§ط³طھط«ظ†ط§ط، ط¹ط¨ط± GUC ظ…ظˆظ‚طھ ط¯ط§ط®ظ„ ط§ظ„ط¯ط§ظ„ط© ط§ظ„ظ…ط¹طھظ…ط¯ط© (recalc).
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

-- ط¥ط¹ط§ط¯ط© ط­ط³ط§ط¨ ط§ظ„ط¯ظٹظˆظ† طھظ„ظ‚ط§ط¦ظٹط§ظ‹ ط¹ظ†ط¯ ط£ظٹ طھط؛ظٹظٹط± ظپظٹ payments.
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
-- 18) ط³ظٹط§ط³ط§طھ Storage (P0/28) â€” ظ…ط³ط§ط± ظ…ط¹ط²ظˆظ„ tenant:
--     farms/{farm_id}/mortality/{record_id}/...
--     ط§ظ„ط±ظپط¹/ط§ظ„ط­ط°ظپ ظ…ظ‚ظٹط¯ ط¨ظ…ط²ط±ط¹ط© ط§ظ„ظ…ط³طھط®ط¯ظ…. ط§ظ„ظ‚ط±ط§ط،ط© ط§ظ„ط¹ط§ظ…ط© طھط¨ظ‚ظ‰ ط®ظٹط§ط±ط§ظ‹ ظ…ط·ط¨ظˆط¹ط§ظ‹
--     (ط§ظ„ظ…ظ„ط§ط­ط¸ط©: ط§ظ„طھط·ط¨ظٹظ‚ ظٹط¹ط±ط¶ ط§ظ„طµظˆط± ط¹ط¨ط± ط§ظ„ط±ط§ط¨ط· ط§ظ„ط¹ط§ظ… ط¨ط¯ظˆظ† headers) â€”
--     ط§ظ„ط°ظ‡ط§ط¨ ط¥ظ„ظ‰ ط®ط§طµظٹط© signed URLs ظٹطھط·ظ„ط¨ طھط؛ظٹظٹط±ط§ظ‹ ظپظٹ ظˆط§ط¬ظ‡ط© ط§ظ„ط¹ط±ط¶.
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
-- 19) ط¢ظ„ظٹط© ط§ظ„ط³ط­ط¨ ظ…ظ† ط§ظ„ط®ط§ط¯ظ… (Server â†’ Client Push)
--     - trigger ظٹظڈط¯ط®ظ„ ظپظٹ sync_changes ط¹ظ†ط¯ ظƒظ„ طھط¹ط¯ظٹظ„ ط¹ظ„ظ‰ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹط©
--     - pull_remote_changes RPC ظٹط³طھط¹ظ„ظ… ط¹ظ† ط§ظ„طھط؛ظٹظٹط±ط§طھ ط§ظ„ط¬ط¯ظٹط¯ط©
--     - ظ‡ط°ط§ ظ…ط§ ظٹظڈظƒظ…ظ„ ط±ط¨ط· Device B ط¨ظ€ Device A ط¹ط¨ط± ط§ظ„ط³ظٹط±ظپط±
-- ============================================================

-- ط§ظ„ط¯ط§ظ„ط© ط§ظ„ظ…ط´طھط±ظƒط©: طھظڈظˆظ„ظ‘ط¯ ط³ط¬ظ„ ظپظٹ sync_changes ط¨ط¹ط¯ ط£ظٹ INSERT/UPDATE/DELETE
-- ط¹ظ„ظ‰ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹط©. طھطھط¬ط§ظˆط² ط§ظ„ظƒطھط§ط¨ط© ط¥ط°ط§ ظƒط§ظ† ط§ظ„ظƒط§طھط¨ ظ‡ظˆ sync_records_batch
-- (ط§ظ„ط°ظٹ ظٹظڈط¹ط§ظ„ط¬ ط§ظ„ظ…ط²ط§ظ…ظ†ط© ط§ظ„ط¹ظƒط³ظٹط©) ظ„طھط¬ظ†ط¨ ط§ظ„طھظƒط±ط§ط±.
CREATE OR REPLACE FUNCTION public.populate_sync_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
    v_farm_id uuid;
    v_op      text;
    v_payload jsonb;
    v_rec     record;
BEGIN
    -- ظ„ط§ طھظڈط¯ط®ظ„ ط¥ط°ط§ ظƒط§ظ† ط¯ط§ط®ظ„ sync_records_batch (ظٹظƒطھط¨ Subtransaction ظ…ط¹ط²ظˆظ„ط©)
    IF current_setting('app.skip_sync_trigger', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- ظ„ط§ طھظڈط¯ط®ظ„ ظ„ط¹ظ…ظ„ظٹط§طھ ط§ظ„ظ…ط³طھط®ط¯ظ… ط§ظ„ط§ظپطھط±ط§ط¶ظٹ (00000000)
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

    -- ط¨ظ†ط§ط، ط§ظ„ظ€ payload ظ…ظ† ط¬ظ…ظٹط¹ ط£ط¹ظ…ط¯ط© ط§ظ„طµظپ (ط¨ط¯ظˆظ† tenant-irrelevant fields)
    IF TG_OP = 'DELETE' THEN
        v_payload := to_jsonb(OLD);
    ELSE
        v_payload := to_jsonb(NEW);
    END IF;
    -- ط¥ط²ط§ظ„ط© ط£ط¹ظ…ط¯ط© ط§ظ„ظ…à¹€à¸›à¸¥ظٹط© (ط§ظ„ظ…ط²ط±ط¹ط© + ط§ظ„ظ…ظڈautogenerate) ظ„طھظ‚ظ„ظٹظ„ ط§ظ„ط­ط¬ظ…
    -- P0: ظ†ط­طھظپط¸ ط¨ظ€ version ظپظٹ ط§ظ„ظ€ payload ظ„ط£ظ† ط§ظ„ط£ط¬ظ‡ط²ط© ط§ظ„ظ…ط³طھظ‚ط¨ظ„ط© طھط­طھط§ط¬ظ‡ ظ„ط¹ظ…ظ„ظٹط§طھ OCC.
    v_payload := v_payload - 'sync_status' - 'deleted_at';

    INSERT INTO sync_changes (table_name, record_id, operation, farm_id, user_id, payload)
    VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), v_op, v_farm_id, v_user_id, v_payload);

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- طھظپط¹ظٹظ„ ط§ظ„ظ€ trigger ط¹ظ„ظ‰ ظƒظ„ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹط© (ظپظ‚ط· طھظ„ظƒ ط§ظ„طھظٹ طھط­طھظˆظٹ farm_id)
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

-- RPC: ط§ظ„ط³ط­ط¨ â€” ظٹظڈط±ط¬ط¹ ط§ظ„طھط؛ظٹظٹط±ط§طھ ظ…ظ†ط° ط¥طµط¯ط§ط± ظ…ط¹ظٹظ†
-- ظٹط³طھط®ط¯ظ…ظ‡ ط§ظ„ط¹ظ…ظٹظ„ ظ„ط§ظƒطھط´ط§ظپ ظ…ط§ ط£ط¶ط§ظپظ‡ ط§ظ„ط£ط¬ظ‡ط²ط© ط§ظ„ط£ط®ط±ظ‰.
-- ط§ظ„ط£ظ…ط§ظ†: ظپظ‚ط· ط§ظ„ظ…ط¯ظٹط± (ط£ظˆ system_admin) ط§ظ„ط®ط§طµ ط¨ط§ظ„ظ…ط²ط±ط¹ط© ظٹظ…ظƒظ†ظ‡ ط§ظ„ط³ط­ط¨ط›
-- طھظ†ط¸ظٹظپ sync_changes ط§ظ„ظ‚ط¯ظٹظ…ط© â€” ظ…ظ‚طµظˆط± ط¹ظ„ظ‰ ط§ظ„ظ…ط¯ظٹط±/system_admin ظپظ‚ط·.
-- ظٹظڈط³طھط¯ط¹ظ‰ ط¯ظˆط±ظٹط§ظ‹ ظ…ظ† Edge Function ط£ظˆ pg_cron ط¨طµظ„ط§ط­ظٹط© managerطŒ ظˆظ„ظٹط³ ظ…ظ† ط§ظ„ط¹ظ…ط§ظ„.
-- ============================================================
-- (21) ط§ط³طھط±ط§طھظٹط¬ظٹط© ط§ظ„ط§ط­طھظپط§ط¸/ط§ظ„ط¶ط؛ط·/ط§ظ„ظ€ checkpoint ظ„ط¬ط¯ظˆظ„ ط§ظ„ظ…ط²ط§ظ…ظ†ط©
-- ============================================================
-- ظ…ظƒظˆظ‘ظ† ظ…ظ† ط£ط±ط¨ط¹ ط·ط¨ظ‚ط§طھ:
--   1) Retention  : cleanup_old_sync_changes() â€” ظٹط­ط°ظپ ظ…ط§ ظ…ط¶ظ‰ ط¹ظ„ظ‰ ط­ظپط¸ظ‡ ظپطھط±ط© ظ…ط³ظ…ظˆط­ط©.
--   2) Compaction : compact_sync_changes() â€” ظٹط·ظˆظٹ ط³ظ„ط§ط³ظ„ UPDATE ط§ظ„ظ…طھطھط§ظ„ظٹط©
--                   ظ„ظƒظ„ (farm, table, record) ظˆظٹط¨ظ‚ظٹ ط¢ط®ط±ظ‡ط§ ظپظ‚ط· (ط§ظ„ظ€ payload طµظˆط±ط©
--                   ظƒط§ظ…ظ„ط© ظ„ظ„طµظپطŒ ظ„ط°ط§ طھط®ط·ظ‘ظٹ ط§ظ„ظ†ط³ط® ط§ظ„ظˆط³ط·ظ‰ ظ„ط§ ظٹظپظ‚ط¯ ظ…ط¹ظ„ظˆظ…ط§طھ).
--   3) Checkpoint : refresh_sync_checkpoint() â€” ظٹط®ط²ظ‘ظ† latest/purged_below per farm
--                   ط¨ط¯ظ„ط§ظ‹ ظ…ظ† ظپط­ظˆطµ MIN/MAX ط§ظ„ظ…ظƒظ„ظپط© ظپظٹ ظƒظ„ ط³ط­ط¨.
--   4) Auto       : auto_maintain_sync() â€” طµظٹط§ظ†ط© ط¯ظˆط±ظٹط© ظ…ظ‚ظٹظ‘ط¯ط© ط²ظ…ظ†ظٹط§ظ‹ (throttle)
--                   طھظڈط³طھط¯ط¹ظ‰ ظپط±طµظٹط§ظ‹ ظ…ظ† pull/push ط¯ظˆظ† ط­ط§ط¬ط© ظ„ط¬ط¯ظˆظ„ط© ط®ط§ط±ط¬ظٹط©.

-- ط£ط¯ط§ط© ط¯ط§ط®ظ„ظٹط©: ظ‚ط±ط§ط،ط© ظپطھط±ط© ط§ظ„ط§ط­طھظپط§ط¸ ظ…ظ† ط§ظ„ط¥ط¹ط¯ط§ط¯ط§طھ (ط§ظپطھط±ط§ط¶ظٹط§ظ‹ 30 ظٹظˆظ…ط§ظ‹)
CREATE OR REPLACE FUNCTION public._sync_retention_days()
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE((SELECT value::int FROM public.app_settings WHERE key = 'sync.retention_days'), 30);
$$;

-- ط£ط¯ط§ط© ط¯ط§ط®ظ„ظٹط©: ظ‚ط±ط§ط،ط© ظپطھط±ط© ط§ظ„طµظٹط§ظ†ط© ط§ظ„ط¯ظ†ظٹط§ ط¨ط§ظ„ط¯ظ‚ط§ط¦ظ‚ (ط§ظپطھط±ط§ط¶ظٹط§ظ‹ 6 ط³ط§ط¹ط§طھ)
CREATE OR REPLACE FUNCTION public._sync_maintenance_interval_minutes()
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE((SELECT value::int FROM public.app_settings WHERE key = 'sync.maintenance_interval_minutes'), 360);
$$;

-- ============================================================
-- (3) طھط­ط¯ظٹط« checkpoint ظ„ظ…ط²ط±ط¹ط© (ط£ظˆ ظƒظ„ ط§ظ„ظ…ط²ط§ط±ط¹):
--   latest_version = MAX(server_version) ظ„ظ„ظ…ط²ط±ط¹ط©
--   purged_below   = MIN(server_version) ط§ظ„ظ…ط­طھط¬ط² ط¨ط¹ط¯ ط§ظ„طھظ†ط¸ظٹظپ/ط§ظ„ط¶ط؛ط·
-- ظٹط¹ظ…ظ„ ط¯ط§ط®ظ„ظٹط§ظ‹ (ط¨ط¯ظˆظ† طھط­ظ‚ظ‚ ط¯ظˆط±ط§طھ) ظ„ط§ط³طھط¯ط¹ط§ط¦ظ‡ ظ…ظ† ط¯ظˆط§ظ„ ط£ط®ط±ظ‰.
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
    -- ظ„ط§ طھظ‚ظ„ظ‚: ظ‡ط°ظ‡ ط¯ط§ظ„ط© ط¯ط§ط®ظ„ظٹط©ط› ط§ظ„طھط­ظ‚ظ‚ ظ…ظ† ط§ظ„طµظ„ط§ط­ظٹط© ظٹطھظ… ظپظٹ ط§ظ„ط¯ط¹ظˆط§طھ ط§ظ„ط¹ط§ظ…ط© (cleanup/compact).
    IF p_all THEN
        FOR v_f IN SELECT id FROM public.farms LOOP
            PERFORM public.refresh_sync_checkpoint(v_f.id);
        END LOOP;
        RETURN;
    END IF;

    IF p_farm_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_ERROR: ظٹط¬ط¨ طھط­ط¯ظٹط¯ ظ…ط²ط±ط¹ط© ط£ظˆ p_all = true';
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
-- (1) Retention: ط­ط°ظپ ط§ظ„ظ‚ط¯ظٹظ… + طھط­ط¯ظٹط« checkpoint.
-- ط¹ط§ظ… â€” طھط­ظ‚ظ‚ طµط±ط§ط­ط© ظ…ظ† ط¯ظˆط± ط§ظ„ظ…ط³طھط®ط¯ظ… (manager ظ…ط²ط±ط¹طھظ‡ / system_admin ط§ظ„ظƒظ„).
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
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: ط؛ظٹط± ظ…ط³ظ…ظˆط­ ط¨طھظ†ط¸ظٹظپ ط§ظ„ظ…ط²ط§ظ…ظ†ط©';
    END IF;

    v_keep_days := COALESCE(p_keep_days, public._sync_retention_days());
    IF v_keep_days < 1 THEN
        RAISE EXCEPTION 'VALIDATION_ERROR: ظپطھط±ط© ط§ظ„ط§ط­طھظپط§ط¸ ظٹط¬ط¨ ط£ظ† طھظƒظˆظ† ظٹظˆظ…ط§ظ‹ ظˆط§ط­ط¯ط§ظ‹ ط¹ظ„ظ‰ ط§ظ„ط£ظ‚ظ„';
    END IF;

    -- ط§ظ„ظ…ط¯ظٹط± ظٹظ†ط¸ظپ ط¨ظٹط§ظ†ط§طھ ظ…ط²ط±ط¹طھظ‡ ظپظ‚ط·ط› system_admin ظٹظ†ط¸ظپ ظƒظ„ ط§ظ„ظ…ط²ط§ط±ط¹ (ط£ظˆ ط§ظ„ظ…ط²ط±ط¹ط© ط§ظ„ظ…ط¹ط·ط§ط©).
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
-- (2) Compaction: ط·ظٹظ‘ ط³ظ„ط§ط³ظ„ UPDATE ط§ظ„ظ…طھطھط§ظ„ظٹط© ظ„ظƒظ„ ط³ط¬ظ„.
-- ظٹط­ط°ظپ ط£ظٹ طµظپ UPDATE ظٹط³ط¨ظ‚ظ‡ (ط¶ظ…ظ† ظ†ظپط³ farm/table/record) طµظپ UPDATE ظ…ط¨ط§ط´ط±ط©طŒ
-- ظ…ط­طھظپط¸ط§ظ‹ ط¨ط¢ط®ط± UPDATE ظپظ‚ط· ظپظٹ ط§ظ„ط³ظ„ط³ظ„ط©. ظ„ط§ ظٹظ…ط³ظ‘ INSERT/DELETE ط£ط¨ط¯ط§ظ‹ ط­طھظ‰ ظ„ط§
-- ظ†ظƒط³ط± طھط±طھظٹط¨ ط¯ظˆط±ط© ط­ظٹط§ط© ط§ظ„ط³ط¬ظ„. ظٹظ‚ط±ط£ purged_below ظ…ظ† checkpoint ظ„ظٹط·ظˆظٹ ط¯ط§ط®ظ„
-- ظ†ط·ط§ظ‚ ظ…ط­طھط¬ط² ظپظ‚ط· (ظ„ط§ ظٹط¹ظٹط¯ ظƒطھط§ط¨ط©/ط­ط°ظپ ظ…ط§ ظ‡ظˆ ط®ط§ط±ط¬ ظپطھط±ط© ط§ظ„ط§ط­طھظپط§ط¸).
-- ط¹ط§ظ… â€” طھط­ظ‚ظ‚ طµط±ط§ط­ط© ظ…ظ† ط§ظ„ط¯ظˆط±.
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
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: ط؛ظٹط± ظ…ط³ظ…ظˆط­ ط¨ط¶ط؛ط· ط§ظ„ظ…ط²ط§ظ…ظ†ط©';
    END IF;

    -- ط­طµط± ط§ظ„ظ†ط·ط§ظ‚: ظپظ‚ط· ط§ظ„ظ…ط²ط±ط¹ط© ط§ظ„ظ…ط­ط¯ط¯ط© (ط£ظˆ ظ…ط²ط±ط¹ط© ط§ظ„ظ…ط¯ظٹط±).
    IF public.is_system_admin() THEN
        IF p_farm_id IS NOT NULL THEN
            v_base := COALESCE((SELECT purged_below FROM sync_checkpoint WHERE farm_id = p_farm_id), 0);
            -- ط·ظٹظ‘ ط§ظ„ط³ظ„ط³ظ„ط©: ط§ط­ط°ظپ UPDATE ط§ظ„ط£ظ‚ط¯ظ… (prev) ط¹ظ†ط¯ظ…ط§ ظٹظ„ظٹظ‡ UPDATE ط£ط­ط¯ط« (sc)
            -- ظ„ظ†ظپط³ farm/table/record ط¯ظˆظ† ط£ظٹ INSERT/DELETE ظˆط³ظٹط·طŒ ظ…ظڈط¨ظ‚ظٹط§ظ‹ ط§ظ„ط£ط­ط¯ط« ظپظ‚ط·
            -- (payload طµظˆط±ط© ظƒط§ظ…ظ„ط© ظ„ظ„طµظپطŒ ظپطھط®ط·ظ‘ظٹ ط§ظ„ظ†ط³ط® ط§ظ„ظˆط³ط·ظ‰ ظ„ط§ ظٹظپظ‚ط¯ ظ…ط¹ظ„ظˆظ…ط§طھ).
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

    -- طھط­ط¯ظٹط« checkpoint ط¨ط¹ط¯ ط§ظ„ط¶ط؛ط·
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
-- (4) Auto-maintenance: طµظٹط§ظ†ط© ط¯ظˆط±ظٹط© ظ…ظ‚ظٹظ‘ط¯ط© ط²ظ…ظ†ظٹط§ظ‹.
-- طھظڈط³طھط¯ط¹ظ‰ ظپط±طµظٹط§ظ‹ ظ…ظ† pull_remote_changes/sync_records_batch. طھظ†ظپظ‘ط°
-- retention + compaction + checkpoint ظ„ظ…ط²ط±ط¹ط© ط§ظ„ظ…ط³طھط®ط¯ظ… ط¨ط­ط¯ ط£ظ‚طµظ‰ ظ…ط±ط©
-- ظƒظ„ maintenance_interval_minutes (ط§ظپطھط±ط§ط¶ظٹط§ظ‹ 6 ط³ط§ط¹ط§طھ) ظ„طھط¬ظ†ظ‘ط¨ طھظƒط±ط§ط± ط§ظ„ط¹ظ…ظ„.
-- طھظڈظ†ظپظژظ‘ط° ط¨طµظ„ط§ط­ظٹط© ط§ظ„ظ…طھطµظ„ ط¹ط¨ط± ط§ظ„ط¯ظˆط§ظ„ ط§ظ„ط¹ط§ظ…ط© (ظپط§ظ„طھط­ظ‚ظ‚ ظ…ظ† ط§ظ„ط¯ظˆط± ط¯ط§ط®ظ„ ظƒظ„ظچظ‘ ظ…ظ†ظ‡ط§).
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

    v_interval := make_interval(mins => public._sync_maintenance_interval_minutes());

    SELECT last_maintenance INTO v_last
    FROM sync_checkpoint WHERE farm_id = v_farm;

    -- ظ„ط§ ظ†ظƒط±ط± ط§ظ„ط¹ظ…ظ„ ط¥ط°ط§ ظƒط§ظ†طھ ط§ظ„طµظٹط§ظ†ط© ط§ظ„ط£ط®ظٹط±ط© ط­ط¯ظٹط«ط©.
    IF v_last IS NOT NULL AND v_last > NOW() - v_interval THEN
        RETURN;
    END IF;

    -- retention
    PERFORM public.cleanup_old_sync_changes(NULL, v_farm);
    -- compaction (ظٹظڈظ†ظپظژظ‘ط° ظپظ‚ط· ظپظٹ ظ†ط·ط§ظ‚ checkpoint â€” ظ„ط§ ظٹط¹ظٹط¯ ط­ط°ظپ ظ…ط§ ظˆط±ط§ط، ط§ظ„ط§ط­طھظپط§ط¸)
    PERFORM public.compact_sync_changes(v_farm);

    -- طھط­ط¯ظٹط« ط§ظ„ط·ط§ط¨ط¹ ط§ظ„ط²ظ…ظ†ظٹ (ظٹطھظ… ط¯ط§ط®ظ„ refreshطŒ ظ†ط¶ط¨ط·ظ‡ طµط±ط§ط­ط©ظ‹ ظ‡ظ†ط§)
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
-- 20) RPCs ظ„ظ†ط¸ط§ظ… ط§ظ„ط¥ط¯ط§ط±ط© + ط¬ط¯ظˆظ„ طµط±ط§ط¹ط§طھ ط§ظ„ظ…ط²ط§ظ…ظ†ط©
-- ============================================================

-- طµط­ط© ط§ظ„ظ…ط²ط§ظ…ظ†ط© ظ„ط¬ظ…ظٹط¹ ط§ظ„ظ…ط¯ط§ط¬ظ† (ظ„ظ€ system_admin ظپظ‚ط·) â€” ظٹط؛ط°ظ‘ظٹ SYNC CENTER.
-- ظ„ظƒظ„ ظ…ط²ط±ط¹ط©:
--   total_devices  = ط¹ط¯ط¯ ط§ظ„ط£ط¬ظ‡ط²ط© ط§ظ„ظ…ظ…ظٹظ‘ط²ط© ط§ظ„طھظٹ ط£ط±ط³ظ„طھ طھط؛ظٹظٹط±ط§طھ.
--   online_devices = ط¹ط¯ط¯ظ‡ط§ ط§ظ„ط°ظٹ ظƒط§ظ† ط¢ط®ط± ظ†ط´ط§ط·ظ‡ ط®ظ„ط§ظ„ ط§ظ„ظپطھط±ط© (ط§ظپطھط±ط§ط¶ظٹط§ظ‹ 5 ط¯ظ‚ط§ط¦ظ‚).
--   offline_devices= ط§ظ„ط¨ط§ظ‚ظٹ (ظ„ظ… ظٹظڈط±ظژ ظ…ظ†ط° ط£ط·ظˆظ„ ظ…ظ† ط§ظ„ظپطھط±ط©).
--   pending_conflicts = طµط±ط§ط¹ط§طھ ط؛ظٹط± ظ…ط­ظ„ظˆظ„ط© (sync_conflicts.status='pending').
--   last_sync     = ط¢ط®ط± ظ†ط´ط§ط· ظ…ط²ط§ظ…ظ†ط© ظ„ظ„ظ…ط²ط±ط¹ط©.
--   latest_version= watermark ServerVersion ظ…ظ† checkpoint.
-- ظ…ظ„ط§ط­ط¸ط©: ظ‚ظˆط§ط¦ظ… ط§ظ„ط§ظ†طھط¸ط§ط± ط§ظ„ظ…ط­ظ„ظٹط© (sync_queue ط¹ظ„ظ‰ ط§ظ„ط¬ظ‡ط§ط²) ظ„ط§ طھط¸ظ‡ط± ظ„ظ„ط®ط§ط¯ظ…ط›
GRANT EXECUTE ON FUNCTION public.admin_sync_health(int) TO authenticated;

-- ط¬ط¯ظˆظ„ طµط±ط§ط¹ط§طھ ط§ظ„ظ…ط²ط§ظ…ظ†ط©
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
CREATE POLICY conflicts_manager ON sync_conflicts
    FOR ALL TO authenticated
    USING (is_system_admin() OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id()))
    WITH CHECK (is_system_admin() OR (current_user_role() = 'manager' AND farm_id = current_user_farm_id()));


-- GRANT ظ„ظ„ط¯ظˆط§ظ„ ط§ظ„ط¬ط¯ظٹط¯ط©
GRANT EXECUTE ON FUNCTION public.admin_select_all_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_select_all_farms() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_farm_with_manager(text, text, text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- SECTION 2: SYSTEM ADMIN (20260902_001)
-- ============================================================
-- ============================================================
-- Migration 20260902_001: system_admin role + is_active + privilege escalation
--هڈ–ن»£ supervisor ط¨ظ†ط¸ط§ظ… admin
-- ============================================================

-- 1) ط¥ط¶ط§ظپط© is_active ظ„ظ„ظ…ط³طھط®ط¯ظ…ظٹظ† (طھط¹ط·ظٹظ„ ط¨ط¯ظˆظ† ط­ط°ظپ)
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- 2) طھط­ط¯ظٹط« ظ‚ظٹط¯ ط§ظ„ط¯ظˆط±: worker | manager | system_admin (ط¨ط¯ظˆظ† supervisor)
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
    CHECK (role IN ('worker', 'manager', 'system_admin'));

-- 3) ط¯ط§ظ„ط© ظ…ط³ط§ط¹ط¯ط©: ظ‡ظ„ ط§ظ„ظ…ط³طھط®ط¯ظ… ط§ظ„ط­ط§ظ„ظٹ system_admin ظ†ط´ط·طں
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

-- 4) طھط­ط¯ظٹط« handle_new_user ظ„ظٹط¹ط§ظ„ط¬ supervisor â†’ manager ط¹ظ†ط¯ ط§ظ„طھط­ظˆظٹظ„ ط§ظ„ظ‚ط¯ظٹظ…
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
    -- supervisor ط§ظ„ظ‚ط¯ظٹظ… ظٹطھط­ظˆظ„ ط¥ظ„ظ‰ manager طھظ„ظ‚ط§ط¦ظٹط§ظ‹
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

-- 5) ط­ط§ط±ط³: ط§ظ„ظ…ط¯ظٹط± ط£ظˆ system_admin
CREATE OR REPLACE FUNCTION public.assert_current_is_manager_of(p_farm_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    -- system_admin ظٹطھط¬ط§ظˆط² ط¹ط²ظ„ ط§ظ„ظ…ط²ط±ط¹ط©
    IF public.is_system_admin() THEN
        RETURN true;
    END IF;

    IF (SELECT public.current_user_role()) IS DISTINCT FROM 'manager' THEN
        RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ظ‡ط°ظ‡ ط§ظ„ط¹ظ…ظ„ظٹط© ظ„ظ„ظ…ط¯ظٹط± ظپظ‚ط·';
    END IF;
    IF (SELECT public.current_user_farm_id()) IS DISTINCT FROM p_farm_id THEN
        RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ط§ظ„ظ…ط³طھط®ط¯ظ… ظ„ظٹط³ ظ…ظ† ظ…ط²ط±ط¹طھظƒ';
    END IF;
    RETURN true;
END;
$$;

-- 6) ط­ظ…ط§ظٹط© ظ…ط³طھظˆظٹط§طھ ط§ظ„ط£ط¹ظ…ط¯ط© ط§ظ„ط­ط³ط§ط³ط© â€” system_admin ظٹط³طھط·ظٹط¹ طھط؛ظٹظٹط± ط£ظٹ ط´ظٹط،
CREATE OR REPLACE FUNCTION public.protect_users_sensitive_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_role   text;
    v_caller_farm   uuid;
    v_target_farm   uuid;
BEGIN
    v_caller_role := public.current_user_role();
    v_caller_farm := public.current_user_farm_id();

    -- system_admin ظٹط³طھط·ظٹط¹ ظƒظ„ ط´ظٹط، (ظ„ظƒظ†ظ‡ ظ„ط§ ظٹط³طھط·ظٹط¹ طھطµط¹ظٹط¯ ظ†ظپط³ظ‡ â€” ط§ظ†ط¸ط± ط£ط¯ظ†ط§ظ‡)
    -- ذ½ذ¾ system_admin ظ„ط§ ظٹط³طھط·ظٹط¹ طھط؛ظٹظٹط± ط¯ظˆط±ظ‡ ظ…ظ† system_admin ط¥ظ„ظ‰ ط£ظ‚ظ„
    IF public.is_system_admin() THEN
        -- ظ…ظ†ط¹ system_admin ظ…ظ† ط®ظپط¶ ط¯ظˆط±ظ‡ ط¹ظ† system_admin (self-protection)
        IF OLD.id = auth.uid() AND NEW.role IS DISTINCT FROM OLD.role THEN
            RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ظ„ط§ ظٹظ…ظƒظ†ظƒ طھط؛ظٹظٹط± ط¯ظˆط±ظƒ ظ…ظ† system_admin';
        END IF;
        RETURN NEW;
    END IF;

    -- ط¥ظ† ظƒط§ظ† ظٹط¹ط±ط¶ طھط¹ط¯ظٹظ„ طµظپ ظ„ظٹط³ ظ…ظ„ظƒظ‡ ظپط؛ظٹط± ظ…ط¯ظٹط± â†’ ط±ظپط¶
    IF OLD.id <> auth.uid()
       AND (v_caller_role IS DISTINCT FROM 'manager') THEN
        RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ظ„ط§ ظٹظ…ظƒظ† طھط¹ط¯ظٹظ„ ظ…ط³طھط®ط¯ظ… ط¢ط®ط±';
    END IF;

    -- ظ„ط§ ظٹظڈط³ظ…ط­ ظ„ط£ط­ط¯ ط¨طھطµط¹ظٹط¯ظ‡ ظ†ظپط³ظ‡ ط¥ظ„ظ‰ system_admin
    IF (NEW.role IS DISTINCT FROM OLD.role)
       AND NEW.role = 'system_admin' THEN
        RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ظ„ط§ ظٹظ…ظƒظ†ظƒ طھطµط¹ظٹط¯ ط¯ظˆط±ظƒ ط¥ظ„ظ‰ system_admin';
    END IF;

    -- ظ„ط§ ظٹظڈط³ظ…ط­ ظ„ط£ط­ط¯ ط¨طھطµط¹ظٹط¯ظ‡ ط£ظٹ ظ…ط³طھط®ط¯ظ… ط¢ط®ط± ط¥ظ„ظ‰ system_admin (manager ظپظ‚ط·)
    IF (NEW.role IS DISTINCT FROM OLD.role)
       AND NEW.role = 'system_admin'
       AND v_caller_role IS DISTINCT FROM 'manager' THEN
        RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ظپظ‚ط· manager ظٹظ…ظƒظ†ظ‡ طھط¹ظٹظٹظ† system_admin';
    END IF;

    -- طھط؛ظٹظٹط± role/farm_id ط§ظ„ط­ط³ط§ط³: ظ„ظ„ظ…ط¯ظٹط± (ظ†ظپط³ ط§ظ„ظ…ط²ط±ط¹ط©) ظپظ‚ط·
    IF (NEW.role IS DISTINCT FROM OLD.role)
       OR (NEW.farm_id IS DISTINCT FROM OLD.farm_id)
       OR (NEW.pin_hash IS DISTINCT FROM OLD.pin_hash) THEN
        IF (v_caller_role IS DISTINCT FROM 'manager') THEN
            RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: طھط؛ظٹظٹط± ط§ظ„ط¯ظˆط±/ط§ظ„ظ…ط²ط±ط¹ط©/ط§ظ„ط±ظ…ط² ظ„ظ„ظ…ط¯ظٹط± ظپظ‚ط·';
        END IF;
        -- ط­طھظ‰ ط§ظ„ظ…ط¯ظٹط± ظ„ط§ ظٹط¹ط¯ظ‘ظ„ ط¥ظ„ط§ ظ…ط³طھط®ط¯ظ…ظٹ ظ…ط²ط±ط¹طھظ‡
        v_target_farm := COALESCE(NEW.farm_id, OLD.farm_id);
        IF v_target_farm IS DISTINCT FROM v_caller_farm THEN
            RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ط§ظ„ظ…ط³طھط®ط¯ظ… ظ„ظٹط³ ظ…ظ† ظ…ط²ط±ط¹طھظƒ';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- 7) admin_create_user: ظٹط¯ط¹ظ… system_admin ظˆظٹط¹ط§ظ…ظ„ system_admin ظƒظ…ط±ط¬ط¹ ط£ط¹ظ„ظ‰
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

    -- system_admin ظٹط³طھط·ظٹط¹ ط¥ظ†ط´ط§ط، ط£ظٹ ط¯ظˆط±
    -- manager ظٹط³طھط·ظٹط¹ ط¥ظ†ط´ط§ط، worker ظپظ‚ط· (ظ„ط§ ظٹط³طھط·ظٹط¹ ط¥ظ†ط´ط§ط، system_admin)
    IF v_caller = 'system_admin' THEN
        -- system_admin: ظ„ط§ ظٹط­طھط§ط¬ طھط­ظ‚ظ‚ farm_id
        IF p_role NOT IN ('worker', 'manager', 'system_admin') THEN
            RAISE EXCEPTION 'ط§ظ„ط¯ظˆط± ط؛ظٹط± طµط§ظ„ط­';
        END IF;
    ELSE
        PERFORM public.assert_current_is_manager_of(p_farm_id::uuid);
        IF p_role NOT IN ('worker', 'manager') THEN
            RAISE EXCEPTION 'ط§ظ„ظ…ط¯ظٹط± ظ„ط§ ظٹظ…ظƒظ†ظ‡ ط¥ظ†ط´ط§ط، system_admin';
        END IF;
    END IF;

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'ط§ظ„ط±ظ…ط² ظٹط¬ط¨ ط£ظ† ظٹظƒظˆظ† 4 ط£ط±ظ‚ط§ظ…';
    END IF;
    IF EXISTS (SELECT 1 FROM users WHERE phone = p_phone) THEN
        RAISE EXCEPTION 'ط±ظ‚ظ… ط§ظ„ظ‡ط§طھظپ ظ…ط³ط¬ظ„ ظ…ط³ط¨ظ‚ط§ظ‹';
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

    INSERT INTO users (id, name, phone, role, pin_hash, farm_id, is_active)
    VALUES (v_auth_uuid, p_name, p_phone, p_role,
            extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
            p_farm_id::uuid, true)
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        phone = EXCLUDED.phone,
        role = EXCLUDED.role,
        pin_hash = EXCLUDED.pin_hash,
        farm_id = EXCLUDED.farm_id,
        is_active = EXCLUDED.is_active
    RETURNING * INTO v_row;

    RETURN to_jsonb(v_row);
END;
$$;

-- 8) admin_update_user: ظٹط¯ط¹ظ… system_admin
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
        -- system_admin: ظ„ط§ ظٹط­طھط§ط¬ طھط­ظ‚ظ‚ farm_id
        IF p_role IS NOT NULL AND p_role NOT IN ('worker', 'manager', 'system_admin') THEN
            RAISE EXCEPTION 'ط§ظ„ط¯ظˆط± ط؛ظٹط± طµط§ظ„ط­';
        END IF;
    ELSE
        PERFORM public.assert_current_is_manager_of(v_target_farm);
        IF p_role IS NOT NULL AND p_role NOT IN ('worker', 'manager') THEN
            RAISE EXCEPTION 'ط§ظ„ظ…ط¯ظٹط± ظ„ط§ ظٹظ…ظƒظ†ظ‡ طھط¹ظٹظٹظ† system_admin';
        END IF;
    END IF;

    IF p_phone IS NOT NULL AND EXISTS (SELECT 1 FROM users WHERE phone = p_phone AND id <> p_uid::uuid) THEN
        RAISE EXCEPTION 'ط±ظ‚ظ… ط§ظ„ظ‡ط§طھظپ ظ…ط³ط¬ظ„ ظ…ط³ط¨ظ‚ط§ظ‹';
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

-- 9) admin_reset_pin: ظٹط¯ط¹ظ… system_admin
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
        RAISE EXCEPTION 'ط§ظ„ط±ظ…ط² ظٹط¬ط¨ ط£ظ† ظٹظƒظˆظ† 4 ط£ط±ظ‚ط§ظ…';
    END IF;
    v_caller := public.current_user_role();
    SELECT farm_id INTO v_target_farm FROM users WHERE id = p_uid::uuid;

    IF v_caller = 'system_admin' THEN
        NULL; -- system_admin: ظٹطھط¬ط§ظˆط² طھط­ظ‚ظ‚ ط§ظ„ظ…ط²ط±ط¹ط©
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

-- 10) admin_delete_user: ظٹط¯ط¹ظ… system_admin
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
        NULL; -- system_admin: ظٹطھط¬ط§ظˆط² طھط­ظ‚ظ‚ ط§ظ„ظ…ط²ط±ط¹ط©
    ELSE
        PERFORM public.assert_current_is_manager_of(v_target_farm);
    END IF;

    IF p_uid::uuid = auth.uid() THEN
        RAISE EXCEPTION 'ظ„ط§ ظٹظ…ظƒظ†ظƒ ط­ط°ظپ ط­ط³ط§ط¨ظƒ ط§ظ„ط­ط§ظ„ظٹ';
    END IF;
    DELETE FROM auth.users WHERE auth.users.id = p_uid::uuid;
END;
$$;

-- 11) find_user_by_phone: ظٹظپط­طµ is_active
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

-- 12) create_farm_with_manager: RPC transactional
-- ظٹظ†ط´ط¦ ظ…ط¯ط¬ظ†ط© + ظ…ط¯ظٹط±ظ‡ط§ ظپظٹ ظ…ط¹ط§ظ…ظ„ط© ظˆط§ط­ط¯ط©
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
    -- ظپظ‚ط· system_admin ط£ظˆ ط§ظ„ظ…ط¯ظٹط± ط§ظ„ط£ظˆظ„ (bootstrap) ظٹظ…ظƒظ†ظ‡ ط¥ظ†ط´ط§ط، ظ…ط¯ط¬ظ†ط©
    IF NOT public.is_system_admin() THEN
        -- ط§ظ„ظ…ط¯ظٹط± ط§ظ„ط¹ط§ط¯ظٹ ظ„ط§ ظٹط³طھط·ظٹط¹ ط¥ظ†ط´ط§ط، ظ…ط¯ط¬ظ†ط© ط¬ط¯ظٹط¯ط©
        RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ظپظ‚ط· system_admin ظٹظ…ظƒظ†ظ‡ ط¥ظ†ط´ط§ط، ظ…ط¯ط¬ظ†ط© ط¬ط¯ظٹط¯ط©';
    END IF;

    IF p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'ط§ظ„ط±ظ…ط² ظٹط¬ط¨ ط£ظ† ظٹظƒظˆظ† 4 ط£ط±ظ‚ط§ظ…';
    END IF;

    IF EXISTS (SELECT 1 FROM users WHERE phone = p_phone) THEN
        RAISE EXCEPTION 'ط±ظ‚ظ… ط§ظ„ظ‡ط§طھظپ ظ…ط³ط¬ظ„ ظ…ط³ط¨ظ‚ط§ظ‹';
    END IF;

    -- ط¥ظ†ط´ط§ط، ط§ظ„ظ…ط²ط±ط¹ط©
    INSERT INTO farms (name, location)
    VALUES (p_farm_name, NULLIF(p_location, ''))
    RETURNING id INTO v_farm_id;

    -- ط¥ظ†ط´ط§ط، ط­ط³ط§ط¨ auth
    v_user_id := gen_random_uuid();

    INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data,
        confirmation_token, recovery_token
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
        '', ''
    );

    INSERT INTO auth.identities (
        provider_id, user_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
    ) VALUES (
        v_user_id::text, v_user_id,
        jsonb_build_object('sub', v_user_id::text),
        'email', NOW(), NOW(), NOW()
    );

    -- ط¥ظ†ط´ط§ط، ط³ط¬ظ„ ط§ظ„ظ…ط³طھط®ط¯ظ…
    INSERT INTO users (id, name, phone, role, pin_hash, farm_id, is_active)
    VALUES (
        v_user_id, p_manager_name, p_phone, 'manager',
        extensions.crypt(public.app_password_from_pin(p_pin), extensions.gen_salt('bf')),
        v_farm_id, true
    );

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
-- SECTION 3: RLS SYSTEM ADMIN (20260902_002)
-- ============================================================
-- ============================================================
-- Migration 20260902_002: RLS system_admin bypass
-- ط§ظ„ظ‚ط§ط¹ط¯ط©: system_admin â†’ ظƒظ„ ط§ظ„ظ…ط¯ط§ط¬ظ† | manager â†’ ظپظ„ط¯ظٹ ظپظ‚ط· | worker â†’ ظپظ„ط¯ظٹ ظپظ‚ط·
-- ============================================================

-- ============================================================
-- a) ط¯ظˆط§ظ„ ط³ظٹط§ط³ط© ظ…ظˆط­ط¯ط©: طھظڈط³طھط®ط¯ظ… ط¹ط¨ط± ensure_operational_policies
-- ============================================================

-- طھط£ظƒط¯ ط£ظ† is_system_admin() ظ…طھط§ط­ط© (ط£ظڈظ†ط´ط¦طھ ظپظٹ migration 001)

-- ============================================================
-- b) farms: system_admin = ظƒظ„ ط´ظٹط،طŒ manager = ظپظ„ط¯ظٹ ظپظ‚ط·
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

-- ============================================================
-- c) users: system_admin = ظƒظ„ ط§ظ„ظ…ط³طھط®ط¯ظ…ظٹظ†طŒ manager = ظ…ط³طھط®ط¯ظ…ظٹ ظ…ط²ط±ط¹طھظ‡
-- ============================================================
DROP POLICY IF EXISTS users_select_self ON users;
CREATE POLICY users_select_self ON users
    FOR SELECT TO authenticated
    USING (
        id = auth.uid()
        OR is_system_admin()
        OR (
            current_user_role() = 'manager'
            AND farm_id = current_user_farm_id()
        )
    );

DROP POLICY IF EXISTS users_select_same_farm ON users;
-- (طھظ… ط¯ظ…ط¬ظ‡ط§ ط£ط¹ظ„ط§ظ‡ ظپظٹ users_select_self â€” ظ„ط§ ط­ط§ط¬ط© ظ„ط³ظٹط§ط³ط© ظ…ظ†ظپطµظ„ط©)

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
            AND farm_id = current_user_farm_id()
        )
    );

-- ============================================================
-- d) ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹط©: system_admin ظٹطھط¬ط§ظˆط² ط¹ط²ظ„ farm_id
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
    EXECUTE format('CREATE POLICY op_select ON %I FOR SELECT TO authenticated USING (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_insert ON %I FOR INSERT TO authenticated WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_update ON %I FOR UPDATE TO authenticated USING (is_system_admin() OR farm_id = current_user_farm_id()) WITH CHECK (is_system_admin() OR farm_id = current_user_farm_id())', p_table);
    EXECUTE format('CREATE POLICY op_delete ON %I FOR DELETE TO authenticated USING ((is_system_admin() OR farm_id = current_user_farm_id()) AND (is_system_admin() OR current_user_role() = ''manager''))', p_table);
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
-- e) ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„ظ…ط§ظ„ظٹط©: system_admin + manager
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
-- audit_log: NOT ط¹ط¨ط± ensure_manager_policies (append-onlyطŒ ظƒطھط§ط¨ط© ط­طµط±ظٹط© ط¹ط¨ط± trigger)
DROP POLICY IF EXISTS mgr_all ON audit_log;

-- inventory_transactions
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
-- f) medicines_catalog
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

-- ============================================================
-- g) app_settings
-- ============================================================
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

-- ============================================================
-- h) app_notifications
-- ============================================================
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

-- ============================================================
-- i) dispatch_requests
-- ============================================================
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

-- ============================================================
-- j) sync_changes: system_admin ظٹط³طھط·ظٹط¹ ظ‚ط±ط§ط،ط© ظƒظ„ ط§ظ„طھط؛ظٹظٹط±ط§طھ
-- ============================================================
DROP POLICY IF EXISTS sync_changes_select ON sync_changes;
CREATE POLICY sync_changes_select ON sync_changes
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR farm_id = current_user_farm_id()
    );

-- ============================================================
-- k) audit_log: system_admin ظٹط±ظ‰ ظƒظ„ ط´ظٹط،
-- ============================================================
DROP POLICY IF EXISTS audit_select_manager ON audit_log;
CREATE POLICY audit_select_manager ON audit_log
    FOR SELECT TO authenticated
    USING (
        is_system_admin()
        OR (
            farm_id = current_user_farm_id()
            AND current_user_role() = 'manager'
        )
    );

-- (19) ط­ظ…ط§ظٹطھظ‡ append-only: ظ†ظڈط³ظ‚ط· ط£ظٹ ط³ظٹط§ط³ط© INSERT/UPDATE/DELETE ظ„ط£ظٹ ظ…ط³طھط®ط¯ظ….
-- ط³ط¬ظ„ط§طھ ط§ظ„طھط¯ظ‚ظٹظ‚ طھظڈظ†ط´ط£ ط­طµط±ظٹط§ظ‹ ط¹ط¨ط± trigger (SECURITY DEFINER) ظˆظ„ظٹط³طھ طھط·ط¨ظٹظ‚ظٹط©.
DROP POLICY IF EXISTS audit_insert_manager ON audit_log;
DROP POLICY IF EXISTS audit_insert_system ON audit_log;

-- ============================================================
-- l) GRANT ظ„ظ„ط¯ظˆط§ظ„ ط§ظ„ط¬ط¯ظٹط¯ط©
-- ============================================================
GRANT EXECUTE ON FUNCTION public.is_system_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_farm_with_manager(text, text, text, text, text) TO authenticated;

-- ============================================================
-- m)_admin_select_all_users: RPC ظ„ط¬ظ„ط¨ ظƒظ„ ط§ظ„ظ…ط³طھط®ط¯ظ…ظٹظ† (ظ„ظ€ system_admin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_select_all_users()
RETURNS SETOF users
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    -- ظپظ‚ط· system_admin ظٹظ…ظƒظ†ظ‡ ط¬ظ„ط¨ ظƒظ„ ط§ظ„ظ…ط³طھط®ط¯ظ…ظٹظ†
    SELECT u.*
    FROM public.users u
    WHERE public.is_system_admin()
    ORDER BY u.created_at;
$$;

GRANT EXECUTE ON FUNCTION public.admin_select_all_users() TO authenticated;

-- admin_select_all_farms: RPC ظ„ط¬ظ„ط¨ ظƒظ„ ط§ظ„ظ…ط¯ط§ط¬ظ† (ظ„ظ€ system_admin)
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
-- SECTION 4: MORTALITY ATOMICITY (20260902_003)
-- ============================================================
-- ============================================================
-- Migration 20260902_003: Atomic mortality + lock flock_id
-- ============================================================

-- 1) طھط­ط¯ظٹط« atomic: ط­ظ…ط§ظٹط© current_count ظ…ظ† race conditions
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
        -- ط­ظ…ط§ظٹط© ط°ط±ظٹط©: ظ†ظ†ظ‚طµ ط§ظ„ط¹ط¯ط¯ ظپظ‚ط· ط¥ط°ط§ ظƒط§ظ† ظƒط§ظپظٹط§ظ‹
        UPDATE flocks
        SET current_count = current_count - NEW.count, updated_at = NOW()
        WHERE id = NEW.flock_id
          AND current_count >= NEW.count;

        GET DIAGNOSTICS v_affected = ROW_COUNT;
        IF v_affected = 0 THEN
            RAISE EXCEPTION 'ط¹ط¯ط¯ ط§ظ„ظ†ظپظˆظ‚ (%) ظٹطھط¬ط§ظˆط² ط§ظ„ط¹ط¯ط¯ ط§ظ„ط­ط§ظ„ظٹ ظپظٹ ط§ظ„ظ‚ط·ظٹط¹', NEW.count;
        END IF;

    ELSIF TG_OP = 'UPDATE' THEN
        -- ط­ظ…ط§ظٹط© flock_id ظ…ظ† ط§ظ„طھط¹ط¯ظٹظ„ ط¨ط¹ط¯ ط§ظ„ط¥ظ†ط´ط§ط،
        IF NEW.flock_id IS DISTINCT FROM OLD.flock_id THEN
            RAISE EXCEPTION 'ظ„ط§ ظٹظ…ظƒظ† طھط؛ظٹظٹط± ط§ظ„ظ‚ط·ظٹط¹ ط¨ط¹ط¯ ط¥ظ†ط´ط§ط، ط³ط¬ظ„ ط§ظ„ظ†ظپظˆظ‚';
        END IF;

        -- soft delete: ط§ط³طھط±ط¬ط§ط¹ ط§ظ„ط¹ط¯ط¯
        IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            UPDATE flocks
            SET current_count = current_count + OLD.count, updated_at = NOW()
            WHERE id = OLD.flock_id;
        ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
            -- ط¥ط¹ط§ط¯ط© طھظپط¹ظٹظ„: ظ†ظ†ظ‚طµ ط§ظ„ط¹ط¯ط¯ ط°ط±ظٹط§ظ‹
            UPDATE flocks
            SET current_count = current_count - NEW.count, updated_at = NOW()
            WHERE id = NEW.flock_id
              AND current_count >= NEW.count;

            GET DIAGNOSTICS v_affected = ROW_COUNT;
            IF v_affected = 0 THEN
                RAISE EXCEPTION 'ط§ظ„ط¹ظˆط¯ط© ظ…ظ† ط§ظ„ط­ط°ظپ: ط§ظ„ط¹ط¯ط¯ ط§ظ„ظ…ط·ظ„ظˆط¨ (%) ظٹطھط¬ط§ظˆط² ط§ظ„ط­ط§ظ„ظٹ', NEW.count;
            END IF;
        ELSE
            v_delta := NEW.count - OLD.count;

            IF v_delta > 0 THEN
                -- ط²ظٹط§ط¯ط©: ظ†ظ†ظ‚طµ ط§ظ„ظپط±ظ‚ ط°ط±ظٹط§ظ‹
                UPDATE flocks
                SET current_count = current_count - v_delta, updated_at = NOW()
                WHERE id = NEW.flock_id
                  AND current_count >= v_delta;

                GET DIAGNOSTICS v_affected = ROW_COUNT;
                IF v_affected = 0 THEN
                    RAISE EXCEPTION 'ط§ظ„طھط¹ط¯ظٹظ„ ط³ظٹط¤ط¯ظٹ ظ„ط¹ط¯ط¯ ط³ط§ظ„ط¨ (ط§ظ„ظپط±ظ‚: %)', v_delta;
                END IF;
            ELSIF v_delta < 0 THEN
                -- ط¥ظ†ظ‚ط§طµ (ط§ط³طھط±ط¬ط§ط¹ ط¹ط¯ط¯)
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

-- 2) ط­ظ…ط§ظٹط© inventory_items.quantity ظ…ظ† ط§ظ„ظƒطھط§ط¨ط© ط§ظ„ظ…ط¨ط§ط´ط±ط© ط¹ط¨ط± sync
-- ط§ظ„ط±طµظٹط¯ ظٹظڈط­ط³ط¨ ظپظ‚ط· ظ…ظ† inventory_transactions
-- ظ†ط¶ظٹظپ trigger ظٹظ…ظ†ط¹ ط§ظ„ظƒطھط§ط¨ط© ط§ظ„ظ…ط¨ط§ط´ط±ط© ظ„ظ€ quantity ط¹ط¨ط± sync_records_batch
CREATE OR REPLACE FUNCTION public.protect_inventory_quantity()
RETURNS TRIGGER AS $$
BEGIN
    -- ط§ظ„ط³ظ…ط§ط­ ط¨ط§ظ„طھط¹ط¯ظٹظ„ ظپظ‚ط· ط¹ط¨ط± ط§ظ„ظ…ط¹ط§ظ…ظ„ط§طھ (inventory_transactions)
    -- ط£ظˆ ط¹ط¨ط± ط§ظ„ط¯ظˆط§ظ„ SECURITY DEFINER (admin functions)
    -- ظٹظ…ظ†ط¹ sync ظ…ظ† ظپط±ط¶ quantity ظ…ط¨ط§ط´ط±
    IF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
        -- ظ„ط§ ظ†ط³ظ…ط­ ط¨ط§ظ„طھط¹ط¯ظٹظ„ ط§ظ„ظ…ط¨ط§ط´ط± â€” ظٹظڈط­ط³ط¨ ظ…ظ† Transactions
        RAISE EXCEPTION 'ظ„ط§ ظٹظ…ظƒظ† طھط¹ط¯ظٹظ„ ط§ظ„ط±طµظٹط¯ ظ…ط¨ط§ط´ط±ط©. ط§ط³طھط®ط¯ظ… ظ…ط¹ط§ظ…ظ„ط§طھ ط§ظ„ظ…ط®ط²ظˆظ†';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- طھظپط¹ظٹظ„ ط§ظ„ط­ظ…ط§ظٹط© ط¹ظ„ظ‰ inventory_items
-- (ظٹط¬ط¨ ط£ظ† ظ„ط§ ظٹظڈظپط¹ظ‘ظ„ ظ‡ط°ط§ ط¹ظ„ظ‰ sync_records_batch ظ„ط£ظ†ظ‡ط§ SECURITY DEFINER)
-- ظ†ظڈظپط¹ظ‘ظ„ظ‡ ظپظ‚ط· ظƒط­ظ…ط§ظٹط© ط¹ط§ظ…ط© â€” ط§ظ„ط¯ظˆط§ظ„ SECURITY DEFINER طھطھط¬ط§ظˆط²ظ‡
DROP TRIGGER IF EXISTS trg_protect_inventory_quantity ON inventory_items;
CREATE TRIGGER trg_protect_inventory_quantity
    BEFORE UPDATE ON inventory_items
    FOR EACH ROW EXECUTE FUNCTION public.protect_inventory_quantity();


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
-- SECTION 5: INVENTORY/PAYMENTS VERSION (20260904_004)
-- ============================================================
-- ============================================================
-- Migration 20260904_004: inventory_items + payments version (OCC)
-- ============================================================
-- ط¥ط¶ط§ظپط© ط¹ظ…ظˆط¯ version ظ„ط¹ظ†ط§طµط± ط§ظ„ظ…ط®ط²ظˆظ† ظ„ط¯ط¹ظ… OCC ظپظٹ sync_records_batch.
-- (ظ…ظ† ظ‚ط¨ظ„ ظ„ظ… ظٹظƒظ† ظ„ظ„ط¬ط¯ظˆظ„ ط¹ظ…ظˆط¯ versionطŒ ظپظƒط§ظ†طھ ظ…ط­ط§ظˆظ„ط© update ط¹ط¨ط±
--  sync_records_batch طھظپط´ظ„ ط¨ط®ط·ط£ "column version does not exist").

-- 1) inventory_items.version
ALTER TABLE inventory_items
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;

-- 2) payments.version (طھط£ظƒظٹط¯ â€” ظ‚ط¯ ظٹظƒظˆظ† ظ…ظˆط¬ظˆط¯ط§ظ‹)
ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;


-- ============================================================
-- SECTION 6: SYNC PERMISSIONS & HEALTH (20260904_005)
-- ============================================================
-- ============================================================
-- Migration 20260904_005: طھظˆط­ظٹط¯ طµظ„ط§ط­ظٹط§طھ ط§ظ„ظ…ط²ط§ظ…ظ†ط© + طµط­ط© ط§ظ„ظ…ط²ط§ظ…ظ†ط©
-- ============================================================
-- ظٹط¶ظٹظپ:
--   1) sync_can_write(role,table)  â€” ظ…طµظپظˆظپط© طµظ„ط§ط­ظٹط§طھ ظƒطھط§ط¨ط© ظ…ط±ظƒط²ظٹط© (ظƒط§ظ†طھ NOT IN ظ…ط¨ط¹ط«ط±ط©)
--   2) sync_can_read(role,table)   â€” ظ…طµظپظˆظپط© طµظ„ط§ط­ظٹط§طھ ظ‚ط±ط§ط،ط©/ط³ط­ط¨ ظ…ط±ظƒط²ظٹط©
--   3) admin_sync_health()         â€” طµط­ط© ظ…ط²ط§ظ…ظ†ط© ظƒظ„ ط§ظ„ظ…ط¯ط§ط¬ظ† (ظ„ظ€ system_admin)
--
-- ظ…ظ„ط§ط­ط¸ط©: ط§ظ„ظ€ migrations ط§ظ„طھط§ظ„ظٹط© (source SQL) ط£ظڈط¹ظٹط¯ ظƒطھط§ط¨ط© ط§ظ„ظپظˆظ†ظƒطھظٹظ†
-- sync_records_batch ظˆ pull_remote_changes ظ„ط§ط³طھط®ط¯ط§ظ… ظ‡ط§طھظٹظ† ط§ظ„ط¯ط§ظ„طھظٹظ† ط§ظ„ظ…ط±ظƒط²ظٹطھظٹظ†.
-- ظٹط¬ط¨ طھط·ط¨ظٹظ‚ ظ‡ط°ط§ ط§ظ„ظ…ظ„ظپ ظ‚ط¨ظ„/ط¨ط¹ط¯ ظ†ط´ط± ط§ظ„ظ€ rework ظ„ظ„ظپظˆظ†ظƒطھظٹظ† ظ…ط¹ط§ظ‹.
-- ============================================================

-- 1) sync_can_write
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

-- 2) sync_can_read
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

-- 3) admin_sync_health
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
        RAISE EXCEPTION 'ط؛ظٹط± ظ…طµط±ط­: ظ‡ط°ظ‡ ط§ظ„ط¨ظٹط§ظ†ط§طھ ظ„ظ€ system_admin ظپظ‚ط·';
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
-- 4) sync_records_batch â€” ظ†ط³ط®ط© ظ…ظڈط¹ط§ط¯ ظƒطھط§ط¨طھظ‡ط§ طھط³طھط®ط¯ظ… sync_can_write
--    (ظ…طµظپظˆظپط© ط§ظ„طµظ„ط§ط­ظٹط§طھ ط§ظ„ظ…ط±ظƒط²ظٹط©) ط¨ط¯ظ„ط§ظ‹ ظ…ظ† NOT IN ط§ظ„ظ…ط¨ط¹ط«ط±ط© ظ„ظƒظ„ ط¯ظˆط±.
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
    -- طھط¹ط·ظٹظ„ ط§ظ„ظ€ trigger ط§ظ„ظ…ظڈظˆظ„ظگظ‘ط¯ ظ„ظ€ sync_changes ط£ط«ظ†ط§ط، ط§ظ„ط¯ظپط¹ط©
    -- ظ„ظ…ظ†ط¹ ط§ظ„طھظƒط±ط§ط± (ط§ظ„ط¹ظ…ظ„ظٹط§طھ طھظڈظƒطھط¨ ط¹ط¨ط± sync_records_batch ظˆظ„ط§ ط­ط§ط¬ط© ظ„طھظƒط±ط§ط±ظ‡ط§)
    PERFORM set_config('app.skip_sync_trigger', 'on', true);

    v_user_farm := public.current_user_farm_id();
    v_user_role := public.current_user_role();
    IF v_user_farm IS NULL THEN
        RAISE EXCEPTION 'ظ„ط§ ظٹظ…ظƒظ† طھط­ط¯ظٹط¯ ط§ظ„ظ…ط²ط±ط¹ط© ظ„ظ„ظ…ط³طھط®ط¯ظ… ط§ظ„ط­ط§ظ„ظٹ';
    END IF;

    FOR v_record IN SELECT * FROM jsonb_array_elements(p_records)
    LOOP
        v_table_name  := v_record->>'table_name';
        v_record_id   := (v_record->>'record_id')::uuid;
        v_operation   := v_record->>'operation';
        v_operation_id := v_record->>'operation_id';
        v_data        := v_record->>'data';

        -- (19) طھظ…ط±ظٹط± device_id/correlation_id ط¥ظ„ظ‰ GUC ظ„ظٹظ‚ط±ط£ظ‡ط§ audit trigger
        -- (null-safe: ط¥ط°ط§ ظ„ظ… طھظڈط±ط³ظ„ طھط¨ظ‚ظ‰ طھظ„ظ‚ط§ط¦ظٹط§طھ NULL).
        PERFORM set_config('app.device_id', COALESCE(v_record->>'device_id', ''), true);
        PERFORM set_config('app.correlation_id', COALESCE(v_record->>'correlation_id', ''), true);

        IF v_data IS NULL THEN
            v_data := '{}'::jsonb;
        END IF;

        -- Idempotency check: ط¥ط°ط§ طھظ… طھظ†ظپظٹط° ط§ظ„ط¹ظ…ظ„ظٹط© ظ…ط³ط¨ظ‚ط§ظ‹ ط¨ظˆط§ط³ط·ط© ظ‡ط°ط§ ط§ظ„ظ…ط³طھط®ط¯ظ…
        -- ظˆظ†ظپط³ ط§ظ„طµظپ/ط§ظ„ط¬ط¯ظˆظ„/ط§ظ„ط¹ظ…ظ„ظٹط©طŒ ط£ط±ط¬ط¹ ط§ظ„ظ†طھظٹط¬ط© ط§ظ„ظ…ط­ظپظˆط¸ط©.
        -- P0: ظ†ط·ط§ظ‚ ط§ظ„ظ€ operation_id = (ط§ظ„ظ…ط³طھط®ط¯ظ… + ط§ظ„ظ…ط²ط±ط¹ط© + ط§ظ„طµظپ + ط§ظ„ط¬ط¯ظˆظ„ + ط§ظ„ط¹ظ…ظ„ظٹط©)
        -- ط­طھظ‰ ظ„ط§ ظٹظڈط¹ط§ط¯ ط§ط³طھط¹ظ…ط§ظ„ operation_id ظ…ط³ط±ظژظ‘ط¨ ظ…ظ† ظ…ط³طھط®ط¯ظ…/طµظپ ط¢ط®ط±طŒ
        -- ظˆظٹظڈط±ظپط¶ ط¥ط¹ط§ط¯ط© ط§ط³طھط®ط¯ط§ظ… ظ†ظپط³ operation_id ظ…ط¹ ط¹ظ…ظ„ظٹط© ظ…ط®طھظ„ظپط©.
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

                -- ظ†ظپط³ operation_id ظ…ظˆط¬ظˆط¯ ظ„ظƒظ† ط¨طھظˆظ‚ظٹط¹ ظ…ط®طھظ„ظپ (ظ…ط³طھط®ط¯ظ…/طµظپ/ط¹ظ…ظ„ظٹط© ط£ط®ط±ظ‰)
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
                        'message', 'operation_id ظ…ط³طھط®ط¯ظ… ط¨ط§ظ„ظپط¹ظ„ ظ„ط¹ظ…ظ„ظٹط© ط£ط®ط±ظ‰'
                    );
                    CONTINUE;
                END IF;
            END;
        END IF;

        -- ط¬ط¯ط§ظˆظ„ ظ…ط­ط¸ظˆط±ط© ظ†ظ‡ط§ط¦ظٹط§ظ‹: ظ„ط§ ظٹط¬ظˆط² ظ„ط£ظٹ ط¯ظˆط± ظ…ط²ط§ظ…ظ†طھظ‡ط§ ط¹ط¨ط± RPC
        IF v_table_name IN ('users', 'farms') THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'status', 'error',
                'message', 'ط¬ط¯ظˆظ„ ظ…ظ…ظ†ظˆط¹ ظ„ظ„ظ…ط²ط§ظ…ظ†ط© ط¹ط¨ط± RPC: ' || v_table_name
            );
            CONTINUE;
        END IF;

        -- Role-based whitelist: ظ…طµظپظˆظپط© طµظ„ط§ط­ظٹط§طھ ظ…ط±ظƒط²ظٹط© ظˆط§ط­ط¯ط© ط¹ط¨ط± sync_can_write.
        -- طھظڈط­ظ„ظ‘ ظ…ط­ظ„ ط§ظ„ظ€ NOT IN ط§ظ„ظ…ط¨ط¹ط«ط±ط© ط§ظ„ط³ط§ط¨ظ‚ط© ظ„ظƒظ„ ط¯ظˆط± ط¹ظ„ظ‰ ط­ط¯ط©.
        -- P0: ط§ظ„ط¹ط§ظ…ظ„ ظ„ط§ ظٹطµظ„ط­ ط¥ظ„ط§ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹط© (ظٹط³طھط¨ط¹ط¯ customers/flocks/ط§ظ„ظ…ط§ظ„ظٹط©).
        IF NOT public.sync_can_write(v_user_role, v_table_name) THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'status', 'error',
                'message', 'ط§ظ„ط¯ظˆط± ط§ظ„ط­ط§ظ„ظٹ ظ„ط§ ظٹظ…ظ„ظƒ طµظ„ط§ط­ظٹط© ط§ظ„ظ…ط²ط§ظ…ظ†ط© ظ„ظ„ط¬ط¯ظˆظ„: ' || v_table_name
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
                    'message', 'ط§ظ„ط³ط¬ظ„ ط؛ظٹط± ظ…ظˆط¬ظˆط¯ ط£ظˆ ظ„ط§ ظٹظ†طھظ…ظٹ ظ„ظ„ظ…ط²ط±ط¹ط©'
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

        -- P0: ظ…ظ„ظƒظٹط© ط§ظ„ط³ط¬ظ„ â€” ط§ظ„ط¹ط§ظ…ظ„ ظ„ط§ ظٹط¹ط¯ظ‘ظ„/ظٹط­ط°ظپ ط¥ظ„ط§ ط³ط¬ظ„ط§طھظ‡ ظ‡ظˆ.
        -- (ط§ظ„ظ…ط¯ظٹط±/ط§ظ„ظ…ط´ط±ظپ ط؛ظٹط± ظ…ظ‚ظٹط¯ظٹظ† ط¨ط§ظ„ظ…ظ„ظƒظٹط© ط¶ظ…ظ† ط§ظ„ظ…ط²ط±ط¹ط©).
        IF v_user_role = 'worker' AND v_operation IN ('update', 'delete') THEN
            IF (v_existing_record->>'worker_id') IS DISTINCT FROM auth.uid()::text THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'status', 'error',
                    'message', 'ط؛ظٹط± ظ…طµط±ط­: ظ„ط§ ظٹظ…ظƒظ† طھط¹ط¯ظٹظ„/ط­ط°ظپ ط³ط¬ظ„ ظ„ظٹط³ ظ…ظ† ط¥ظ†ط´ط§ط¦ظƒ'
                );
                CONTINUE;
            END IF;
        END IF;

        -- P0/2: ظ…طµظپظˆظپط© طµظ„ط§ط­ظٹط§طھ ظ…ظˆط­ط¯ط© ظ…ط¹ RLS â€” ط§ظ„ط­ط°ظپ ظ„ظ„ظ…ط¯ظٹط± ظپظ‚ط· ظپظٹ ظƒظ„ ط§ظ„ط·ط¨ظ‚ط§طھ.
        -- (RLS: op_delete â†’ current_user_role()='manager'ط› ظˆظ‡ظ†ط§ ظ…ط«ظ„ظ‡ط§ طھظ…ط§ظ…ط§ظ‹)
        IF v_operation = 'delete' AND v_user_role <> 'manager' THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'status', 'error',
                'message', 'ط؛ظٹط± ظ…طµط±ط­: ط§ظ„ط­ط°ظپ ظ„ظ„ظ…ط¯ظٹط± ظپظ‚ط·'
            );
            CONTINUE;
        END IF;

        -- column whitelist ظ„ظƒظ„ ط¬ط¯ظˆظ„
        CASE v_table_name
            WHEN 'egg_production' THEN v_allowed_cols := ARRAY['flock_id','date','cartons','trays','loose_eggs','broken_eggs','dirty_eggs','tray_weight_kg','section_no','worker_id'];
            WHEN 'mortality' THEN v_allowed_cols := ARRAY['flock_id','date','count','reason','reason_other','notes','image_url','worker_id','section_no'];
            WHEN 'feed_consumption' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','bags_count','quantity_kg','worker_id','section_no'];
            WHEN 'feed_received' THEN v_allowed_cols := ARRAY['date','entry_mode','quantity','quantity_kg','feed_type','supplier','invoice_number','notes','price_per_kg','section_no','worker_id'];
            WHEN 'egg_dispatch' THEN v_allowed_cols := ARRAY['date','customer_id','cartons','trays','tray_weight_kg','notes','payment_status','worker_id'];
            WHEN 'medications' THEN v_allowed_cols := ARRAY['flock_id','date','type','medicine_name','dosage','administration_route','treatment_days','withdrawal_days','notes','worker_id'];
            WHEN 'customers' THEN v_allowed_cols := ARRAY['name','phone','notes'];
            WHEN 'flocks' THEN v_allowed_cols := ARRAY['breed','start_date','initial_count','status','sections_count'];
            WHEN 'expenses' THEN v_allowed_cols := ARRAY['date','category','description','amount'];
            WHEN 'inventory_items' THEN v_allowed_cols := ARRAY['name','unit','low_stock_threshold','notes'];
            WHEN 'inventory_transactions' THEN v_allowed_cols := ARRAY['item_id','date','type','quantity','note','user_id'];
            WHEN 'opening_balances' THEN v_allowed_cols := ARRAY['flock_id','eggs_produced','eggs_dispatched','feed_consumed_kg','initial_birds','mortality_count','total_payments','total_revenues','sections'];
            WHEN 'payments' THEN v_allowed_cols := ARRAY['dispatch_id','customer_id','date','price_per_carton','total_due','amount_paid','payment_method','due_date','notes','manager_id'];
            ELSE v_allowed_cols := ARRAY[]::text[];
        END CASE;

        -- P0: ظ…ظ†ط¹ ط§ظ„ط¹ط§ظ…ظ„/ط§ظ„ظ…ط´ط±ظپ ظ…ظ† طھط¹ط¯ظٹظ„ ط§ظ„ط£ط¹ظ…ط¯ط© ط§ظ„ط­ط³ظ‘ط§ط³ط© (ظ…ط§ظ„ظٹط©/ط£ط³ط¹ط§ط±/ط­ط§ظ„ط© ظ…ط­ط§ط³ط¨ظٹط©)
        -- ط­طھظ‰ ظپظٹ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹط©. ظˆظƒط°ظ„ظƒ ظ…ظ†ط¹ طھط؛ظٹظٹط± ظ…ظ„ظƒظٹط© ط§ظ„ط³ط¬ظ„ (worker_id).
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

        -- P0/1: ط§ظ„طھظƒط§ظ…ظ„ ط§ظ„ظ…ط±ط¬ط¹ظٹ ط¹ط¨ط± ط§ظ„ظ…ط²ط±ط¹ط© â€” ط£ظٹ ط¹ظ…ظˆط¯ ط¹ظ„ظ†ظٹ (foreign key) ظپظٹ ط§ظ„ط­ظ…ظˆظ„ط©
        -- ظٹط¬ط¨ ط£ظ† ظٹط´ظٹط± ظ„طµظپ ط¯ط§ط®ظ„ ظ†ظپط³ ظ…ط²ط±ط¹ط© ط§ظ„ظ…ط³طھط®ط¯ظ…طŒ ظˆط¥ظ„ط§ Rظپط¶ظŒ طµط±ظٹط­.
        -- ظ„ط§ ظ†ط¹طھظ…ط¯ ط¹ظ„ظ‰ FK ظˆط­ط¯ظ‡ (ط§ظ„ظˆط¬ظˆط¯ ظ„ط§ ظٹط¹ظ†ظٹ ظ†ظپط³ ط§ظ„ظ…ط²ط±ط¹ط©).
        IF v_operation IN ('insert', 'update') THEN
            IF v_table_name = 'egg_dispatch' AND (v_data ? 'customer_id') THEN
                IF NOT EXISTS (SELECT 1 FROM customers WHERE id = (v_data->>'customer_id')::uuid AND farm_id = v_user_farm) THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id, 'status', 'error',
                        'message', 'customer_id ظ„ط§ ظٹظ†طھظ…ظٹ ظ„ظ…ط²ط±ط¹طھظƒ'
                    );
                    CONTINUE;
                END IF;
            END IF;

            IF v_table_name IN ('egg_production', 'mortality', 'feed_consumption', 'medications', 'opening_balances')
               AND (v_data ? 'flock_id') AND (v_data->>'flock_id') IS NOT NULL AND (v_data->>'flock_id') <> 'null' THEN
                IF NOT EXISTS (SELECT 1 FROM flocks WHERE id = (v_data->>'flock_id')::uuid AND farm_id = v_user_farm) THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id, 'status', 'error',
                        'message', 'flock_id ظ„ط§ ظٹظ†طھظ…ظٹ ظ„ظ…ط²ط±ط¹طھظƒ'
                    );
                    CONTINUE;
                END IF;
            END IF;

            IF v_table_name = 'inventory_transactions' AND (v_data ? 'item_id') THEN
                IF NOT EXISTS (SELECT 1 FROM inventory_items WHERE id = (v_data->>'item_id')::uuid AND farm_id = v_user_farm) THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id, 'status', 'error',
                        'message', 'item_id ظ„ط§ ظٹظ†طھظ…ظٹ ظ„ظ…ط²ط±ط¹طھظƒ'
                    );
                    CONTINUE;
                END IF;
            END IF;
        END IF;

        BEGIN
            IF v_operation = 'insert' THEN
                v_cols := ARRAY['id', 'farm_id', 'version'];
                v_vals := ARRAY[
                    quote_literal(v_record_id::text),
                    quote_literal(v_user_farm::text),
                    '1'
                ];
                FOR v_col IN SELECT jsonb_object_keys(v_data)
                LOOP
                    -- P0: ط§ظ„ط¹ط§ظ…ظ„/ط§ظ„ظ…ط´ط±ظپ ظ„ط§ ظٹظڈط¯ط®ظ„ worker_id ظ…ظ† ط§ظ„ط­ظ…ظˆظ„ط© â€” ظٹظڈظ„ط²ظ…ط§ظ† ط¨ظ‡ظˆظٹطھظ‡ظ…ط§ ظ„ط§ط­ظ‚ط§ظ‹
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
                        'message', 'طھط¹ط§ط±ط¶ ظپظٹ ط§ظ„ط¥طµط¯ط§ط± ط£ط«ظ†ط§ط، ط§ظ„طھط­ط¯ظٹط«'
                    );
                    CONTINUE;
                END IF;
                v_affected := v_affected + v_upd_count;

            ELSIF v_operation = 'delete' THEN
                -- P0/3: ط­ط°ظپ ظ†ط§ط¹ظ… ظ…ط¹ OCC â€” ظٹطھط·ظ„ط¨ previous_version ظ…ط·ط§ط¨ظ‚ط§ظ‹طŒ
                -- ظˆظٹظڈط¹طھط¨ط± طھط¹ط§ط±ط¶ط§ظ‹ (conflict) ط¹ظ†ط¯ظ…ط§ ظ„ط§ ظٹطھط·ط§ط¨ظ‚ (ROW_COUNT = 0).
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
                        'message', 'طھط¹ط§ط±ط¶ ظپظٹ ط§ظ„ط¥طµط¯ط§ط± ط£ط«ظ†ط§ط، ط§ظ„ط­ط°ظپ'
                    );
                    CONTINUE;
                END IF;
                v_affected := v_affected + v_upd_count;
            END IF;

            -- P0: طھط³ط¬ظٹظ„ ط§ظ„طھط؛ظٹظٹط± ظپظٹ sync_changes ظ„ظٹط±ط§ظ‡ ط§ظ„ط£ط¬ظ‡ط²ط© ط§ظ„ط£ط®ط±ظ‰ ط¹ط¨ط± pull.
            -- ظٹط­ظ„ ظ…ط´ظƒظ„ط©: sync_records_batch ظƒط§ظ† ظٹظƒطھط¨ ظ…ط¨ط§ط´ط±ط© ط¨ط¯ظˆظ† trigger
            -- (ظ„ط£ظ†ظ‡ ظ‚ط§ظ… ط¨طھط¹ط·ظٹظ„ظ‡)طŒ ظپظ„ظ… ظٹظڈط³ط¬ظژظ‘ظ„ ط£ظٹ طھط؛ظٹظٹط± ظپظٹ sync_changes.
            DECLARE
                v_sc_record jsonb;
                v_sc_payload jsonb;
            BEGIN
                -- ظ‚ط±ط§ط،ط© ط§ظ„طµظپ ط¨ط¹ط¯ ط§ظ„طھط¹ط¯ظٹظ„ (ظٹظپط¹ظ„ INSERT/UPDATE/DELETE ط§ظ„ظ†ط§ط¹ظ…)
                EXECUTE format(
                    'SELECT to_jsonb(t) FROM %I t WHERE t.id = $1 AND t.farm_id = $2',
                    v_table_name
                ) INTO v_sc_record
                USING v_record_id, v_user_farm;

                IF v_sc_record IS NOT NULL THEN
                    -- ط¥ط²ط§ظ„ط© sync_status ظˆ deleted_at ظپظ‚ط· (ظ†ط­طھظپط¸ ط¨ظ€ version ظ„طµط­ط© OCC)
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

                -- ط­ظپط¸ ظپظٹ ط³ط¬ظ„ ط§ظ„ظ€ idempotency
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
$$;

GRANT EXECUTE ON FUNCTION public.sync_records_batch(jsonb) TO authenticated;

-- ============================================================
-- 5) pull_remote_changes â€” ظ†ط³ط®ط© ظ…ظڈط¹ط§ط¯ ظƒطھط§ط¨طھظ‡ط§ طھط³طھط®ط¯ظ… sync_can_read
--    ط¨ط¯ظ„ط§ظ‹ ظ…ظ† NOT IN ('payments','expenses') ط§ظ„ط«ط§ط¨طھط©.
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
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: ط؛ظٹط± ظ…ط³ط¬ظ„ ط§ظ„ط¯ط®ظˆظ„';
    END IF;

    -- ط§ظ„ط³ظ…ط§ط­: system_admin (ظƒظ„ ط§ظ„ظ…ط¯ط§ط¬ظ†) ط£ظˆ manager/worker ظ„ظ…ط²ط±ط¹طھظ‡.
    -- ط§ظ„ط¹ط§ظ…ظ„ ظٹط³ط­ط¨ ط§ظ„ط¨ظٹط§ظ†ط§طھ ط§ظ„طھط´ط؛ظٹظ„ظٹط© ظپظ‚ط· (ظٹظڈط³طھط¨ط¹ط¯ ط§ظ„ط¬ط¯ظˆظ„ط§ظ† ط§ظ„ظ…ط§ظ„ظٹط§ظ†).
    IF NOT public.is_system_admin() THEN
        SELECT public.current_user_role() INTO v_role;
        IF v_role NOT IN ('manager', 'worker') THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: ط¯ظˆط± ط؛ظٹط± ظ…طµط±ط­ ط¨ط³ط­ط¨ ط§ظ„ظ…ط²ط§ظ…ظ†ط©';
        END IF;
        -- ط¥ط¬ط¨ط§ط± p_farm_id ط¹ظ„ظ‰ ظ…ط²ط±ط¹ط© ط§ظ„ظ…ط³طھط®ط¯ظ…ط› طھط¬ط§ظ‡ظ„ ط£ظٹ ظ‚ظٹظ…ط© ط£ط®ط±ظ‰ ظ…ظ† ط§ظ„ط¹ظ…ظٹظ„.
        IF p_farm_id IS DISTINCT FROM public.current_user_farm_id() THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: ظ…ط²ط±ط¹ط© ط؛ظٹط± ظ…طµط±ط­ ط¨ظ‡ط§';
        END IF;
        -- ط§ظ„ط¹ط§ظ…ظ„: ط§ظ„ظˆطµظˆظ„ ط§ظ„طھط´ط؛ظٹظ„ظٹ ظپظ‚ط· (ظ„ط§ ظٹط·ظ‘ظ„ط¹ ط¹ظ„ظ‰ ط§ظ„ظ…ط§ظ„ظٹط©: payments/expenses).
        IF v_role = 'worker' THEN
            v_operational_only := true;
        END IF;
    END IF;

    -- طµظٹط§ظ†ط© ط¯ظˆط±ظٹط© ظ…ظ‚ظٹظ‘ط¯ط© ط²ظ…ظ†ظٹط§ظ‹ (retention + compaction + checkpoint) â€”
    -- طھظڈظ†ظپظژظ‘ط° ظƒط­ط¯ ط£ظ‚طµظ‰ ظ…ط±ط© ظƒظ„ maintenance_interval_minutesطŒ ظپظ„ط§ طھظƒظ„ظ‘ظپ ط§ظ„ط³ط­ط¨.
    PERFORM public.auto_maintain_sync();

    -- ظ‚ط±ط§ط،ط© watermark ظ…ظ† checkpoint (ط¨ط¯ظ„ ظپط­ظˆطµ MIN/MAX ط§ظ„ظ…ظƒظ„ظپط© ظپظٹ ظƒظ„ ط³ط­ط¨).
    -- ط¥ط°ط§ ظ„ظ… ظٹظˆط¬ط¯ checkpoint ط¨ط¹ط¯ (ظ…ط²ط±ط¹ط© ط¬ط¯ظٹط¯ط©/ط£ظˆظ„ ط³ط­ط¨)طŒ ظ†ط­ط³ط¨ ظˆظ†ط®ط²ظ‘ظ†.
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

    -- ط¬ظ„ط¨ ط§ظ„طھط؛ظٹظٹط±ط§طھ ط§ظ„ط£ط­ط¯ط« ظ…ظ† ط§ظ„ط¥طµط¯ط§ط± ط§ظ„ظ…ط·ظ„ظˆط¨.
    -- ظ„ظ„ط¹ط§ظ…ظ„: ظ†ط³طھط¨ط¹ط¯ ط§ظ„ط¬ط¯ط§ظˆظ„ ط§ظ„ظ…ط§ظ„ظٹط© ظˆظ†ط¹ظٹط¯ watermark ظپط±ط¹ظٹ ظ„ظ„ط¹ظ…ظ„ظٹط§طھ ط§ظ„طھط´ط؛ظٹظ„ظٹط©
    -- ط­طھظ‰ ظ„ط§ ظٹط®ط²ظ‘ظ† ط¬ظ‡ط§ط² ط§ظ„ط¹ط§ظ…ظ„ watermark ظٹطھط¬ط§ظˆط² طھط؛ظٹظٹط±ط§طھظ‡ ط§ظ„ظ…ط³ظ…ظˆط­ ط¨ظ‡ط§.
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

        -- watermark ط§ظ„ط¹ط§ظ…ظ„ = ط£ط¹ظ„ظ‰ ظ†ط³ط®ط© طھط´ط؛ظٹظ„ظٹط© ط£ط¹ظٹط¯طھ ظ„ظ‡ (ط¨ط§ط³طھط«ظ†ط§ط، ط§ظ„ظ…ط§ظ„ظٹط©).
        SELECT COALESCE(MAX(server_version), p_from_version) INTO v_latest
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name)
          AND server_version > p_from_version;

        -- ط£ظ‚ظ„ ظ†ط³ط®ط© طھط´ط؛ظٹظ„ظٹط© ظ…ط­ظپظˆط¸ط© ط¨ط¹ط¯ ط§ظ„ط¶ط؛ط·/ط§ظ„ط§ط­طھظپط§ط¸ (ظ„ظ…ط¹ط±ظپط© ظ…ط§ ط¥ط°ط§ طھط£ط®ط± ط§ظ„ط¬ظ‡ط§ط²).
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

    -- ط¥ط°ط§ ظƒط§ظ† ط§ظ„ط¬ظ‡ط§ط² ظ…طھط£ط®ط±ط§ظ‹ ط¹ظ† ط£ظ‚ظ„ ظ†ط³ط®ط© ظ…ط­ظپظˆط¸ط©طŒ ظ„ط§ ظٹظ…ظƒظ†ظ‡ طھط·ط¨ظٹظ‚ delta ظ†ط§ظ‚طµ
    IF p_from_version > 0 AND p_from_version < v_min_keep THEN
        RETURN jsonb_build_object(
            'resync_required', true,
            'message', 'ط¨ظٹط§ظ†ط§طھ ط§ظ„ط¬ظ‡ط§ط² ط£ظ‚ط¯ظ… ظ…ظ† ظپطھط±ط© ط§ظ„ط§ط­طھظپط§ط¸طŒ ظٹظ„ط²ظ… ط¥ط¹ط§ط¯ط© ظ…ط²ط§ظ…ظ†ط© ظƒط§ظ…ظ„ط©',
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



COMMIT;



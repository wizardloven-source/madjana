-- ============================================================
-- Master Schema - Poultry Farm Management System
-- الإصدار: 3.0 (موحد ونظيف)
-- التاريخ: 2025-01-02
-- الوصف: هيكل قاعدة البيانات الكامل لجميع الجداول والدوال
-- ============================================================

-- ============================================================
-- 1. الجداول الأساسية (Core Tables)
-- ============================================================

-- جدول المزارع
CREATE TABLE IF NOT EXISTS public.farms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    location TEXT,
    phone TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- جدول المستخدمين
CREATE TABLE IF NOT EXISTS public.users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('worker', 'supervisor', 'manager')),
    farm_id UUID REFERENCES public.farms(id) ON DELETE SET NULL,
    full_name TEXT,
    phone TEXT,
    pin_hash TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- جدول القطعان
CREATE TABLE IF NOT EXISTS public.flocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    breed TEXT NOT NULL,
    start_date DATE NOT NULL,
    initial_count INTEGER NOT NULL,
    current_count INTEGER NOT NULL,
    sections_count INTEGER DEFAULT 1,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'sold', 'closed')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 2. جداول الإنتاج اليومي (Daily Operations)
-- ============================================================

-- إنتاج البيض
CREATE TABLE IF NOT EXISTS public.egg_production (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    flock_id UUID NOT NULL REFERENCES public.flocks(id) ON DELETE CASCADE,
    worker_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    cartons INTEGER DEFAULT 0,
    trays INTEGER DEFAULT 0,
    loose_eggs INTEGER DEFAULT 0,
    broken_eggs INTEGER DEFAULT 0,
    dirty_eggs INTEGER DEFAULT 0,
    tray_weight_kg DECIMAL(5,2),
    section_no INTEGER,
    total_eggs INTEGER GENERATED ALWAYS AS (
        (cartons * 360) + (trays * 30) + loose_eggs
    ) STORED,
    sync_status TEXT DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced', 'failed')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- النفوق
CREATE TABLE IF NOT EXISTS public.mortality (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    flock_id UUID NOT NULL REFERENCES public.flocks(id) ON DELETE CASCADE,
    worker_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    count INTEGER NOT NULL CHECK (count > 0),
    reason TEXT,
    image_url TEXT,
    section_no INTEGER,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- استهلاك العلف
CREATE TABLE IF NOT EXISTS public.feed_consumption (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    flock_id UUID REFERENCES public.flocks(id) ON DELETE SET NULL,
    worker_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    bags_count INTEGER DEFAULT 0,
    quantity_kg DECIMAL(10,2) NOT NULL,
    feed_type TEXT DEFAULT 'standard',
    section_no INTEGER,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- استلام العلف
CREATE TABLE IF NOT EXISTS public.feed_received (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    quantity_kg DECIMAL(10,2) NOT NULL,
    feed_type TEXT NOT NULL,
    supplier TEXT,
    price_per_kg DECIMAL(10,2),
    total_price DECIMAL(10,2),
    batch_number TEXT,
    expiry_date DATE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 3. جداول التخريج والمبيعات (Dispatch & Sales)
-- ============================================================

-- الزبائن
CREATE TABLE IF NOT EXISTS public.customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    phone TEXT,
    address TEXT,
    total_debt DECIMAL(12,2) DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- تخريج البيض
CREATE TABLE IF NOT EXISTS public.egg_dispatch (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    worker_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,
    customer_id UUID REFERENCES public.customers(id) ON DELETE SET NULL,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    cartons INTEGER DEFAULT 0,
    trays INTEGER DEFAULT 0,
    loose_eggs INTEGER DEFAULT 0,
    tray_weight_kg DECIMAL(5,2),
    total_eggs INTEGER GENERATED ALWAYS AS (
        (cartons * 360) + (trays * 30) + loose_eggs
    ) STORED,
    price_per_carton DECIMAL(10,2),
    total_amount DECIMAL(12,2),
    payment_status TEXT DEFAULT 'unpaid' CHECK (payment_status IN ('paid', 'partial', 'unpaid')),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- المدفوعات
CREATE TABLE IF NOT EXISTS public.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    manager_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,
    customer_id UUID REFERENCES public.customers(id) ON DELETE SET NULL,
    dispatch_id UUID REFERENCES public.egg_dispatch(id) ON DELETE SET NULL,
    amount_paid DECIMAL(12,2) NOT NULL,
    payment_method TEXT DEFAULT 'cash' CHECK (payment_method IN ('cash', 'bank', 'check')),
    payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 4. جداول المخزون والمصروفات (Inventory & Expenses)
-- ============================================================

-- المخزون
CREATE TABLE IF NOT EXISTS public.inventory_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    item_name TEXT NOT NULL,
    category TEXT,
    quantity DECIMAL(10,2) DEFAULT 0,
    unit TEXT NOT NULL,
    min_quantity DECIMAL(10,2) DEFAULT 0,
    price_per_unit DECIMAL(10,2),
    supplier TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- حركات المخزون
CREATE TABLE IF NOT EXISTS public.inventory_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id UUID NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('in', 'out', 'adjustment')),
    quantity DECIMAL(10,2) NOT NULL,
    reason TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- المصروفات
CREATE TABLE IF NOT EXISTS public.expenses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    amount DECIMAL(12,2) NOT NULL,
    description TEXT,
    expense_date DATE NOT NULL DEFAULT CURRENT_DATE,
    receipt_image TEXT,
    created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- الأدوية
CREATE TABLE IF NOT EXISTS public.medications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    flock_id UUID REFERENCES public.flocks(id) ON DELETE SET NULL,
    worker_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,
    medication_type TEXT NOT NULL,
    medication_name TEXT NOT NULL,
    dosage TEXT,
    administration_method TEXT,
    start_date DATE NOT NULL,
    end_date DATE,
    withdrawal_days INTEGER DEFAULT 0,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- أرصدة افتتاحية
CREATE TABLE IF NOT EXISTS public.opening_balances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    flock_id UUID REFERENCES public.flocks(id) ON DELETE SET NULL,
    cash_balance DECIMAL(12,2) DEFAULT 0,
    feed_qty_kg DECIMAL(10,2) DEFAULT 0,
    eggs_count INTEGER DEFAULT 0,
    notes TEXT,
    balance_date DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 5. جداول النظام والمزامنة (System & Sync)
-- ============================================================

-- طابور المزامنة
CREATE TABLE IF NOT EXISTS public.sync_changes (
    id BIGSERIAL PRIMARY KEY,
    server_version BIGINT DEFAULT 0,
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    changed_at TIMESTAMPTZ DEFAULT NOW(),
    user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
    payload JSONB,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'synced', 'failed', 'conflict'))
);

-- طلبات التخريج
CREATE TABLE IF NOT EXISTS public.dispatch_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    flock_id UUID NOT NULL REFERENCES public.flocks(id) ON DELETE CASCADE,
    customer_id UUID REFERENCES public.customers(id) ON DELETE SET NULL,
    worker_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,
    requested_cartons INTEGER NOT NULL,
    requested_date DATE NOT NULL,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'completed')),
    decided_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
    decision_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- إشعارات التطبيق
CREATE TABLE IF NOT EXISTS public.app_notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    flock_id UUID REFERENCES public.flocks(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    type TEXT DEFAULT 'info',
    is_read BOOLEAN DEFAULT FALSE,
    created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ
);

-- سجل التدقيق
CREATE TABLE IF NOT EXISTS public.audit_log (
    id BIGSERIAL PRIMARY KEY,
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    table_name TEXT NOT NULL,
    record_id UUID,
    old_values JSONB,
    new_values JSONB,
    ip_address TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- كتالوج الأدوية
CREATE TABLE IF NOT EXISTS public.medicines_catalog (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    manufacturer TEXT,
    default_withdrawal_days INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- إعدادات التطبيق
CREATE TABLE IF NOT EXISTS public.app_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    setting_key TEXT NOT NULL UNIQUE,
    setting_value JSONB NOT NULL,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 6. الفهارس (Indexes)
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_users_farm ON public.users(farm_id);
CREATE INDEX IF NOT EXISTS idx_users_role ON public.users(role);
CREATE INDEX IF NOT EXISTS idx_flocks_farm ON public.flocks(farm_id);
CREATE INDEX IF NOT EXISTS idx_flocks_status ON public.flocks(status);
CREATE INDEX IF NOT EXISTS idx_egg_production_farm_date ON public.egg_production(farm_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_egg_production_flock_date ON public.egg_production(flock_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_egg_production_sync ON public.egg_production(sync_status) WHERE sync_status = 'pending';
CREATE INDEX IF NOT EXISTS idx_mortality_farm_date ON public.mortality(farm_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_feed_consumption_farm_date ON public.feed_consumption(farm_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_customers_farm ON public.customers(farm_id);
CREATE INDEX IF NOT EXISTS idx_egg_dispatch_farm_date ON public.egg_dispatch(farm_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_payments_customer ON public.payments(customer_id);
CREATE INDEX IF NOT EXISTS idx_inventory_items_farm ON public.inventory_items(farm_id);
CREATE INDEX IF NOT EXISTS idx_expenses_farm_date ON public.expenses(farm_id, expense_date DESC);
CREATE INDEX IF NOT EXISTS idx_sync_changes_farm_status ON public.sync_changes(farm_id, status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_sync_changes_changed_at ON public.sync_changes(changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_farm ON public.audit_log(farm_id, created_at DESC);

-- ============================================================
-- 7. الدوال المساعدة (Helper Functions)
-- ============================================================

-- دالة الحصول على معرف المزرعة الحالي
CREATE OR REPLACE FUNCTION public.current_user_farm_id()
RETURNS UUID
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT farm_id FROM public.users WHERE id = auth.uid();
$$;

-- دالة الحصول على دور المستخدم الحالي
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT role FROM public.users WHERE id = auth.uid();
$$;

-- دالة المزامنة الدفعيّة
CREATE OR REPLACE FUNCTION public.sync_records_batch(
    p_records JSONB,
    p_user_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID;
    v_farm_id UUID;
    v_role TEXT;
    v_record JSONB;
    v_table TEXT;
    v_action TEXT;
    v_data JSONB;
    v_record_id UUID;
    v_payload_farm_id UUID;
    v_success JSONB := '[]'::JSONB;
    v_failed JSONB := '[]'::JSONB;
    v_conflicts JSONB := '[]'::JSONB;
    v_count INTEGER := 0;
    v_max_batch INTEGER := 100;
BEGIN
    -- التحقق من هوية المستخدم
    v_uid := COALESCE(p_user_id, auth.uid());
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: User ID is required';
    END IF;
    
    -- جلب معلومات المستخدم
    SELECT u.farm_id, u.role INTO v_farm_id, v_role
    FROM public.users u WHERE u.id = v_uid;
    
    IF v_farm_id IS NULL THEN
        RAISE EXCEPTION 'User not found or not associated with a farm';
    END IF;
    
    -- تحديد عدد السجلات
    v_count := jsonb_array_length(p_records);
    IF v_count > v_max_batch THEN
        RAISE EXCEPTION 'Batch size (%) exceeds maximum allowed (%)', v_count, v_max_batch;
    END IF;
    
    -- معالجة كل سجل
    FOR i IN 0..(v_count - 1) LOOP
        BEGIN
            v_record := p_records->i;
            v_table := v_record->>'table_name';
            v_action := v_record->>'operation';
            v_data := v_record->'payload';
            v_record_id := (v_record->>'record_id')::UUID;
            v_payload_farm_id := (v_data->>'farm_id')::UUID;
            
            -- التحقق من تطابق المزرعة
            IF v_payload_farm_id IS NOT NULL AND v_payload_farm_id != v_farm_id THEN
                v_failed := v_failed || jsonb_build_array(
                    jsonb_build_object('id', v_record_id, 'error', 'Farm ID mismatch')
                );
                CONTINUE;
            END IF;
            
            -- تنفيذ العملية حسب نوعها
            CASE v_action
                WHEN 'INSERT' THEN
                    CASE v_table
                        WHEN 'egg_production' THEN
                            INSERT INTO public.egg_production (id, farm_id, flock_id, worker_id, date, cartons, trays, loose_eggs, broken_eggs, dirty_eggs, tray_weight_kg, section_no, sync_status)
                            VALUES (v_record_id, (v_data->>'farm_id')::UUID, (v_data->>'flock_id')::UUID, (v_data->>'worker_id')::UUID, (v_data->>'date')::DATE, COALESCE((v_data->>'cartons')::INTEGER, 0), COALESCE((v_data->>'trays')::INTEGER, 0), COALESCE((v_data->>'loose_eggs')::INTEGER, 0), COALESCE((v_data->>'broken_eggs')::INTEGER, 0), COALESCE((v_data->>'dirty_eggs')::INTEGER, 0), (v_data->>'tray_weight_kg')::DECIMAL, (v_data->>'section_no')::INTEGER, 'synced');
                        
                        WHEN 'mortality' THEN
                            INSERT INTO public.mortality (id, farm_id, flock_id, worker_id, date, count, reason, image_url, section_no)
                            VALUES (v_record_id, (v_data->>'farm_id')::UUID, (v_data->>'flock_id')::UUID, (v_data->>'worker_id')::UUID, (v_data->>'date')::DATE, (v_data->>'count')::INTEGER, v_data->>'reason', v_data->>'image_url', (v_data->>'section_no')::INTEGER);
                            
                            -- تحديث عدد القطيع
                            UPDATE public.flocks SET current_count = current_count - (v_data->>'count')::INTEGER WHERE id = (v_data->>'flock_id')::UUID;
                        
                        WHEN 'feed_consumption' THEN
                            INSERT INTO public.feed_consumption (id, farm_id, flock_id, worker_id, date, bags_count, quantity_kg, feed_type, section_no)
                            VALUES (v_record_id, (v_data->>'farm_id')::UUID, (v_data->>'flock_id')::UUID, (v_data->>'worker_id')::UUID, (v_data->>'date')::DATE, COALESCE((v_data->>'bags_count')::INTEGER, 0), (v_data->>'quantity_kg')::DECIMAL, COALESCE(v_data->>'feed_type', 'standard'), (v_data->>'section_no')::INTEGER);
                        
                        WHEN 'egg_dispatch' THEN
                            INSERT INTO public.egg_dispatch (id, farm_id, worker_id, customer_id, date, cartons, trays, loose_eggs, tray_weight_kg, price_per_carton, total_amount, payment_status, notes)
                            VALUES (v_record_id, (v_data->>'farm_id')::UUID, (v_data->>'worker_id')::UUID, (v_data->>'customer_id')::UUID, (v_data->>'date')::DATE, COALESCE((v_data->>'cartons')::INTEGER, 0), COALESCE((v_data->>'trays')::INTEGER, 0), COALESCE((v_data->>'loose_eggs')::INTEGER, 0), (v_data->>'tray_weight_kg')::DECIMAL, (v_data->>'price_per_carton')::DECIMAL, (v_data->>'total_amount')::DECIMAL, COALESCE(v_data->>'payment_status', 'unpaid'), v_data->>'notes');
                        
                        ELSE
                            v_failed := v_failed || jsonb_build_array(
                                jsonb_build_object('id', v_record_id, 'error', 'Unknown table: ' || v_table)
                            );
                            CONTINUE;
                    END CASE;
                
                WHEN 'UPDATE' THEN
                    CASE v_table
                        WHEN 'egg_production' THEN
                            UPDATE public.egg_production
                            SET cartons = COALESCE((v_data->>'cartons')::INTEGER, cartons),
                                trays = COALESCE((v_data->>'trays')::INTEGER, trays),
                                loose_eggs = COALESCE((v_data->>'loose_eggs')::INTEGER, loose_eggs),
                                broken_eggs = COALESCE((v_data->>'broken_eggs')::INTEGER, broken_eggs),
                                dirty_eggs = COALESCE((v_data->>'dirty_eggs')::INTEGER, dirty_eggs),
                                tray_weight_kg = (v_data->>'tray_weight_kg')::DECIMAL,
                                section_no = (v_data->>'section_no')::INTEGER,
                                sync_status = 'synced',
                                updated_at = NOW()
                            WHERE id = v_record_id AND farm_id = v_farm_id;
                        
                        ELSE
                            v_failed := v_failed || jsonb_build_array(
                                jsonb_build_object('id', v_record_id, 'error', 'Update not supported for table: ' || v_table)
                            );
                            CONTINUE;
                    END CASE;
                
                WHEN 'DELETE' THEN
                    IF v_role != 'manager' THEN
                        v_failed := v_failed || jsonb_build_array(
                            jsonb_build_object('id', v_record_id, 'error', 'Only managers can delete records')
                        );
                        CONTINUE;
                    END IF;
                    
                    CASE v_table
                        WHEN 'egg_production' THEN
                            DELETE FROM public.egg_production WHERE id = v_record_id AND farm_id = v_farm_id;
                        WHEN 'mortality' THEN
                            DELETE FROM public.mortality WHERE id = v_record_id AND farm_id = v_farm_id;
                        ELSE
                            v_failed := v_failed || jsonb_build_array(
                                jsonb_build_object('id', v_record_id, 'error', 'Delete not supported for table: ' || v_table)
                            );
                            CONTINUE;
                    END CASE;
                
                ELSE
                    v_failed := v_failed || jsonb_build_array(
                        jsonb_build_object('id', v_record_id, 'error', 'Unknown operation: ' || v_action)
                    );
            END CASE;
            
            v_success := v_success || jsonb_build_array(v_record_id);
            
        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed || jsonb_build_array(
                jsonb_build_object('id', COALESCE(v_record_id, 'unknown'), 'error', SQLERRM)
            );
        END;
    END LOOP;
    
    RETURN jsonb_build_object('success', v_success, 'failed', v_failed, 'conflicts', v_conflicts);
END;
$$;

-- دالة جلب السجلات المعلقة
CREATE OR REPLACE FUNCTION public.get_pending_sync_changes(p_limit INTEGER DEFAULT 50)
RETURNS TABLE (
    id BIGINT,
    farm_id UUID,
    table_name TEXT,
    record_id UUID,
    operation TEXT,
    changed_at TIMESTAMPTZ,
    user_id UUID,
    payload JSONB
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT 
        sc.id,
        sc.farm_id,
        sc.table_name,
        sc.record_id,
        sc.operation,
        sc.changed_at,
        sc.user_id,
        sc.payload
    FROM public.sync_changes sc
    WHERE sc.status = 'pending'
      AND sc.farm_id = current_user_farm_id()
    ORDER BY sc.changed_at ASC
    LIMIT p_limit;
END;
$$;

-- دالة تحديث حالة المزامنة
CREATE OR REPLACE FUNCTION public.mark_sync_records_as_synced(p_ids BIGINT[])
RETURNS VOID AS $$
BEGIN
    UPDATE public.sync_changes
    SET status = 'synced',
        changed_at = NOW()
    WHERE id = ANY(p_ids)
      AND farm_id = current_user_farm_id();
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Failed to update sync status: %', SQLERRM;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- دالة تنظيف السجلات القديمة
CREATE OR REPLACE FUNCTION public.cleanup_old_sync_logs(days_to_keep INTEGER DEFAULT 30)
RETURNS BIGINT AS $$
DECLARE
    deleted_count BIGINT;
BEGIN
    DELETE FROM public.sync_changes
    WHERE status = 'synced'
      AND changed_at < NOW() - (days_to_keep || ' days')::INTERVAL;
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 8. محفزات التدقيق (Audit Triggers)
-- ============================================================

CREATE OR REPLACE FUNCTION public.audit_trigger_function()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.audit_log (farm_id, user_id, action, table_name, record_id, old_values, new_values)
        VALUES (NEW.farm_id, auth.uid(), 'INSERT', TG_TABLE_NAME, NEW.id, NULL, to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO public.audit_log (farm_id, user_id, action, table_name, record_id, old_values, new_values)
        VALUES (NEW.farm_id, auth.uid(), 'UPDATE', TG_TABLE_NAME, NEW.id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO public.audit_log (farm_id, user_id, action, table_name, record_id, old_values, new_values)
        VALUES (OLD.farm_id, auth.uid(), 'DELETE', TG_TABLE_NAME, OLD.id, to_jsonb(OLD), NULL);
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS audit_egg_production ON public.egg_production;
CREATE TRIGGER audit_egg_production
    AFTER INSERT OR UPDATE OR DELETE ON public.egg_production
    FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_function();

DROP TRIGGER IF EXISTS audit_mortality ON public.mortality;
CREATE TRIGGER audit_mortality
    AFTER INSERT OR UPDATE OR DELETE ON public.mortality
    FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_function();

DROP TRIGGER IF EXISTS audit_egg_dispatch ON public.egg_dispatch;
CREATE TRIGGER audit_egg_dispatch
    AFTER INSERT OR UPDATE OR DELETE ON public.egg_dispatch
    FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_function();

-- ============================================================
-- 9. سياسات الأمان (RLS Policies)
-- ============================================================

ALTER TABLE public.farms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.egg_production ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mortality ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_consumption ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_received ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.egg_dispatch ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opening_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispatch_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "farms_select" ON public.farms;
CREATE POLICY "farms_select" ON public.farms FOR SELECT TO authenticated USING (id = current_user_farm_id());

DROP POLICY IF EXISTS "farms_update_manager" ON public.farms;
CREATE POLICY "farms_update_manager" ON public.farms FOR UPDATE TO authenticated USING (current_user_role() = 'manager' AND id = current_user_farm_id());

DROP POLICY IF EXISTS "users_select_self" ON public.users;
CREATE POLICY "users_select_self" ON public.users FOR SELECT TO authenticated USING (id = auth.uid());

DROP POLICY IF EXISTS "users_select_same_farm" ON public.users;
CREATE POLICY "users_select_same_farm" ON public.users FOR SELECT TO authenticated USING (
    current_user_role() = 'manager' AND farm_id = current_user_farm_id()
);

DO $$
DECLARE
    tbl TEXT;
    tables TEXT[] := ARRAY['flocks', 'egg_production', 'mortality', 'feed_consumption', 'feed_received', 'customers', 'egg_dispatch', 'payments', 'inventory_items', 'expenses', 'medications', 'opening_balances', 'dispatch_requests', 'app_notifications'];
BEGIN
    FOREACH tbl IN ARRAY tables
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS "%1$s_select" ON public.%1$s', tbl);
        EXECUTE format('CREATE POLICY "%1$s_select" ON public.%1$s FOR SELECT TO authenticated USING (farm_id = current_user_farm_id())', tbl);
        
        EXECUTE format('DROP POLICY IF EXISTS "%1$s_insert" ON public.%1$s', tbl);
        EXECUTE format('CREATE POLICY "%1$s_insert" ON public.%1$s FOR INSERT TO authenticated WITH CHECK (farm_id = current_user_farm_id())', tbl);
        
        EXECUTE format('DROP POLICY IF EXISTS "%1$s_update" ON public.%1$s', tbl);
        EXECUTE format('CREATE POLICY "%1$s_update" ON public.%1$s FOR UPDATE TO authenticated USING (farm_id = current_user_farm_id()) WITH CHECK (farm_id = current_user_farm_id())', tbl);
        
        EXECUTE format('DROP POLICY IF EXISTS "%1$s_delete" ON public.%1$s', tbl);
        EXECUTE format('CREATE POLICY "%1$s_delete" ON public.%1$s FOR DELETE TO authenticated USING (farm_id = current_user_farm_id() AND current_user_role() = ''manager'')', tbl);
    END LOOP;
END $$;

DROP POLICY IF EXISTS "sync_changes_select" ON public.sync_changes;
CREATE POLICY "sync_changes_select" ON public.sync_changes FOR SELECT TO authenticated USING (farm_id = current_user_farm_id());

DROP POLICY IF EXISTS "sync_changes_no_manual_modification" ON public.sync_changes;
CREATE POLICY "sync_changes_no_manual_modification" ON public.sync_changes FOR ALL TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS "inventory_transactions_select" ON public.inventory_transactions;
CREATE POLICY "inventory_transactions_select" ON public.inventory_transactions FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.inventory_items i WHERE i.id = item_id AND i.farm_id = current_user_farm_id())
);

DROP POLICY IF EXISTS "inventory_transactions_manager" ON public.inventory_transactions;
CREATE POLICY "inventory_transactions_manager" ON public.inventory_transactions FOR ALL TO authenticated USING (
    current_user_role() = 'manager' AND EXISTS (SELECT 1 FROM public.inventory_items i WHERE i.id = item_id AND i.farm_id = current_user_farm_id())
) WITH CHECK (
    current_user_role() = 'manager' AND EXISTS (SELECT 1 FROM public.inventory_items i WHERE i.id = item_id AND i.farm_id = current_user_farm_id())
);

DROP POLICY IF EXISTS "medicines_catalog_select" ON public.medicines_catalog;
CREATE POLICY "medicines_catalog_select" ON public.medicines_catalog FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "medicines_catalog_manager" ON public.medicines_catalog;
CREATE POLICY "medicines_catalog_manager" ON public.medicines_catalog FOR ALL TO authenticated USING (current_user_role() = 'manager') WITH CHECK (current_user_role() = 'manager');

DROP POLICY IF EXISTS "audit_log_manager" ON public.audit_log;
CREATE POLICY "audit_log_manager" ON public.audit_log FOR ALL TO authenticated USING (current_user_role() = 'manager' AND farm_id = current_user_farm_id()) WITH CHECK (current_user_role() = 'manager' AND farm_id = current_user_farm_id());

-- ============================================================
-- 10. بيانات أولية (Seed Data)
-- ============================================================

INSERT INTO public.app_settings (setting_key, setting_value, description) VALUES
    ('app_version', '{"major": 1, "minor": 0, "patch": 0}', 'إصدار التطبيق'),
    ('features', '{"pro_enabled": false, "max_users": 10}', 'الميزات المفعلة'),
    ('sync_batch_size', '{"value": 50}', 'حجم دفعة المزامنة')
ON CONFLICT (setting_key) DO NOTHING;

-- ============================================================
-- نهاية ملف الهجرة الرئيسي
-- ============================================================

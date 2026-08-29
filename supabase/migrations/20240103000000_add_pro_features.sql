-- ============================================================
-- Migration: Professional Features Add-on
-- Description: Adds Inventory, Health Logs, Shifts, and Analytics support
-- ============================================================

-- 1. Advanced Inventory Management
CREATE TABLE IF NOT EXISTS public.inventory_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    category TEXT NOT NULL, -- 'feed', 'medicine', 'equipment'
    barcode TEXT,
    quantity DECIMAL(10, 2) NOT NULL DEFAULT 0,
    unit TEXT NOT NULL, -- 'kg', 'box', 'liter'
    min_stock_level DECIMAL(10, 2) DEFAULT 0,
    expiry_date DATE,
    location_bin TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.inventory_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id UUID NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('IN', 'OUT', 'ADJUSTMENT')),
    quantity DECIMAL(10, 2) NOT NULL,
    reason TEXT,
    performed_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Flock Health Logs (Detailed Medical History)
CREATE TABLE IF NOT EXISTS public.health_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flock_id UUID NOT NULL REFERENCES public.flocks(id) ON DELETE CASCADE,
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    log_date DATE NOT NULL DEFAULT CURRENT_DATE,
    symptom TEXT,
    diagnosis TEXT,
    treatment_action TEXT,
    medication_used UUID REFERENCES public.medications(id),
    severity TEXT CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    vet_name TEXT,
    cost DECIMAL(10, 2) DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- 3. Shifts & Worker Performance
CREATE TABLE IF NOT EXISTS public.worker_shifts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID NOT NULL REFERENCES public.farms(id) ON DELETE CASCADE,
    worker_name TEXT NOT NULL,
    shift_date DATE NOT NULL DEFAULT CURRENT_DATE,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ,
    tasks_completed JSONB, -- List of completed tasks
    performance_score INTEGER CHECK (performance_score BETWEEN 1 AND 5),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. System Maintenance & Backups Log
CREATE TABLE IF NOT EXISTS public.system_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id UUID REFERENCES public.farms(id) ON DELETE CASCADE,
    action_type TEXT NOT NULL, -- 'BACKUP', 'RESTORE', 'SYNC_FORCE', 'SETTINGS_CHANGE'
    details JSONB,
    status TEXT CHECK (status IN ('SUCCESS', 'FAILED', 'PENDING')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for Performance
CREATE INDEX IF NOT EXISTS idx_inventory_barcode ON public.inventory_items(barcode);
CREATE INDEX IF NOT EXISTS idx_inventory_expiry ON public.inventory_items(expiry_date);
CREATE INDEX IF NOT EXISTS idx_health_flock_date ON public.health_logs(flock_id, log_date);
CREATE INDEX IF NOT EXISTS idx_shifts_worker_date ON public.worker_shifts(worker_name, shift_date);

-- Triggers for updated_at
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_inventory_items_updated ON public.inventory_items;
CREATE TRIGGER tr_inventory_items_updated
    BEFORE UPDATE ON public.inventory_items
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

DROP TRIGGER IF EXISTS tr_health_logs_updated ON public.health_logs;
CREATE TRIGGER tr_health_logs_updated
    BEFORE UPDATE ON public.health_logs
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

-- Enable RLS
ALTER TABLE public.inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.health_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.worker_shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_logs ENABLE ROW LEVEL SECURITY;

-- Policies (Simplified for Manager/Worker access)
-- Assuming a function get_user_farm_id() exists or similar logic in your app
-- Here we apply generic policies based on farm_id matching user's farm_id in users table

CREATE POLICY "Farm members can view inventory" ON public.inventory_items
    FOR SELECT USING (farm_id IN (SELECT farm_id FROM public.users WHERE id = auth.uid()));

CREATE POLICY "Managers can manage inventory" ON public.inventory_items
    FOR ALL USING (
        farm_id IN (SELECT farm_id FROM public.users WHERE id = auth.uid() AND role = 'manager')
    );

CREATE POLICY "Farm members can view health logs" ON public.health_logs
    FOR SELECT USING (farm_id IN (SELECT farm_id FROM public.users WHERE id = auth.uid()));

CREATE POLICY "Managers can manage health logs" ON public.health_logs
    FOR ALL USING (
        farm_id IN (SELECT farm_id FROM public.users WHERE id = auth.uid() AND role = 'manager')
    );

CREATE POLICY "Farm members can view shifts" ON public.worker_shifts
    FOR SELECT USING (farm_id IN (SELECT farm_id FROM public.users WHERE id = auth.uid()));

CREATE POLICY "Managers can manage shifts" ON public.worker_shifts
    FOR ALL USING (
        farm_id IN (SELECT farm_id FROM public.users WHERE id = auth.uid() AND role = 'manager')
    );

CREATE POLICY "Farm members can view system logs" ON public.system_logs
    FOR SELECT USING (farm_id IS NULL OR farm_id IN (SELECT farm_id FROM public.users WHERE id = auth.uid()));

-- Add new tables to Sync allowed list in Edge Function logic (Handled in Dart/TS mostly, but good to note)
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- v007: الأرصدة الافتتاحية للقطعان القديمة
-- نسخة متوافقة مع المخطط الفعلي (معرّفات نصية TEXT)
-- بدون قيود مفتاح أجنبي حتى لا تتعارض الأنواع مع الجداول الموجودة
-- آمن لإعادة التنفيذ (IF NOT EXISTS + DROP POLICY IF EXISTS)
-- ============================================================

CREATE TABLE IF NOT EXISTS opening_balances (
    id TEXT PRIMARY KEY,
    farm_id TEXT NOT NULL,
    flock_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    eggs_produced INTEGER NOT NULL DEFAULT 0,
    eggs_dispatched INTEGER NOT NULL DEFAULT 0,
    feed_consumed_kg REAL NOT NULL DEFAULT 0,
    initial_birds INTEGER NOT NULL DEFAULT 0,
    mortality_count INTEGER NOT NULL DEFAULT 0,
    total_payments REAL NOT NULL DEFAULT 0,
    total_revenues REAL NOT NULL DEFAULT 0,
    sections JSONB
);

CREATE INDEX IF NOT EXISTS idx_opening_farm ON opening_balances(farm_id);
CREATE INDEX IF NOT EXISTS idx_opening_flock ON opening_balances(flock_id);

ALTER TABLE opening_balances ENABLE ROW LEVEL SECURITY;

-- دوال مساعدة آمنة نصياً (تُنشأ إن لم تكن موجودة من 008)
CREATE OR REPLACE FUNCTION public.current_role_safe()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.role::text FROM public.users u WHERE u.id::text = auth.uid()::text LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.current_farm_safe()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.farm_id::text FROM public.users u WHERE u.id::text = auth.uid()::text LIMIT 1
$$;

GRANT EXECUTE ON FUNCTION public.current_role_safe() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_farm_safe() TO anon, authenticated;

-- مدير فقط: قراءة/كتابة أرصدة مزرعته
DROP POLICY IF EXISTS manager_only_opening_balances ON opening_balances;
CREATE POLICY manager_only_opening_balances ON opening_balances
    FOR ALL TO authenticated
    USING (
        farm_id::text = public.current_farm_safe()
        AND public.current_role_safe() = 'manager'
    )
    WITH CHECK (
        farm_id::text = public.current_farm_safe()
        AND public.current_role_safe() = 'manager'
    );

-- العامل لا يرى الأرصدة إطلاقاً
DROP POLICY IF EXISTS worker_no_opening_balances ON opening_balances;
CREATE POLICY worker_no_opening_balances ON opening_balances
    FOR SELECT TO authenticated
    USING (false);
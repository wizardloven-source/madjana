-- جدول الشركاء
CREATE TABLE IF NOT EXISTS partners (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    phone_number VARCHAR(20) NOT NULL,
    email VARCHAR(255),
    national_id VARCHAR(20),
    address TEXT,
    profile_image_url TEXT,
    contract_document_url TEXT,
    contract_start_date DATE,
    contract_end_date DATE,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'expired')),
    total_received_profits DECIMAL(15,2) DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- جدول علاقات الشركاء بالمزارع
CREATE TABLE IF NOT EXISTS partner_farm_relations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id UUID NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
    farm_id UUID NOT NULL REFERENCES farms(id) ON DELETE CASCADE,
    farm_name VARCHAR(255),
    role VARCHAR(50) NOT NULL, -- مول، صاحب أرض، إلخ
    percentage DECIMAL(5,2) NOT NULL CHECK (percentage > 0 AND percentage <= 100),
    bears_loss BOOLEAN DEFAULT true,
    start_date DATE,
    end_date DATE,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'expired')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(partner_id, farm_id)
);

-- جدول المعاملات المالية للشركاء
CREATE TABLE IF NOT EXISTS partner_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id UUID NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
    farm_id UUID REFERENCES farms(id) ON DELETE SET NULL,
    farm_name VARCHAR(255),
    description TEXT NOT NULL,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    credit DECIMAL(15,2), -- دائن (له)
    debit DECIMAL(15,2), -- مدين (عليه)
    balance DECIMAL(15,2) DEFAULT 0,
    payment_method VARCHAR(50), -- كاش، تحويل بنكي، شيك
    receipt_image_url TEXT,
    transaction_type VARCHAR(50) NOT NULL, -- profit, withdrawal, advance, settlement
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- جدول مسحوبات الشركاء
CREATE TABLE IF NOT EXISTS partner_withdrawals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id UUID NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
    amount DECIMAL(15,2) NOT NULL,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    description TEXT,
    payment_method VARCHAR(50),
    receipt_image_url TEXT,
    is_settled BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- جدول سجل التدقيق
CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID NOT NULL,
    action VARCHAR(50) NOT NULL,
    user_id UUID NOT NULL,
    details TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- إنشاء فهارس لتحسين الأداء
CREATE INDEX IF NOT EXISTS idx_partners_status ON partners(status);
CREATE INDEX IF NOT EXISTS idx_partner_farm_relations_partner_id ON partner_farm_relations(partner_id);
CREATE INDEX IF NOT EXISTS idx_partner_farm_relations_farm_id ON partner_farm_relations(farm_id);
CREATE INDEX IF NOT EXISTS idx_partner_transactions_partner_id ON partner_transactions(partner_id);
CREATE INDEX IF NOT EXISTS idx_partner_transactions_date ON partner_transactions(date);
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity_type, entity_id);

-- دالة جلب شركاء مدجنة معينة
CREATE OR REPLACE FUNCTION get_partners_by_farm(farm_id_param UUID)
RETURNS TABLE (
    id UUID,
    name VARCHAR,
    phone_number VARCHAR,
    email VARCHAR,
    national_id VARCHAR,
    address TEXT,
    profile_image_url TEXT,
    contract_document_url TEXT,
    contract_start_date DATE,
    contract_end_date DATE,
    status VARCHAR,
    total_received_profits DECIMAL,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT p.*
    FROM partners p
    INNER JOIN partner_farm_relations pfr ON p.id = pfr.partner_id
    WHERE pfr.farm_id = farm_id_param
    AND p.status = 'active';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger لتحديث updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_partners_updated_at
    BEFORE UPDATE ON partners
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- سياسات RLS (Row Level Security)
ALTER TABLE partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE partner_farm_relations ENABLE ROW LEVEL SECURITY;
ALTER TABLE partner_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE partner_withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- سياسة للمالك: يرى كل شيء
CREATE POLICY "Owners can view all partners"
    ON partners FOR ALL
    USING (auth.uid() IN (
        SELECT user_id FROM user_farms WHERE role = 'owner'
    ));

-- سياسة للشريك: يرى فقط بياناته
CREATE POLICY "Partners can view their own data"
    ON partners FOR SELECT
    USING (auth.uid() = id);

COMMENT ON TABLE partners IS 'جدول إدارة شركاء المزارع';
COMMENT ON TABLE partner_farm_relations IS 'علاقات الشركاء بالمزارع ونسب الأرباح';
COMMENT ON TABLE partner_transactions IS 'المعاملات المالية للشركاء (أرباح، مسحوبات)';
COMMENT ON TABLE partner_withdrawals IS 'مسحوبات الشركاء المسبقة';
COMMENT ON TABLE audit_logs IS 'سجل تدقيق جميع العمليات على الشركاء';

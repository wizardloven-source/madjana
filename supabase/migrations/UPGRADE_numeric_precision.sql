-- UPGRADE_numeric_precision.sql
-- توسيع دقة الأعمدة المالية المخزنة بالدولار حتى لا تضيع الكسور عند
-- التحويل من الليرة (390000 ÷ 13750 = 28.3636... كان يُدوَّر إلى 28.36
-- فيعيد الفتح 389950 بدل 390000). توسيع NUMERIC آمن ولا يفقد بيانات.
ALTER TABLE payments ALTER COLUMN price_per_carton TYPE NUMERIC(16,8);
ALTER TABLE payments ALTER COLUMN total_due TYPE NUMERIC(16,8);
ALTER TABLE payments ALTER COLUMN amount_paid TYPE NUMERIC(16,8);
ALTER TABLE revenue ALTER COLUMN amount TYPE NUMERIC(16,8);
ALTER TABLE expenses ALTER COLUMN amount TYPE NUMERIC(16,8);

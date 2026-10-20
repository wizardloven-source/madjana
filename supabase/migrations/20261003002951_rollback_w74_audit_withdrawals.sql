-- ============================================================
-- W7.4 rollback: محفّز تدقيق سحوبات الشركاء
-- ============================================================
-- يعكس 20261003002950_w74_audit_withdrawals.sql
-- ملاحظة: build_test_db.py يتخطى أي ملف يحوي "rollback" فلا يُطبّق تلقائيًا.
-- السجلات التي كتبها المحفّز في partner_audit تبقى (append-only حوكمة).
-- ============================================================

BEGIN;

DROP TRIGGER IF EXISTS trg_partner_withdrawals_audit ON public.partner_withdrawals;
DROP FUNCTION IF EXISTS public.audit_partner_withdrawal();

COMMIT;

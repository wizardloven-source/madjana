-- ============================================================================
-- W7.4 (SQL): محفّز تدقيق سحوبات الشركاء على partner_withdrawals
-- ============================================================================
-- WHY
--   W6-M23 منعت العميل من كتابة partner_audit (لا سياسة INSERT)، وحصرت
--   الكاتب في record_partner_audit() الذي يفرض is_system_admin() داخلياً.
--   النتيجة: اعتماد/صرف/رفض سحبٍ من قِبل مدير مزرعة (user_manages_farm)
--   لا يترك أثراً في سجل التدقيق إطلاقاً — ثغرة حوكمة في مسار المال.
--
--   W7.4 يُغطّي المسار بمحفّز AFTER على partner_withdrawals نفسه (نمط M30:
--   كتابة الجدول المُراقَب مباشرةً من كاتب خادمي SECURITY DEFINER، بلا
--   تعديل approve_withdrawal() ولا record_partner_audit()).
--
-- INTEGRITY
--   * INSERT في أي حالة يُسجَّل withdrawal_requested (الطلب دخل النظام).
--   * تغيّر الحالة إلى approved/rejected/paid يُسجَّل بالإجراء المقابل؛
--     cancelled مقصوداً بلا تسجيل (لا قيمة مطابقة في قيد action CHECK).
--   * تحديثات غير-حالة (مثلاً notes) لا تُنتج سجلاً.
--   * changed_by = auth.uid() إن كان مستخدماً حقيقياً، وإلا reviewed_by /
--     requested_by المخزََنَين على الصف (FK مضمون) — فلا يكسر السجلُ
--     عملية الكتابة نفسها أبداً.
--   * سجل partner_audit يبقى append-only: لا سياسة كتابة جديدة، والمحفّز
--     وحده يكتب (SECURITY DEFINER).
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) دالة التدقيق ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.audit_partner_withdrawal()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $w74audit$
DECLARE
    v_actor  uuid;
    v_action text;
BEGIN
    -- من يقف خلف العملية؟ auth.uid() عند وجود جلسة حقيقية، وإلا المراجع
    -- أو الطالب المخزَنَين على الصف (عمليات الخادم/الهجرة بلا جلسة).
    v_actor := auth.uid();
    IF v_actor IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = v_actor) THEN
        v_actor := COALESCE(NEW.reviewed_by, NEW.requested_by);
    END IF;
    IF v_actor IS NULL THEN
        -- لا actor صالح: نتخطّى التسجيل ولا نُفشل عملية السحب.
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.partner_audit
            (farm_id, partner_id, action, new_values, changed_by, notes)
        VALUES
            (NEW.farm_id, NEW.partner_id, 'withdrawal_requested',
             jsonb_build_object(
                 'withdrawal_id', NEW.id,
                 'amount', NEW.amount,
                 'currency', NEW.currency,
                 'distribution_id', NEW.distribution_id,
                 'reason', NEW.reason),
             v_actor, 'auto: partner_withdrawals trigger');
        RETURN NEW;
    END IF;

    -- UPDATE: تسجيل تغيّر الحالة فقط (لا تحديثات غير-حالة).
    IF NEW.status IS DISTINCT FROM OLD.status
       AND NEW.status IN ('approved', 'rejected', 'paid') THEN
        v_action := 'withdrawal_' || NEW.status;
        INSERT INTO public.partner_audit
            (farm_id, partner_id, action, old_values, new_values,
             changed_by, notes)
        VALUES
            (NEW.farm_id, NEW.partner_id, v_action,
             jsonb_build_object('status', OLD.status),
             jsonb_build_object(
                 'withdrawal_id', NEW.id,
                 'status', NEW.status,
                 'rejection_reason', NEW.rejection_reason,
                 'payment_method', NEW.payment_method),
             v_actor, 'auto: partner_withdrawals trigger');
    END IF;

    RETURN NEW;
END;
$w74audit$;

-- ── 2) المحفّز ──────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_partner_withdrawals_audit ON public.partner_withdrawals;
CREATE TRIGGER trg_partner_withdrawals_audit
    AFTER INSERT OR UPDATE ON public.partner_withdrawals
    FOR EACH ROW EXECUTE FUNCTION public.audit_partner_withdrawal();

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $w74chk$
DECLARE
    v_n      int;
    v_tgtype int;
BEGIN
    IF to_regclass('public.partner_withdrawals') IS NULL THEN
        RAISE EXCEPTION 'FAIL: partner_withdrawals missing';
    END IF;

    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname = 'trg_partner_withdrawals_audit'
       AND tgrelid = 'public.partner_withdrawals'::regclass;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: trg_partner_withdrawals_audit not attached exactly once';
    END IF;

    -- AFTER (لا BEFORE) + INSERT أو UPDATE (لا DELETE/TRUNCATE).
    SELECT tgtype INTO v_tgtype FROM pg_trigger
     WHERE NOT tgisinternal AND tgname = 'trg_partner_withdrawals_audit';
    IF (v_tgtype & 2) <> 0 THEN
        RAISE EXCEPTION 'FAIL: audit trigger must be AFTER, tgtype=%', v_tgtype;
    END IF;
    IF (v_tgtype & 4) = 0 OR (v_tgtype & 16) = 0 THEN
        RAISE EXCEPTION 'FAIL: audit trigger must fire on INSERT and UPDATE, tgtype=%', v_tgtype;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public'
                      AND p.proname = 'audit_partner_withdrawal'
                      AND p.prosecdef) THEN
        RAISE EXCEPTION 'FAIL: audit_partner_withdrawal() missing or not SECURITY DEFINER';
    END IF;

    RAISE NOTICE 'OK: W7.4 verified - partner_withdrawals audit trigger live';
END;
$w74chk$;

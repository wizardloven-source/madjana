-- ============================================================================
-- M24 (W6) ROLLBACK: drop the partner workflow functions
-- ============================================================================
-- Removes exactly what 20261003002300_m24_partner_functions.sql created. The
-- functions hold no data, but they are the only code that can move a
-- withdrawal past 'pending', so the rollback refuses while any processed
-- withdrawal exists -- dropping the engine would strand those rows with no
-- supported way to reach 'paid'.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

DO $m24rb$
DECLARE
    v_processed int;
BEGIN
    IF to_regclass('public.partner_withdrawals') IS NOT NULL THEN
        SELECT count(*) INTO v_processed
          FROM public.partner_withdrawals
         WHERE deleted_at IS NULL
           AND status IN ('approved', 'rejected', 'paid', 'cancelled');
        IF v_processed > 0 THEN
            RAISE EXCEPTION
                'ABORT: cannot rollback M24 - % processed withdrawal(s) exist',
                v_processed;
        END IF;
    END IF;
END;
$m24rb$;

DROP FUNCTION IF EXISTS public.partner_net_profit(uuid, date, date, uuid);
DROP FUNCTION IF EXISTS public.partner_pending_withdrawal(uuid);
DROP FUNCTION IF EXISTS public.partner_summary(uuid);
DROP FUNCTION IF EXISTS public.approve_withdrawal(uuid, uuid);
DROP FUNCTION IF EXISTS public.calculate_profit_distribution(uuid, date, date, uuid);

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT)
-- ============================================================================
DO $m24rchk$
DECLARE
    v_sigs text[] := ARRAY[
        'public.partner_net_profit(uuid,date,date,uuid)',
        'public.partner_pending_withdrawal(uuid)',
        'public.partner_summary(uuid)',
        'public.approve_withdrawal(uuid,uuid)',
        'public.calculate_profit_distribution(uuid,date,date,uuid)'
    ];
    v_sig text;
BEGIN
    FOREACH v_sig IN ARRAY v_sigs LOOP
        IF to_regprocedure(v_sig) IS NOT NULL THEN
            RAISE EXCEPTION 'FAIL: % still exists after rollback', v_sig;
        END IF;
    END LOOP;
    RAISE NOTICE 'OK: M24 rollback verified - partner workflow functions dropped';
END;
$m24rchk$;

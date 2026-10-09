-- ============================================================================
-- M20: due_payments — آجال: إشعارات الاستحقاق والتأخر (بدون غرامة/تعليق)
-- ============================================================================
-- WHY
--   آجل dispatches carry a due_date (paid-in-7 / paid-in-30, chosen by the
--   operator at W3/M-W3 design time). Nothing tracks those dates server-side,
--   so an overdue invoice only bothers the person who remembers to look.
--   M20 makes the DB the reminder:
--
--     check_due_payments()   scans OPEN آجل payments (unpaid, due_date set)
--                            and, at four milestones, creates an
--                            app_notifications row:
--                              +3d  payment_due_3      "يستحق خلال 3 أيام"
--                              +0d  payment_due_today  "يستحق اليوم"
--                              -7d  payment_overdue_7  "متأخر 7 أيام"
--                              -30d payment_overdue_30 "متأخر 30 يوم"
--     idempotent per milestone: a notification keyed PAYDUE:<ms>:<payment_id>
--     is created once; re-runs skip it. No fine, no suspension, no debicard
--     impact — pure reminder, as specified.
--
--   No hard dependency on pg_cron (local PG15 and CI do not ship it). The
--   migration schedules a daily job ONLY if the extension is present; on
--   every other box it prints one NOTICE and the operator either schedules
--   check_due_payments() manually or points a Supabase Edge timer at it
--   (docs/DEPLOYMENT.md, W5).
--
-- SCOPE
--   * one function + optional cron job; nothing else touched.
--   * the +7/+30 AUTO due-date on dispatch creation stays an APP decision
--     (W6): this server function only notifies against dates that exist.
--
-- SECURITY NOTES
--   * SECURITY DEFINER: app_notifications INSERT is RLS-gated to the
--     farm's members, but a cron/scheduler session carries no auth.uid();
--     the definer writes the notice, readers still see only their farm's.
--   * created_by = NULL marks "system-generated".
--   * notifications are regular synced rows (app_notifications has the sync
--     triggers), so a manager-triggered run replicates on device.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) the notifier ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.check_due_payments()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m20$
DECLARE
    v_created   int := 0;
    v_p         record;
    v_days      int;
    v_milestone text;
    v_key       text;
    v_body      text;
    v_flock     uuid;
BEGIN
    FOR v_p IN
        SELECT id, farm_id, dispatch_id, due_date,
               amount_paid, total_due
          FROM public.payments
         WHERE deleted_at IS NULL
           AND due_date  IS NOT NULL
           AND COALESCE(amount_paid, 0) < COALESCE(total_due, 0)
    LOOP
        v_days := (v_p.due_date - CURRENT_DATE);

        v_milestone := CASE
            WHEN v_days = 3  THEN 'payment_due_3'
            WHEN v_days = 0  THEN 'payment_due_today'
            WHEN v_days = -7 THEN 'payment_overdue_7'
            WHEN v_days = -30 THEN 'payment_overdue_30'
            ELSE NULL
        END;

        IF v_milestone IS NULL THEN
            CONTINUE;
        END IF;

        v_key := 'PAYDUE:' || v_milestone || ':' || v_p.id::text;
        IF EXISTS (
            SELECT 1 FROM public.app_notifications
             WHERE farm_id = v_p.farm_id AND title = v_key AND is_active
        ) THEN
            CONTINUE;
        END IF;

        v_body := CASE v_milestone
            WHEN 'payment_due_3'     THEN 'أجل يستحق خلال 3 أيام.'
            WHEN 'payment_due_today' THEN 'أجل مستحق اليوم — راجع المدفوعات.'
            WHEN 'payment_overdue_7' THEN 'أجل متأخر 7 أيام — تواصل مع الزبون.'
            ELSE 'أجل متأخر 30 يوم — راجع الحساب.'
        END;

        SELECT d.flock_id INTO v_flock
          FROM public.egg_dispatch d
         WHERE d.id = v_p.dispatch_id;

        INSERT INTO public.app_notifications
            (farm_id, flock_id, is_persistent, is_active, created_by,
             title, body, level)
        VALUES
            (v_p.farm_id, v_flock, false, true, NULL,
             v_key, v_body, 'warning');

        v_created := v_created + 1;
    END LOOP;

    RETURN v_created;
END;
$m20$;

-- ── 2) grants ────────────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.check_due_payments() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.check_due_payments() TO authenticated;

COMMIT;

-- ============================================================================
-- OPTIONAL SCHEDULING — only when pg_cron exists
-- ============================================================================
DO $m20$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'madjana_due_payments') THEN
            PERFORM cron.schedule('madjana_due_payments', '0 6 * * *',
                                  $$SELECT public.check_due_payments()$$);
        END IF;
    ELSE
        RAISE NOTICE 'M20: pg_cron غير مثبت — جدوِل check_due_payments() يدويا أو عبر Edge Function (docs/DEPLOYMENT.md)';
    END IF;
END;
$m20$;

-- ============================================================================
-- VERIFICATION (after COMMIT, a failure never rolls the work back)
-- ============================================================================
DO $m20$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname='check_due_payments' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: check_due_payments not SECURITY DEFINER';
    END IF;

    IF has_function_privilege('anon', 'public.check_due_payments()', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: anon can call check_due_payments';
    END IF;

    -- milestone/dedup/settled-money behaviour runs in p0_due_payments_test.sql
    -- against the local fixtures; production data must not be touched by a
    -- migration's verify block.
    RAISE NOTICE 'OK: M20 verified - notifier live, calls gated, cron optional';
END;
$m20$;
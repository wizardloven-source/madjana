-- ============================================================================
-- M6b ROLLBACK -- undo per-key server-side login throttling
-- ============================================================================
--  Scope guard: refuses the rollback while security_alerts still holds any
--  recorded alert (the throttle ladder has genuinely fired, so the operator
--  gets to review those hits before the store is reverted -- manual rollback
--  after triage). An EMPTY store rolls back automatically; a missing store
--  just means M6b was never applied (idempotent re-run). No guard consults
--  login_throttle: its rows are plain rate-limit counters with no owner --
--  the API roles never read it, so rolling it back never leaks.
--
--  On top of the guard, this file:
--      * restores throttle_exceeded(text, int, int) with the ORIGINAL
--        init.sql body (client-supplied p_max/p_window_seconds) + its
--        anon/authenticated grants
--      * drops the server-side throttle_exceeded(text)
--      * restores record_login_failure(text) with the ORIGINAL init.sql body
--        + its anon/authenticated grants
--      * drops record_login_failure(text, text) and the M6b-only objects
--        (record_security_alert writer + the security_alerts table)
--
--  IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── guard: refuse automatic rollback while alerts are on file ───────────────
DO $m6r$
BEGIN
    IF to_regclass('public.security_alerts') IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.security_alerts) THEN
        RAISE EXCEPTION 'REFUSED: security_alerts يحتوي تنبيهات مسجلة — راجع التهبّات (20+ محاولة) ثم أفرغ الجدول أو نفّذ تراجعاً يدوياً';
    END IF;
END;
$m6r$;

-- ── 1) restore throttle_exceeded(text, int, int) exactly as init.sql ──────
DROP FUNCTION IF EXISTS public.throttle_exceeded(text);
CREATE OR REPLACE FUNCTION public.throttle_exceeded(
    p_key text,
    p_max int DEFAULT 10,
    p_window_seconds int DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6rfn$
DECLARE
    v_hits int;
BEGIN
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
$m6rfn$;

GRANT EXECUTE ON FUNCTION public.throttle_exceeded(text, int, int) TO anon, authenticated;

-- ── 2) restore record_login_failure(text) exactly as init.sql ───────────────
DROP FUNCTION IF EXISTS public.record_login_failure(text, text);
CREATE OR REPLACE FUNCTION public.record_login_failure(p_phone text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6rfn$
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
$m6rfn$;

GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon, authenticated;

-- ── 3) drop the M6b-only objects ─────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.record_security_alert(text, text, jsonb);
DROP TABLE IF EXISTS security_alerts;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m6r$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
      AND p.pronargs = 3;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: throttle_exceeded(text,int,int) not restored';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
      AND p.pronargs = 1;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: throttle_exceeded(text) outlived the rollback';
    END IF;

    IF NOT has_function_privilege('anon', 'public.throttle_exceeded(text, int, int)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.throttle_exceeded(text, int, int)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: throttle_exceeded lost its original grants';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
      AND p.pronargs = 1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: record_login_failure(text) not restored';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
      AND p.pronargs = 2;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: record_login_failure(text,text) outlived the rollback';
    END IF;

    IF NOT has_function_privilege('anon', 'public.record_login_failure(text)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.record_login_failure(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: record_login_failure lost its original grants';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'record_security_alert') THEN
        RAISE EXCEPTION 'FAIL: record_security_alert outlived the rollback';
    END IF;

    IF to_regclass('public.security_alerts') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: security_alerts outlived the rollback';
    END IF;

    RAISE NOTICE 'OK: M6b rolled back cleanly - client-throttle restored, security_alerts gone';
END;
$m6r$;
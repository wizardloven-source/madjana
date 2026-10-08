-- ============================================================================
-- M6b: login throttling without client-supplied bounds + escalating lock ladder
-- ============================================================================
-- WHY
--   throttle_exceeded(p_key, p_max, p_window_seconds) lets the CLIENT choose
--   the threshold and window: passing p_max = 0 turns a single request into an
--   instant lock (a cheap denial-of-service against any key the caller can
--   guess), and passing a huge p_max silently disables the throttle. The bounds
--   belong on the server, so throttle_exceeded now reads them exclusively from
--   throttle_max_hits() / throttle_window_seconds().
--
--   record_login_failure(phone) thottled nothing by itself: it only bumped the
--   account counter and had no per-IP awareness, so an attacker rotating
--   phone numbers was unconstrained. M6b records EVERY failure under both a
--   'phone:' and an 'ip:' key in login_throttle and escalates:
--       5 hits  -> 15-minute lock
--       10 hits -> 1-hour lock
--       20 hits -> 1-hour lock AND a security alert (record_security_alert)
--
--   security_alerts is created here in its minimal form because the ladder
--   needs a place to record escalations. M6c adds the RLS/admin surface.
--
-- SCOPE (nothing outside this is touched)
--   * drops throttle_exceeded(text,int,int), installs throttle_exceeded(text)
--   * drops record_login_failure(text), installs record_login_failure(text,text)
--   * creates security_alerts table + record_security_alert writer (internal)
--   * grants: throttle_exceeded -> authenticated (anon refused), the failure
--     reporter stays callable by anon (it runs BEFORE a session is created)
--
-- SECURITY NOTES
--   * every new function is SECURITY DEFINER, search_path pinned, and REVOKEd
--     from PUBLIC (a fresh function EXECs to PUBLIC by default).
--   * no client-supplied p_max/p_window anywhere; server tuning only.
--   * app.pin_secret is NOT touched.
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) security_alerts store (minimal; M6c adds RLS + admin surface) ────────
CREATE TABLE IF NOT EXISTS security_alerts (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_type  text NOT NULL,
    severity    text NOT NULL DEFAULT 'warning',
    meta        jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION public.record_security_alert(
    p_alert_type text,
    p_severity   text DEFAULT 'warning',
    p_meta       jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6b$
DECLARE
    v_id uuid;
BEGIN
    IF p_alert_type IS NULL OR p_alert_type = '' THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: نوع تنبيه مطلوب';
    END IF;
    INSERT INTO security_alerts (alert_type, severity, meta)
    VALUES (p_alert_type,
            COALESCE(p_severity, 'warning'),
            COALESCE(p_meta, '{}'::jsonb))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$m6b$;

REVOKE EXECUTE ON FUNCTION public.record_security_alert(text, text, jsonb) FROM PUBLIC;

-- ── 2) throttle_exceeded: server-side bounds only ────────────────────────────
DROP FUNCTION IF EXISTS public.throttle_exceeded(text, int, int);
CREATE OR REPLACE FUNCTION public.throttle_exceeded(p_key text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6b$
DECLARE
    v_hits int;
    v_max  int := public.throttle_max_hits();
    v_win  int := public.throttle_window_seconds();
BEGIN
    IF p_key IS NULL OR p_key = '' THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: مفتاح غير صالح';
    END IF;

    INSERT INTO login_throttle (key, hits, window_start, last_hit)
    VALUES (p_key, 1, NOW(), NOW())
    ON CONFLICT (key) DO UPDATE SET
        last_hit = NOW(),
        hits = CASE
            WHEN login_throttle.window_start < NOW() - (v_win || ' seconds')::interval THEN 1
            ELSE login_throttle.hits + 1
        END,
        window_start = CASE
            WHEN login_throttle.window_start < NOW() - (v_win || ' seconds')::interval THEN NOW()
            ELSE login_throttle.window_start
        END
    RETURNING hits INTO v_hits;

    RETURN v_hits > v_max;
END;
$m6b$;

REVOKE EXECUTE ON FUNCTION public.throttle_exceeded(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.throttle_exceeded(text) TO authenticated;

-- ── 3) record_login_failure: phone:/ip: keys + escalating ladder ─────────────
DROP FUNCTION IF EXISTS public.record_login_failure(text);
CREATE OR REPLACE FUNCTION public.record_login_failure(p_phone text, p_ip text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6b$
DECLARE
    v_max        int := public.login_lock_max_attempts();
    v_lock_s     int := public.login_lock_duration_seconds();
    v_win        int := public.throttle_window_seconds();
    v_phone      text;
    v_ip         text;
    v_key        text;
    v_hits       int := 0;
    v_phone_hits int := 0;
    v_ip_hits    int := 0;
    v_failed     int := 0;
    v_lock_sec   int := 0;
    v_alert      boolean := false;
BEGIN
    v_phone := NULLIF(regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g'), '');
    v_ip    := NULLIF(trim(COALESCE(p_ip, '')), '');

    -- account-level counter (unchanged semantics: 5 -> 15-minute account lock)
    IF v_phone IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.users WHERE phone = v_phone) THEN
        UPDATE public.users
           SET failed_attempts = failed_attempts + 1,
               locked_until = CASE
                   WHEN failed_attempts + 1 >= v_max
                       THEN NOW() + (v_lock_s || ' seconds')::interval
                   ELSE locked_until
               END,
               updated_at = NOW()
         WHERE phone = v_phone
         RETURNING failed_attempts INTO v_failed;
    END IF;

    -- composite key: 'phone:' || p_phone
    IF v_phone IS NOT NULL THEN
        v_key := 'phone:' || v_phone;
        INSERT INTO login_throttle (key, hits, window_start, last_hit)
        VALUES (v_key, 1, NOW(), NOW())
        ON CONFLICT (key) DO UPDATE SET
            last_hit = NOW(),
            hits = CASE
                WHEN login_throttle.window_start < NOW() - (v_win || ' seconds')::interval THEN 1
                ELSE login_throttle.hits + 1
            END,
            window_start = CASE
                WHEN login_throttle.window_start < NOW() - (v_win || ' seconds')::interval THEN NOW()
                ELSE login_throttle.window_start
            END
        RETURNING hits INTO v_hits;
        v_phone_hits := v_hits;

        IF v_hits = 20 THEN
            v_alert := true;
            PERFORM public.record_security_alert(
                'login_throttle', 'high',
                jsonb_build_object('key', v_key, 'phone', v_phone, 'hits', v_hits));
            v_lock_sec := GREATEST(v_lock_sec, 3600);
        ELSIF v_hits >= 10 THEN
            v_lock_sec := GREATEST(v_lock_sec, 3600);
        ELSIF v_hits >= 5 THEN
            v_lock_sec := GREATEST(v_lock_sec, 900);
        END IF;
    END IF;

    -- composite key: 'ip:' || p_ip
    IF v_ip IS NOT NULL THEN
        v_key := 'ip:' || v_ip;
        INSERT INTO login_throttle (key, hits, window_start, last_hit)
        VALUES (v_key, 1, NOW(), NOW())
        ON CONFLICT (key) DO UPDATE SET
            last_hit = NOW(),
            hits = CASE
                WHEN login_throttle.window_start < NOW() - (v_win || ' seconds')::interval THEN 1
                ELSE login_throttle.hits + 1
            END,
            window_start = CASE
                WHEN login_throttle.window_start < NOW() - (v_win || ' seconds')::interval THEN NOW()
                ELSE login_throttle.window_start
            END
        RETURNING hits INTO v_hits;
        v_ip_hits := v_hits;

        IF v_hits = 20 THEN
            v_alert := true;
            PERFORM public.record_security_alert(
                'login_throttle', 'high',
                jsonb_build_object('key', v_key, 'ip', v_ip, 'hits', v_hits));
            v_lock_sec := GREATEST(v_lock_sec, 3600);
        ELSIF v_hits >= 10 THEN
            v_lock_sec := GREATEST(v_lock_sec, 3600);
        ELSIF v_hits >= 5 THEN
            v_lock_sec := GREATEST(v_lock_sec, 900);
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'locked',        v_lock_sec > 0,
        'lock_seconds',  v_lock_sec,
        'attempts_left', CASE
                             WHEN v_phone IS NULL THEN -1
                             WHEN NOT EXISTS (SELECT 1 FROM public.users WHERE phone = v_phone) THEN -1
                             ELSE GREATEST(0, v_max - v_failed)
                         END,
        'phone_hits',    v_phone_hits,
        'ip_hits',       v_ip_hits,
        'alert',         v_alert);
END;
$m6b$;

REVOKE EXECUTE ON FUNCTION public.record_login_failure(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text, text) TO anon, authenticated;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m6b$
DECLARE
    v_n int;
BEGIN
    -- throttle_exceeded: (text) only; the client-supplied-bounds form is gone
    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded' AND p.pronargs = 1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: throttle_exceeded(text) not installed';
    END IF;
    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded' AND p.pronargs = 3;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: throttle_exceeded(text,int,int) still present';
    END IF;
    IF has_function_privilege('anon', 'public.throttle_exceeded(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: anon can call throttle_exceeded';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.throttle_exceeded(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost EXECUTE on throttle_exceeded';
    END IF;

    -- record_login_failure: (text,text) only
    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_login_failure' AND p.pronargs = 2;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: record_login_failure(text,text) not installed';
    END IF;
    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_login_failure' AND p.pronargs = 1;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: record_login_failure(text) still present';
    END IF;
    IF NOT has_function_privilege('anon', 'public.record_login_failure(text, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: anon must still reach record_login_failure (pre-login path)';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.record_login_failure(text, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost EXECUTE on record_login_failure';
    END IF;

    -- alert store: writer exists and is internal-only
    IF NOT EXISTS (SELECT 1 FROM pg_proc
                   WHERE proname = 'record_security_alert' AND prosecdef) THEN
        RAISE EXCEPTION 'FAIL: record_security_alert not SECURITY DEFINER';
    END IF;
    IF has_function_privilege('anon', 'public.record_security_alert(text, text, jsonb)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.record_security_alert(text, text, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: record_security_alert exposed to an API role';
    END IF;
    IF to_regclass('public.security_alerts') IS NULL THEN
        RAISE EXCEPTION 'FAIL: security_alerts table missing';
    END IF;

    RAISE NOTICE 'OK: M6b verified - server-side throttle, phone:/ip: keys, ladder wired, anon throttled out';
END;
$m6b$;
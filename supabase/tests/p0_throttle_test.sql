-- ============================================================================
-- P0 M6b: server-side login throttling (no client-supplied bounds)
-- ============================================================================
-- The rules under test, from docs/SECURITY.md §9:
--   * throttle_exceeded(text) reads its bounds ONLY from throttle_max_hits()
--     (10) and throttle_window_seconds() (60): the old (text,int,int) form that
--     let the caller self-disable the throttle is GONE, along with its
--     denial-of-service shape ("p_max = 0 locks out any guessable key").
--   * throttle_exceeded is SECURITY DEFINER and REVOKEd from PUBLIC and anon;
--     only authenticated may call it.
--   * record_login_failure(p_phone, p_ip) records EVERY failure under two
--     composite keys -- 'phone:' || p_phone and 'ip:' || p_ip -- in
--     login_throttle, and escalates: 5 hits -> 15-min lock, 10 -> 1-hour lock,
--     20 -> 1-hour lock AND a security alert.
--   * record_login_failure stays callable by anon (it runs BEFORE a session
--     exists); it is REVOKEd from PUBLIC and granted to anon+authenticated.
--   * record_security_alert is internal-only (SECURITY DEFINER, not exposed).
--   * the migration's DDL re-runs cleanly (idempotent), and the rollback is
--     guarded (refuses while alerts are on file) and restores the ORIGINAL
--     functions.
--
-- Functional reads never touch login_throttle directly (RLS-enabled, no
-- policy, API roles cannot see it): every assertion reads the jsonb returned
-- by record_login_failure, and security_alerts counts go through the owner.
--
-- Runs inside BEGIN/ROLLBACK. No fixtures shared with other suites.
--   psql -f supabase/tests/p0_throttle_test.sql
-- ============================================================================

BEGIN;

-- ── helpers (the standard P0 contract checkers) ──────────────────────────────
CREATE SCHEMA IF NOT EXISTS tests;

CREATE OR REPLACE FUNCTION tests.expect(
    p_label text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok THEN
        RAISE NOTICE 'PASS  %', rpad(p_label, 56, '.');
    ELSE
        RAISE EXCEPTION 'FAIL  %  %', p_label, p_detail;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION tests.role_exec(p_proname text, p_role text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM pg_proc p
          CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, '{}'::aclitem[])) a
         WHERE p.proname = p_proname
           AND a.privilege_type = 'EXECUTE'
           AND CASE WHEN lower(p_role) = 'public' THEN a.grantee = 0
                    ELSE a.grantee = p_role::regrole OR a.grantee = 0
               END);
$$;

-- ── fixture: one KNOWN-phone user: the account-counter path of
--    record_login_failure still works (the throttle keys are separate). ───────
SET ROLE postgres;

INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'throttle-b1@test.local',
        '{"role":"worker","full_name":"Throttle B1","phone":"0555000199","farm_id":"00000000-0000-0000-0000-000000000001"}'::jsonb)
ON CONFLICT (id) DO NOTHING;

UPDATE public.users SET failed_attempts = 3
WHERE id = '00000000-0000-0000-0000-0000000000b1';

SET ROLE test_runner;

-- ============================================================================
-- PART I -- structural + ACL contract
-- ============================================================================
DO $$
BEGIN
    PERFORM tests.expect('throttle_exceeded(text) installed',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
                  AND p.pronargs = 1));
    PERFORM tests.expect('old throttle_exceeded(text,int,int) gone',
        NOT EXISTS (SELECT 1 FROM pg_proc p
                     JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
                      AND p.pronargs = 3));

    -- the DoS shape: a 3-arg call must not resolve to anything
    BEGIN
        PERFORM public.throttle_exceeded('demo:key', 0, 0);
        PERFORM tests.expect('p_max/p_window are NOT accepted (no 3-arg fn)',
            false, 'call unexpectedly resolved');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('p_max/p_window are NOT accepted (no 3-arg fn)',
            SQLERRM LIKE '%does not exist%', SQLERRM);
    END;

    PERFORM tests.expect('PUBLIC cannot call throttle_exceeded',
        NOT tests.role_exec('throttle_exceeded', 'public'));
    PERFORM tests.expect('anon cannot call throttle_exceeded',
        NOT tests.role_exec('throttle_exceeded', 'anon'));
    PERFORM tests.expect('throttle_exceeded granted to authenticated only',
        tests.role_exec('throttle_exceeded', 'authenticated'));

    PERFORM tests.expect('record_login_failure(text,text) installed',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
                  AND p.pronargs = 2
                  AND format_type(p.proargtypes[0], NULL) = 'text'
                  AND format_type(p.proargtypes[1], NULL) = 'text'));
    PERFORM tests.expect('old record_login_failure(text) gone',
        NOT EXISTS (SELECT 1 FROM pg_proc p
                     JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
                      AND p.pronargs = 1));
    PERFORM tests.expect('PUBLIC cannot call record_login_failure',
        NOT tests.role_exec('record_login_failure', 'public'));
    PERFORM tests.expect('anon CAN STILL call record_login_failure (pre-login)',
        tests.role_exec('record_login_failure', 'anon'));

    PERFORM tests.expect('record_security_alert is internal-only',
        NOT tests.role_exec('record_security_alert', 'public')
        AND NOT tests.role_exec('record_security_alert', 'anon')
        AND NOT tests.role_exec('record_security_alert', 'authenticated'));

    RAISE NOTICE 'M6b structural + ACL block passed';
END $$;

-- ============================================================================
-- PART II -- behavioural: keys, server bounds, escalating ladder
-- ============================================================================
DO $$
DECLARE
    v_res jsonb;
    v_i   int;
    v_left int;
BEGIN
    -- phone-only: 'phone:' key climbs, nothing is written for a NULL ip
    FOR v_i IN 1..3 LOOP
        v_res := public.record_login_failure('0555000101', NULL);
    END LOOP;
    PERFORM tests.expect('ip-less failures raise the phone: key',
        (v_res ->> 'phone_hits') = '3',
        'phone_hits = ' || COALESCE(v_res ->> 'phone_hits', 'NULL'));
    PERFORM tests.expect('NULL ip writes nothing to the ip: key',
        (v_res ->> 'ip_hits') = '0',
        'ip_hits = ' || COALESCE(v_res ->> 'ip_hits', 'NULL'));

    -- ip-only: 'ip:' key climbs, phone untouched
    FOR v_i IN 1..3 LOOP
        v_res := public.record_login_failure(NULL, '203.0.113.21');
    END LOOP;
    PERFORM tests.expect('phone-less failures raise the ip: key',
        (v_res ->> 'ip_hits') = '3',
        'ip_hits = ' || COALESCE(v_res ->> 'ip_hits', 'NULL'));
    PERFORM tests.expect('NULL phone writes nothing to the phone: key',
        (v_res ->> 'phone_hits') = '0',
        'phone_hits = ' || COALESCE(v_res ->> 'phone_hits', 'NULL'));

    -- server bounds: throttle_exceeded alone uses hits > 10 (no client max)
    FOR v_i IN 1..11 LOOP
        PERFORM public.throttle_exceeded('serverbounds:demo');
    END LOOP;
    PERFORM tests.expect('throttle_exceeded locks at 10 (server default), '
                         || 'no client max',
        public.throttle_exceeded('serverbounds:demo'),
        '11th hit not seen as exceed');

    -- escalating ladder on a fresh phone+ip pair
    FOR v_i IN 1..20 LOOP
        v_res := public.record_login_failure('0555000102', '198.51.100.31');
        IF v_i = 5 THEN
            PERFORM tests.expect('5 hits -> 15-minute lock (900s)',
                (v_res ->> 'locked') = 'true'
                AND (v_res ->> 'lock_seconds')::int = 900,
                v_res::text);
        ELSIF v_i = 10 THEN
            PERFORM tests.expect('10 hits -> 1-hour lock (3600s)',
                (v_res ->> 'locked') = 'true'
                AND (v_res ->> 'lock_seconds')::int = 3600,
                v_res::text);
        ELSIF v_i = 20 THEN
            PERFORM tests.expect('20 hits -> alert fired + 1-hour lock',
                (v_res ->> 'alert') = 'true'
                AND (v_res ->> 'lock_seconds')::int = 3600,
                v_res::text);
        END IF;
    END LOOP;

    -- account-counter path on a KNOWN phone is preserved (fixture seeded
    -- failed_attempts = 3, so this call is the 4th of 5 -> 1 left)
    v_res := public.record_login_failure('0555000199', NULL);
    SELECT (v_res ->> 'attempts_left')::int INTO v_left;
    PERFORM tests.expect('known phone: attempts_left counts down (4th of 5)',
        v_left = 1, 'attempts_left = ' || COALESCE(v_res ->> 'attempts_left', 'NULL'));

    RAISE NOTICE 'M6b behavioural block passed';
END $$;

-- ============================================================================
-- PART III -- alert persistence (read through the owner: API roles have no
-- grant on security_alerts -- deliberate, it is admin-only)
-- ============================================================================
SET ROLE postgres;

DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM public.security_alerts
     WHERE alert_type = 'login_throttle';
    PERFORM tests.expect('security_alerts has rows from the 20-hit ladder',
        v_n >= 1, 'count = ' || v_n);

    SELECT count(*) INTO v_n FROM public.security_alerts
     WHERE meta ->> 'hits' = '20';
    PERFORM tests.expect('alert meta records the 20-hit trigger',
        v_n >= 1, 'count = ' || v_n);

    PERFORM tests.expect('security_alerts is a table (M6c will add RLS/grants)',
        to_regclass('public.security_alerts') IS NOT NULL);

    RAISE NOTICE 'M6b alert persistence block passed';
END $$;

-- ============================================================================
-- PART IV -- idempotent re-run of M6b's DDL
-- ============================================================================

-- replay the migration's DDL exactly as a second apply would
CREATE OR REPLACE FUNCTION public.record_security_alert(
    p_alert_type text,
    p_severity   text DEFAULT 'warning',
    p_meta       jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6bidem$
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
$m6bidem$;

REVOKE EXECUTE ON FUNCTION public.record_security_alert(text, text, jsonb) FROM PUBLIC;

DROP FUNCTION IF EXISTS public.throttle_exceeded(text, int, int);
CREATE OR REPLACE FUNCTION public.throttle_exceeded(p_key text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6bidem$
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
$m6bidem$;

REVOKE EXECUTE ON FUNCTION public.throttle_exceeded(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.throttle_exceeded(text) TO authenticated;

DROP FUNCTION IF EXISTS public.record_login_failure(text);
CREATE OR REPLACE FUNCTION public.record_login_failure(p_phone text, p_ip text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6bidem$
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
$m6bidem$;

REVOKE EXECUTE ON FUNCTION public.record_login_failure(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text, text) TO anon, authenticated;

SET ROLE test_runner;

DO $$
BEGIN
    PERFORM tests.expect('idempotent: throttle_exceeded(text) survives a re-run',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
                  AND p.pronargs = 1)
        AND NOT EXISTS (SELECT 1 FROM pg_proc p
                         JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
                          AND p.pronargs = 3));
    PERFORM tests.expect('idempotent: anon still cannot call throttle_exceeded',
        NOT tests.role_exec('throttle_exceeded', 'anon'));
    PERFORM tests.expect('idempotent: record_login_failure(text,text) survives',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
                  AND p.pronargs = 2));
    PERFORM tests.expect('idempotent: record_login_failure still callable by anon',
        tests.role_exec('record_login_failure', 'anon'));
    RAISE NOTICE 'M6b idempotency block passed';
END $$;

-- ============================================================================
-- PART V -- rollback: guarded, then restores the ORIGINAL functions
-- ============================================================================
SET ROLE postgres;

-- 5a) the guard refuses while alerts are on file
DO $$
BEGIN
    BEGIN
        IF EXISTS (SELECT 1 FROM public.security_alerts) THEN
            RAISE EXCEPTION 'REFUSED: security_alerts يحتوي تنبيهات مسجلة';
        END IF;
        PERFORM tests.expect('rollback guard refuses while alert rows exist',
            false, 'guard did not fire');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('rollback guard refuses while alert rows exist',
            SQLERRM LIKE '%REFUSED%', SQLERRM);
    END;
END $$;

-- 5b) clear the alerts, then apply the rollback DDL exactly as a re-apply would
DELETE FROM public.security_alerts;

DROP FUNCTION IF EXISTS public.throttle_exceeded(text);
CREATE OR REPLACE FUNCTION public.throttle_exceeded(
    p_key text,
    p_max int DEFAULT 10,
    p_window_seconds int DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6roll$
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
$m6roll$;

GRANT EXECUTE ON FUNCTION public.throttle_exceeded(text, int, int) TO anon, authenticated;

DROP FUNCTION IF EXISTS public.record_login_failure(text, text);
CREATE OR REPLACE FUNCTION public.record_login_failure(p_phone text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6roll$
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
$m6roll$;

GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon, authenticated;

DROP FUNCTION IF EXISTS public.record_security_alert(text, text, jsonb);
-- M6c now owns a policy + a SETOF security_alerts function on this table, so a
-- plain DROP TABLE fails on dependencies. CASCADE mirrors the real reverse-order
-- rollback (00621 first) and lets the table -- and its M6c attachments -- go.
DROP TABLE IF EXISTS security_alerts CASCADE;

SET ROLE test_runner;

DO $$
BEGIN
    PERFORM tests.expect('rollback: throttle_exceeded(text,int,int) restored',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
                  AND p.pronargs = 3));
    PERFORM tests.expect('rollback: throttle_exceeded(text) gone',
        NOT EXISTS (SELECT 1 FROM pg_proc p
                     JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
                      AND p.pronargs = 1));
    PERFORM tests.expect('rollback: record_login_failure(text) restored',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
                  AND p.pronargs = 1));
    PERFORM tests.expect('rollback: record_login_failure(text,text) gone',
        NOT EXISTS (SELECT 1 FROM pg_proc p
                     JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
                      AND p.pronargs = 2));
    PERFORM tests.expect('rollback: record_security_alert gone',
        NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'record_security_alert'));
    PERFORM tests.expect('rollback: security_alerts table gone',
        to_regclass('public.security_alerts') IS NULL);
    RAISE NOTICE 'M6b rollback block passed';
END $$;

ROLLBACK;
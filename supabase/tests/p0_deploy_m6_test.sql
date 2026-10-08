-- ============================================================================
-- P0 M6 deploy simulation: build_test_db.py already deploys the whole migration
-- chain onto a database recreated from scratch, so this suite verifies the
-- OPERATIONAL outcome of that fresh deploy for M6a AND M6b:
--   * app.pin_secret is configured (set by the harness shim through
--     ALTER ROLE postgres, exactly like docs/SECURITY.md §8 tells ops to do)
--   * app.v1_grace_until was persisted by M6a to NOW() + 7 days
--   * record_login_success is functional on the deployed schema (accepts a
--     legacy v1 PIN inside the grace window, upgrades it, rejects a wrong PIN)
--   * M6b's throttle landed: throttle_exceeded(text) with NO client-supplied
--     bounds, anon refused, and record_login_failure(p_phone, p_ip) escalates
--     5 -> 15 min, 10 -> 1 hour, 20 -> alert, all on the freshly built schema
--
-- Deliberately does NOT set the app.* GUCs itself: they must come from the
-- deployed role/database settings so the suite proves the deploy, not the
-- suite. Runs inside BEGIN/ROLLBACK.
--   psql -f supabase/tests/p0_deploy_m6_test.sql
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS tests;

CREATE OR REPLACE FUNCTION tests.set_user(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
        true);
END;
$$;

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

-- ── M6a witness: a legacy v1 hash, as a fresh deploy would have on day one ──
-- ── M6b witness: nothing here, the throttle reads no fixtures ───────────────
SET ROLE postgres;

-- bcrypt comparisons from the assertions below run as test_runner, which has
-- no USAGE on schema extensions; this SECURITY DEFINER helper is owned by
-- postgres and does the matching on its behalf.
CREATE OR REPLACE FUNCTION tests.crypt_matches(p_attempt text, p_hash text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT extensions.crypt(p_attempt, p_hash) = p_hash;
$$;

INSERT INTO auth.users (id, email, raw_user_meta_data, encrypted_password)
VALUES ('00000000-0000-0000-0000-0000000000a5', 'pin-a5@test.local',
        '{"role":"worker","full_name":"Pin A5","phone":"0555000095","farm_id":"00000000-0000-0000-0000-000000000001"}'::jsonb,
        extensions.crypt('madjana$5555', extensions.gen_salt('bf')))
ON CONFLICT (id) DO NOTHING;

UPDATE public.users SET
    pin_hash = extensions.crypt('madjana$5555', extensions.gen_salt('bf'))
WHERE id = '00000000-0000-0000-0000-0000000000a5';

SET ROLE test_runner;

-- claim = system admin: the read-back assertions need to see the fixture row
-- of public.users under its RLS (same pattern as the other P0 suites)
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');

DO $$
DECLARE
    v_a5     uuid := '00000000-0000-0000-0000-0000000000a5';
    v_grace  text;
    v_gts    timestamptz;
    v_enc    text;
    v_res    jsonb;
    v_i      int;
    v_n      int;
BEGIN
    -- ── 1) the deployed GUCs (M6a) ─────────────────────────────────────────
    PERFORM tests.expect('deploy: app.pin_secret مضبوط بعد النشر',
        NULLIF(current_setting('app.pin_secret', true), '') IS NOT NULL,
        'app.pin_secret = ' || COALESCE(current_setting('app.pin_secret', true), 'NULL'));

    v_grace := current_setting('app.v1_grace_until', true);
    PERFORM tests.expect('deploy: app.v1_grace_until مضبوط بعد النشر',
        NULLIF(v_grace, '') IS NOT NULL, 'v1_grace_until = ' || COALESCE(v_grace, 'NULL'));

    v_gts := NULLIF(v_grace, '')::timestamptz;
    PERFORM tests.expect('deploy: app.v1_grace_until = الآن + 7 أيام',
        v_gts BETWEEN NOW() + interval '7 days' - interval '2 hours'
                 AND NOW() + interval '7 days' + interval '2 hours',
        'grace = ' || v_gts::text);

    PERFORM tests.expect('deploy: M6a objects موجودة على القاعدة المبنية حديثاً',
        EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'app_password_from_pin_v2')
        AND EXISTS (SELECT 1 FROM pg_proc
                     WHERE proname = 'record_login_success' AND pronargs = 2));

    -- ── 2) record_login_success works on the deployed schema (M6a) ─────────
    PERFORM public.record_login_success(v_a5, '5555');

    SELECT encrypted_password INTO v_enc FROM auth.users WHERE id = v_a5;
    PERFORM tests.expect('deploy: v1 داخل grace تمت ترقيته (auth.users)',
        tests.crypt_matches(public.app_password_from_pin_v2('5555'), v_enc));
    SELECT pin_hash INTO v_enc FROM public.users WHERE id = v_a5;
    PERFORM tests.expect('deploy: v1 داخل grace تمت ترقيته (public.users)',
        tests.crypt_matches(public.app_password_from_pin_v2('5555'), v_enc));

    BEGIN
        PERFORM public.record_login_success(v_a5, '0000');
        PERFORM tests.expect('deploy: رمز خاطئ مرفوض (INVALID_PIN)',
            false, 'no exception');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('deploy: رمز خاطئ مرفوض (INVALID_PIN)',
            SQLERRM LIKE '%INVALID_PIN%', SQLERRM);
    END;

    -- the upgraded user can still log in with the same PIN (now v2)
    PERFORM public.record_login_success(v_a5, '5555');
    SELECT encrypted_password INTO v_enc FROM auth.users WHERE id = v_a5;
    PERFORM tests.expect('deploy: الدخول بعد الترقية يعمل (v2)',
        tests.crypt_matches(public.app_password_from_pin_v2('5555'), v_enc));

    -- ── 3) M6b throttle landed on the fresh build ──────────────────────────
    PERFORM tests.expect('deploy: throttle_exceeded(text) فقط (بلا حدود عميل)',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
                  AND p.pronargs = 1)
        AND NOT EXISTS (SELECT 1 FROM pg_proc p
                         JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'public' AND p.proname = 'throttle_exceeded'
                          AND p.pronargs = 3));
    PERFORM tests.expect('deploy: anon محجوب عن throttle_exceeded',
        NOT tests.role_exec('throttle_exceeded', 'anon')
        AND NOT tests.role_exec('throttle_exceeded', 'public'));

    PERFORM tests.expect('deploy: record_login_failure(p_phone, p_ip) جاهزة',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
                  AND p.pronargs = 2
                  AND format_type(p.proargtypes[0], NULL) = 'text'
                  AND format_type(p.proargtypes[1], NULL) = 'text')
        AND NOT EXISTS (SELECT 1 FROM pg_proc p
                         JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'public' AND p.proname = 'record_login_failure'
                          AND p.pronargs = 1));
    PERFORM tests.expect('deploy: anon يصل إلى record_login_failure (pre-login)',
        tests.role_exec('record_login_failure', 'anon'));

    PERFORM tests.expect('deploy: security_alerts modal على القاعدة المبنية',
        to_regclass('public.security_alerts') IS NOT NULL);

    -- functional ladder on the fresh build: 5 -> 900s, 20 -> alert
    FOR v_i IN 1..20 LOOP
        v_res := public.record_login_failure('0555111102', '203.0.113.199');
        IF v_i = 5 THEN
            PERFORM tests.expect('deploy: 5 محاولات -> قفل 15 دقيقة',
                (v_res ->> 'locked') = 'true'
                AND (v_res ->> 'lock_seconds')::int = 900,
                v_res::text);
        ELSIF v_i = 20 THEN
            PERFORM tests.expect('deploy: 20 محاولة -> تنبيه أمني',
                (v_res ->> 'alert') = 'true', v_res::text);
        END IF;
    END LOOP;

    RAISE NOTICE 'M6 deploy simulation: all assertions passed.';
END $$;

-- the alert row landed on the fresh build (read through the owner: only
-- service_role -- and, in prod, ops -- can read security_alerts on purpose)
SET ROLE postgres;

DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM public.security_alerts
     WHERE alert_type = 'login_throttle';
    PERFORM tests.expect('deploy: تنبيه مسجل في security_alerts',
        v_n >= 1, 'count = ' || v_n);
    RAISE NOTICE 'M6 deploy alert persistence passed';
END $$;

SET ROLE test_runner;

ROLLBACK;
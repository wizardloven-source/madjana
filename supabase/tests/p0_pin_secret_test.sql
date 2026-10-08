-- ============================================================================
-- P0 M6a: PIN secret v2 + record_login_success PIN validation + writer upgrade
-- ============================================================================
-- The rules under test, from docs/SECURITY.md §6-§8:
--   * app_password_from_pin_v2 derives 'madjana$'||pin||'$'||app.pin_secret and
--     is STABLE SECURITY DEFINER with a pinned search_path
--   * it is REVOKEd from PUBLIC/anon/authenticated (PIN oracle), and it RAISES
--     when app.pin_secret is unset (fail closed)
--   * record_login_success(uuid,text) replaces (uuid): it validates the PIN,
--     upgrades a v1 hash to v2 inside the grace window, refuses v1 after the
--     grace date or when app.v1_grace_until is unset, and resets the lockout
--   * granted to authenticated only (anon is out)
--   * all four writers (admin_create_user, create_farm_with_manager,
--     admin_reset_pin, bootstrap_create_farm_and_manager) now store v2 hashes
--   * the migration's DDL re-runs cleanly (idempotent)
--
-- The two test GUCs live only in THIS transaction: app.pin_secret (a fake
-- secret, never a real one) and app.v1_grace_until. SET LOCAL dies with the
-- ROLLBACK at the end, so nothing leaks into other suites.
--
-- Runs inside BEGIN/ROLLBACK. Fixtures from local_fixtures.sql + dedicated
-- PIN users created here.
--   psql -f supabase/tests/p0_pin_secret_test.sql
-- ============================================================================

BEGIN;

-- ── session-only test configuration (transaction-scoped, dies with ROLLBACK) ─
SELECT set_config('app.pin_secret', 'm6a-test-secret', true);
SELECT set_config('app.v1_grace_until', (NOW() + interval '7 days')::text, true);

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
    -- does p_role (or PUBLIC) hold EXECUTE on the named public-schema function?
    -- ACL-based on pg_proc.proacl: works for any caller (has_function_privilege
    -- with a foreign role would raise "permission denied" for a non-superuser)
    SELECT EXISTS (
        SELECT 1
          FROM pg_proc p
          CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, '{}'::aclitem[])) a
         WHERE p.proname = p_proname
           AND (a.grantee = p_role::regrole OR a.grantee = 0)
           AND a.privilege_type = 'EXECUTE');
$$;

-- ── fixture users (as the DB owner; the trigger builds public.users) ────────
SET ROLE postgres;

-- bcrypt comparisons from the assertions below must run that are run by
-- test_runner, which has no USAGE on schema extensions; this SECURITY DEFINER
-- helper is owned by postgres and does the matching on its behalf.
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
VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'pin-a1@test.local',
     '{"role":"worker","full_name":"Pin A1","phone":"0555000091","farm_id":"00000000-0000-0000-0000-000000000001"}'::jsonb,
     extensions.crypt('madjana$1111', extensions.gen_salt('bf'))),
    ('00000000-0000-0000-0000-0000000000a2', 'pin-a2@test.local',
     '{"role":"worker","full_name":"Pin A2","phone":"0555000092","farm_id":"00000000-0000-0000-0000-000000000001"}'::jsonb,
     extensions.crypt('madjana$2222', extensions.gen_salt('bf'))),
    ('00000000-0000-0000-0000-0000000000a3', 'pin-a3@test.local',
     '{"role":"worker","full_name":"Pin A3","phone":"0555000093","farm_id":"00000000-0000-0000-0000-000000000001"}'::jsonb,
     extensions.crypt('madjana$3333', extensions.gen_salt('bf'))),
    ('00000000-0000-0000-0000-0000000000a4', 'pin-a4@test.local',
     '{"role":"worker","full_name":"Pin A4","phone":"0555000094","farm_id":"00000000-0000-0000-0000-000000000001"}'::jsonb,
     extensions.crypt(public.app_password_from_pin_v2('4444'), extensions.gen_salt('bf')));

UPDATE public.users SET
    pin_hash = extensions.crypt('madjana$1111', extensions.gen_salt('bf'))
WHERE id = '00000000-0000-0000-0000-0000000000a1';
UPDATE public.users SET
    pin_hash = extensions.crypt('madjana$2222', extensions.gen_salt('bf'))
WHERE id = '00000000-0000-0000-0000-0000000000a2';
UPDATE public.users SET
    pin_hash = extensions.crypt('madjana$3333', extensions.gen_salt('bf'))
WHERE id = '00000000-0000-0000-0000-0000000000a3';
UPDATE public.users SET
    pin_hash = extensions.crypt(public.app_password_from_pin_v2('4444'),
                                extensions.gen_salt('bf'))
WHERE id = '00000000-0000-0000-0000-0000000000a4';

-- lockout counter seed for the "success resets the counter" case
UPDATE public.users SET
    failed_attempts = 4,
    locked_until = NOW() + interval '10 minutes'
WHERE id = '00000000-0000-0000-0000-0000000000a4';

SET ROLE test_runner;

-- claim = system admin: lets the read-back assertions below see the fixture
-- rows of public.users under its RLS (same pattern as the P0 suites)
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');

DO $$
DECLARE
    v_ua     uuid := '00000000-0000-0000-0000-0000000000a1'; -- v1, in grace
    v_ub     uuid := '00000000-0000-0000-0000-0000000000a2'; -- v1, expired/refused
    v_uc     uuid := '00000000-0000-0000-0000-0000000000a3'; -- v1, no grace GUC
    v_ud     uuid := '00000000-0000-0000-0000-0000000000a4'; -- v2 from the start
    v_enc    text;
    v_cnt    int;
BEGIN
    -- ── structural: v2 derivation ───────────────────────────────────────────
    PERFORM tests.expect('app_password_from_pin_v2 exists',
        (SELECT count(*) FROM pg_proc WHERE proname = 'app_password_from_pin_v2') = 1);
    PERFORM tests.expect('app_password_from_pin_v2 is STABLE',
        EXISTS (SELECT 1 FROM pg_proc
                 WHERE proname = 'app_password_from_pin_v2' AND provolatile = 's'));
    PERFORM tests.expect('app_password_from_pin_v2 is SECURITY DEFINER',
        EXISTS (SELECT 1 FROM pg_proc
                 WHERE proname = 'app_password_from_pin_v2' AND prosecdef));
    PERFORM tests.expect('v2 search_path pinned to public, pg_temp',
        EXISTS (SELECT 1 FROM pg_proc
                 WHERE proname = 'app_password_from_pin_v2'
                   AND proconfig = ARRAY['search_path=public, pg_temp']));
    PERFORM tests.expect('anon cannot call v2 (PIN oracle closed)',
        NOT tests.role_exec('app_password_from_pin_v2', 'anon'));
    PERFORM tests.expect('authenticated cannot call v2 (PIN oracle closed)',
        NOT tests.role_exec('app_password_from_pin_v2', 'authenticated'));

    -- ── structural: record_login_success signature + grants ────────────────
    PERFORM tests.expect('record_login_success(uuid, text) installed',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'record_login_success'
                  AND p.pronargs = 2
                  AND format_type(p.proargtypes[0], NULL) = 'uuid'
                  AND format_type(p.proargtypes[1], NULL) = 'text'));
    PERFORM tests.expect('old record_login_success(uuid) gone',
        NOT EXISTS (SELECT 1 FROM pg_proc p
                     JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public' AND p.proname = 'record_login_success'
                      AND p.pronargs = 1));
    PERFORM tests.expect('authenticated can call record_login_success',
        tests.role_exec('record_login_success', 'authenticated'));
    PERFORM tests.expect('anon cannot call record_login_success',
        NOT tests.role_exec('record_login_success', 'anon'));

    -- ── structural: writers target v2 ──────────────────────────────────────
    PERFORM tests.expect('all 4 writers call v2',
        (SELECT count(*) FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('admin_create_user', 'create_farm_with_manager',
                             'admin_reset_pin', 'bootstrap_create_farm_and_manager')
           AND p.prokind = 'f'
           AND strpos(p.prosrc, 'public.app_password_from_pin_v2(') > 0) = 4);
    PERFORM tests.expect('no writer still calls v1',
        (SELECT count(*) FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('admin_create_user', 'create_farm_with_manager',
                             'admin_reset_pin', 'bootstrap_create_farm_and_manager')
           AND p.prokind = 'f'
           AND strpos(p.prosrc, 'public.app_password_from_pin(') > 0) = 0);

    -- ── behavioural: v2 derivation values and fail-closed ─────────────────
    PERFORM tests.expect('v2 pins the result to the server secret',
        public.app_password_from_pin_v2('1234') = 'madjana$1234$m6a-test-secret');

    BEGIN
        PERFORM set_config('app.pin_secret', '', true);
        PERFORM public.app_password_from_pin_v2('1234');
        PERFORM tests.expect('v2 RAISEs when app.pin_secret is unset',
            false, 'no exception');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('v2 RAISEs when app.pin_secret is unset',
            SQLERRM LIKE '%PIN_SECRET_NOT_CONFIGURED%', SQLERRM);
    END;
    PERFORM set_config('app.pin_secret', 'm6a-test-secret', true);

    -- ── behavioural: v1 user logs in inside the grace window -> upgraded ──
    PERFORM public.record_login_success(v_ua, '1111');
    SELECT encrypted_password INTO v_enc FROM auth.users WHERE id = v_ua;
    PERFORM tests.expect('v1 login within grace: auth.users upgraded to v2',
        tests.crypt_matches(public.app_password_from_pin_v2('1111'), v_enc));
    SELECT pin_hash INTO v_enc FROM public.users WHERE id = v_ua;
    PERFORM tests.expect('v1 login within grace: public.users.pin_hash upgraded',
        tests.crypt_matches(public.app_password_from_pin_v2('1111'), v_enc));

    -- ── behavioural: wrong PIN never upgrades ──────────────────────────────
    BEGIN
        PERFORM public.record_login_success(v_ub, '9999');
        PERFORM tests.expect('v1 wrong PIN rejected (INVALID_PIN)',
            false, 'no exception');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('v1 wrong PIN rejected (INVALID_PIN)',
            SQLERRM LIKE '%INVALID_PIN%', SQLERRM);
    END;
    SELECT encrypted_password INTO v_enc FROM auth.users WHERE id = v_ub;
    PERFORM tests.expect('wrong PIN leaves the v1 hash untouched',
        tests.crypt_matches('madjana$2222', v_enc)
        AND NOT tests.crypt_matches(public.app_password_from_pin_v2('2222'), v_enc));

    -- ── behavioural: v1 outside the grace window refused ──────────────────
    PERFORM set_config('app.v1_grace_until', (NOW() - interval '1 second')::text, true);
    BEGIN
        PERFORM public.record_login_success(v_ub, '2222');
        PERFORM tests.expect('v1 after grace refused (PIN_VERSION_EXPIRED)',
            false, 'no exception');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('v1 after grace refused (PIN_VERSION_EXPIRED)',
            SQLERRM LIKE '%PIN_VERSION_EXPIRED%', SQLERRM);
    END;
    SELECT encrypted_password INTO v_enc FROM auth.users WHERE id = v_ub;
    PERFORM tests.expect('expired v1 was NOT upgraded',
        tests.crypt_matches('madjana$2222', v_enc)
        AND NOT tests.crypt_matches(public.app_password_from_pin_v2('2222'), v_enc));

    -- ── behavioural: v1 with grace GUC unset -> fail closed ────────────────
    PERFORM set_config('app.v1_grace_until', '', true);
    BEGIN
        PERFORM public.record_login_success(v_uc, '3333');
        PERFORM tests.expect('v1 with no grace GUC refused (fail closed)',
            false, 'no exception');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('v1 with no grace GUC refused (fail closed)',
            SQLERRM LIKE '%PIN_VERSION_EXPIRED%', SQLERRM);
    END;

    -- ── behavioural: v2 user logs in, and the success resets the lockout ──
    PERFORM public.record_login_success(v_ud, '4444');
    SELECT count(*) INTO v_cnt FROM public.users
     WHERE id = v_ud AND failed_attempts = 0 AND locked_until IS NULL;
    PERFORM tests.expect('v2 login succeeds and resets the lockout counters',
        v_cnt = 1, 'failed_attempts/locked_until not reset');

    BEGIN
        PERFORM public.record_login_success(v_ud, '0000');
        PERFORM tests.expect('v2 wrong PIN rejected (INVALID_PIN)',
            false, 'no exception');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('v2 wrong PIN rejected (INVALID_PIN)',
            SQLERRM LIKE '%INVALID_PIN%', SQLERRM);
    END;
    SELECT encrypted_password INTO v_enc FROM auth.users WHERE id = v_ud;
    PERFORM tests.expect('v2 wrong PIN does not downgrade the hash',
        tests.crypt_matches(public.app_password_from_pin_v2('4444'), v_enc));

    -- ── behavioural: admin_reset_pin now writes v2 (SECURITY DEFINER path) ─
    PERFORM public.admin_reset_pin(v_ud::text, '1357');
    SELECT encrypted_password INTO v_enc FROM auth.users WHERE id = v_ud;
    PERFORM tests.expect('admin_reset_pin stores a v2 hash',
        tests.crypt_matches(public.app_password_from_pin_v2('1357'), v_enc));
    SELECT pin_hash INTO v_enc FROM public.users WHERE id = v_ud;
    PERFORM tests.expect('admin_reset_pin keeps public.users.pin_hash in v2',
        tests.crypt_matches(public.app_password_from_pin_v2('1357'), v_enc));

    RAISE NOTICE 'M6a behavioural block passed';
END $$;

-- ── idempotency: re-run M6a's DDL exactly as a re-apply would ──────────────
SET ROLE postgres;

CREATE OR REPLACE FUNCTION public.app_password_from_pin_v2(p_pin text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6aidem$
DECLARE
    v_secret text;
BEGIN
    IF p_pin IS NULL THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;
    v_secret := NULLIF(current_setting('app.pin_secret', true), '');
    IF v_secret IS NULL THEN
        RAISE EXCEPTION 'PIN_SECRET_NOT_CONFIGURED: app.pin_secret غير مضبوط';
    END IF;
    RETURN 'madjana$' || p_pin || '$' || v_secret;
END;
$m6aidem$;

REVOKE EXECUTE ON FUNCTION public.app_password_from_pin_v2(text)
    FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.record_login_success(uuid);
CREATE OR REPLACE FUNCTION public.record_login_success(p_uid uuid, p_pin text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6aidem$
DECLARE
    v_enc      text;
    v_v2       text;
    v_grace    text;
    v_grace_ts timestamptz;
BEGIN
    IF p_uid IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: معرف غير صالح';
    END IF;
    IF p_pin IS NULL OR p_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'الرمز يجب أن يكون 4 أرقام';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.users
                    WHERE id = p_uid AND is_active = true) THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: معرف غير صالح';
    END IF;
    SELECT encrypted_password INTO v_enc FROM auth.users WHERE id = p_uid;
    IF v_enc IS NULL OR v_enc = '' THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: لا توجد كلمة مرور لهذا الحساب';
    END IF;
    v_v2 := public.app_password_from_pin_v2(p_pin);
    IF extensions.crypt(v_v2, v_enc) = v_enc THEN
        NULL;
    ELSIF extensions.crypt('madjana$' || p_pin, v_enc) = v_enc THEN
        v_grace := NULLIF(current_setting('app.v1_grace_until', true), '');
        IF v_grace IS NULL THEN
            RAISE EXCEPTION 'PIN_VERSION_EXPIRED: app.v1_grace_until غير مضبوط — الرمز القديم مرفوض';
        END IF;
        v_grace_ts := v_grace::timestamptz;
        IF NOW() > v_grace_ts THEN
            RAISE EXCEPTION 'PIN_VERSION_EXPIRED: الرمز القديم انتهت مهلة ترقيته';
        END IF;
        UPDATE auth.users
           SET encrypted_password = extensions.crypt(v_v2, extensions.gen_salt('bf')),
               updated_at = NOW()
         WHERE id = p_uid;
        UPDATE public.users
           SET pin_hash = extensions.crypt(v_v2, extensions.gen_salt('bf'))
         WHERE id = p_uid;
    ELSE
        RAISE EXCEPTION 'INVALID_PIN: الرمز غير صحيح';
    END IF;
    UPDATE public.users SET
        failed_attempts = 0,
        locked_until = NULL,
        updated_at = NOW()
    WHERE id = p_uid AND is_active = true;
END;
$m6aidem$;

REVOKE EXECUTE ON FUNCTION public.record_login_success(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_login_success(uuid, text) TO authenticated;

DO $m6aidem$
DECLARE
    r record;
    v_prosrc text;
    v_ddl    text;
BEGIN
    FOR r IN
        SELECT n.nspname || '.' || p.proname AS fqn,
               p.prosrc,
               pg_get_function_identity_arguments(p.oid) AS idargs,
               pg_get_function_result(p.oid) AS res
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('admin_create_user', 'create_farm_with_manager',
                             'admin_reset_pin', 'bootstrap_create_farm_and_manager')
           AND p.prokind = 'f'
    LOOP
        IF strpos(r.prosrc, 'public.app_password_from_pin_v2(') > 0 THEN
            CONTINUE;
        END IF;
        IF strpos(r.prosrc, 'public.app_password_from_pin(') = 0 THEN
            RAISE EXCEPTION 'FAIL: % does not call app_password_from_pin()', r.fqn;
        END IF;
        v_prosrc := replace(r.prosrc, 'public.app_password_from_pin(',
                                     'public.app_password_from_pin_v2(');
        v_ddl := format(
            'CREATE OR REPLACE FUNCTION %s(%s) RETURNS %s '
            'LANGUAGE plpgsql SECURITY DEFINER '
            'SET search_path = public, pg_temp AS $m6aidemb$%s$m6aidemb$',
            r.fqn, r.idargs, r.res, v_prosrc);
        EXECUTE v_ddl;
    END LOOP;
END;
$m6aidem$;

SET ROLE test_runner;

DO $$
BEGIN
    PERFORM tests.expect('idempotent: v2 still installed after re-run',
        (SELECT count(*) FROM pg_proc WHERE proname = 'app_password_from_pin_v2') = 1);
    PERFORM tests.expect('idempotent: record_login_success(uuid, text) survives',
        EXISTS (SELECT 1 FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'record_login_success'
                  AND p.pronargs = 2));
    PERFORM tests.expect('idempotent: all 4 writers still on v2 after re-run',
        (SELECT count(*) FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('admin_create_user', 'create_farm_with_manager',
                             'admin_reset_pin', 'bootstrap_create_farm_and_manager')
           AND p.prokind = 'f'
           AND strpos(p.prosrc, 'public.app_password_from_pin_v2(') > 0) = 4);
    PERFORM tests.expect('idempotent: anon is still locked out of v2',
        NOT tests.role_exec('app_password_from_pin_v2', 'anon'));
    RAISE NOTICE 'M6a: all assertions passed.';
END;
$$;

ROLLBACK;
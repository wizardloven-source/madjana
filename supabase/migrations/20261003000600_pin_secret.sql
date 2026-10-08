-- ============================================================================
-- M6a: PIN secret v2 (server-side PIN password) + record_login_success upgrade
-- ============================================================================
-- WHY
--   PIN -> password is today 'madjana$' || pin (public.app_password_from_pin,
--   a bare SQL IMMUTABLE function). The derivation is public, so anyone who
--   obtains a bcrypt hash can brute-force the whole 10,000-pin space offline.
--   M6a moves the salt onto the server: app_password_from_pin_v2 derives
--   'madjana$' || pin || '$' || <app.pin_secret>, where app.pin_secret lives
--   only inside the database (ops sets it via ALTER DATABASE; it is never
--   written to the repo or to a migration).
--
--   Existing hashes must stay usable while clients roll over, so
--   record_login_success() now also VALIDATES the PIN it is given and upgrades
--   legacy v1 hashes to v2 inside a grace window carried by app.v1_grace_until
--   (auto-seeded to NOW() + 7 days when unset). Once the grace date passes --
--   or if the GUC is unset (fail closed) -- a v1 hash is refused and the user
--   must get a PIN reset.
--
--   The four account-writer functions (admin_create_user, admin_reset_pin,
--   create_farm_with_manager, bootstrap_create_farm_and_manager) start storing
--   v2 hashes so every future hash is secret-derived.
--
-- SCOPE (nothing outside this is touched)
--   * creates public.app_password_from_pin_v2(text) and locks it down
--   * replaces record_login_success(uuid) with record_login_success(uuid, text)
--   * rewrites the four writers in place to call v2
--   * carries/bootstraps app.v1_grace_until; never writes app.pin_secret
--
-- SECURITY NOTES (behavioural changes an operator must expect)
--   * app_password_from_pin_v2 is STABLE SECURITY DEFINER and is REVOKEd from
--     PUBLIC, anon and authenticated -- it is a PIN oracle and never exposed.
--   * record_login_success is granted to authenticated ONLY and REVOKEd from
--     PUBLIC (a freshly created function EXECs to PUBLIC by default), as well
--     as from anon. anon never calls it: it is also a PIN oracle.
--   * Deploy order: set app.pin_secret BEFORE or WITH this migration via
--     ALTER ROLE postgres SET app.pin_secret = '...' (works from the Supabase
--     SQL Editor and on self-hosted; ALTER DATABASE ... SET is the fallback
--     for self-hosted). app.v1_grace_until auto-seeds to NOW()+7d below and is
--     persisted with ALTER ROLE postgres (fallback: ALTER DATABASE). If
--     app.pin_secret is unset the v2 computation RAISES and logins/writers
--     fail closed until ops sets it -- the intended fail-closed behaviour.
--   * Client note: the client passes only the 4-digit PIN to
--     record_login_success; the server computes v2. Do NOT keep deriving the
--     v1 password on the client after this migration (see docs/SECURITY.md).
--
-- IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── 1) GUC bootstrap (configuration only; never secrets in the repo) ─────────
DO $m6a$
DECLARE
    v_grace_text text;
    v_grace      timestamptz;
BEGIN
    IF NULLIF(current_setting('app.pin_secret', true), '') IS NULL THEN
        RAISE NOTICE 'M6a: app.pin_secret غير مضبوط بعد — اضبطه أولاً عبر: ALTER ROLE postgres SET app.pin_secret = ''...''';
    END IF;

    v_grace_text := NULLIF(current_setting('app.v1_grace_until', true), '');
    IF v_grace_text IS NULL THEN
        v_grace := NOW() + interval '7 days';
        PERFORM set_config('app.v1_grace_until', v_grace::text, false);
        DECLARE
            v_persisted boolean := false;
        BEGIN
            BEGIN
                -- أساسي: ALTER ROLE (يعمل في Supabase SQL Editor وعلى
                -- self-hosted): يُطبّق على كل جلسة تسجّل دخولها كـ postgres
                EXECUTE format('ALTER ROLE postgres SET app.v1_grace_until = %L',
                               v_grace::text);
                v_persisted := true;
            EXCEPTION
                WHEN insufficient_privilege OR feature_not_supported OR active_sql_transaction THEN
                    -- بديل: ALTER DATABASE (self-hosted بدون امتياز postgres)
                    BEGIN
                        EXECUTE format('ALTER DATABASE %I SET app.v1_grace_until = %L',
                                       current_database(), v_grace::text);
                        v_persisted := true;
                    EXCEPTION
                        WHEN insufficient_privilege OR feature_not_supported OR active_sql_transaction THEN
                            RAISE NOTICE 'M6a: app.v1_grace_until مضبوط لهذه الجلسة فقط — اضبطه دائماً عبر: ALTER ROLE postgres SET app.v1_grace_until = % (أو إن لم يعمل: ALTER DATABASE % SET app.v1_grace_until = %)', v_grace::text, current_database(), v_grace::text;
                    END;
            END;
            IF v_persisted THEN
                RAISE NOTICE 'M6a: app.v1_grace_until = % (مثبَّت على مستوى الدور/القاعدة)', v_grace::text;
            END IF;
        END;
    END IF;
END;
$m6a$;

-- ── 2) v2 derivation, locked down ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.app_password_from_pin_v2(p_pin text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6afn$
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
$m6afn$;

REVOKE EXECUTE ON FUNCTION public.app_password_from_pin_v2(text)
    FROM PUBLIC, anon, authenticated;

-- ── 3) record_login_success validates the PIN and upgrades v1 -> v2 ─────────
DROP FUNCTION IF EXISTS public.record_login_success(uuid);
CREATE OR REPLACE FUNCTION public.record_login_success(p_uid uuid, p_pin text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6afn$
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
        NULL; -- already a v2 hash; nothing to upgrade
    ELSIF extensions.crypt('madjana$' || p_pin, v_enc) = v_enc THEN
        -- legacy v1 hash is only valid inside the grace window
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
$m6afn$;

REVOKE EXECUTE ON FUNCTION public.record_login_success(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_login_success(uuid, text) TO authenticated;

-- ── 4) the four writers store v2 hashes from now on ─────────────────────────
DO $m6a$
DECLARE
    r record;
    v_prosrc text;
    v_ddl    text;
BEGIN
    FOR r IN
        SELECT p.oid,
               n.nspname || '.' || p.proname AS fqn,
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
            CONTINUE; -- already upgraded by an earlier run (idempotent)
        END IF;
        IF strpos(r.prosrc, 'public.app_password_from_pin(') = 0 THEN
            RAISE EXCEPTION 'FAIL: % does not call app_password_from_pin()', r.fqn;
        END IF;
        v_prosrc := replace(r.prosrc, 'public.app_password_from_pin(',
                                     'public.app_password_from_pin_v2(');
        IF strpos(v_prosrc, 'public.app_password_from_pin_v2(') = 0 THEN
            RAISE EXCEPTION 'FAIL: rewrite produced no v2 call for %', r.fqn;
        END IF;
        v_ddl := format(
            'CREATE OR REPLACE FUNCTION %s(%s) RETURNS %s '
            'LANGUAGE plpgsql SECURITY DEFINER '
            'SET search_path = public, pg_temp AS $m6afn$%s$m6afn$',
            r.fqn, r.idargs, r.res, v_prosrc);
        EXECUTE v_ddl;
    END LOOP;
END;
$m6a$;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m6a$
DECLARE
    v_n int;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc
                    WHERE proname = 'app_password_from_pin_v2'
                      AND provolatile = 's'
                      AND prosecdef) THEN
        RAISE EXCEPTION 'FAIL: app_password_from_pin_v2 not STABLE SECURITY DEFINER';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc
               WHERE proname = 'app_password_from_pin_v2'
                 AND proconfig IS DISTINCT FROM ARRAY['search_path=public, pg_temp']) THEN
        RAISE EXCEPTION 'FAIL: v2 search_path not pinned';
    END IF;

    IF has_function_privilege('anon', 'public.app_password_from_pin_v2(text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.app_password_from_pin_v2(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: v2 leaked to an API role';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_login_success'
      AND p.pronargs = 2
      AND format_type(p.proargtypes[0], NULL) = 'uuid'
      AND format_type(p.proargtypes[1], NULL) = 'text';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: record_login_success(uuid, text) not installed';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_login_success'
      AND p.pronargs = 1;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: record_login_success(uuid) still present';
    END IF;

    IF NOT has_function_privilege('authenticated', 'public.record_login_success(uuid, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: authenticated lost EXECUTE on record_login_success';
    END IF;
    IF has_function_privilege('anon', 'public.record_login_success(uuid, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: anon can call record_login_success (PIN oracle)';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('admin_create_user', 'create_farm_with_manager',
                        'admin_reset_pin', 'bootstrap_create_farm_and_manager')
      AND p.prokind = 'f'
      AND strpos(p.prosrc, 'public.app_password_from_pin_v2(') > 0;
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FAIL: % writers target v2, expected 4', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('admin_create_user', 'create_farm_with_manager',
                        'admin_reset_pin', 'bootstrap_create_farm_and_manager')
      AND p.prokind = 'f'
      AND strpos(p.prosrc, 'public.app_password_from_pin(') > 0;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: % writers still call v1', v_n;
    END IF;

    RAISE NOTICE 'OK: M6a verified - v2 installed, 4 writers write v2, record_login_success validates PIN';
END;
$m6a$;
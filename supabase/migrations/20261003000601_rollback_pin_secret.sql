-- ============================================================================
-- M6a ROLLBACK -- undo the v2 PIN scheme
-- ============================================================================
--  Scope guard: refuses the rollback when any existing hash cannot be proven
--  to be v1-compatible. bcrypt hashes carry no scheme marker, so "v1 or v2?"
--  is only decidable by trying the whole 10,000-pin space against the stored
--  hash. If no v1 candidate matches, the user would be stranded after the
--  rollback (the restored v1 verifier can never accept them) -- so we refuse.
--
--  Cost honesty: per-user worst case is 10,000 crypt() calls (pgcrypto bf
--  default cost 6 -> ~2-5 ms each, so up to ~50 s per orphan). The REFUSAL
--  fires on the FIRST orphan found; scanning is only fully run when every
--  hash really is v1 (i.e. the safe direction). More than 500 hashes to
--  inspect, or an unexpected hash format, also refuses and asks for manual
--  rollback. Any statement_timeout mid-scan aborts the whole transaction
--  (nothing below runs), which is the safe direction too.
--
--  On top of the guard, this file:
--      * restores the four writers to v1 (app_password_from_pin)
--      * restores record_login_success(uuid) body + anon/authenticated grants
--      * drops app_password_from_pin_v2
--      * resets app.pin_secret / app.v1_grace_until for this session and
--        tells ops to unset them at the database level, so v2 cannot be
--        produced again from new sessions
--
--  IDEMPOTENT. RE-RUN SAFE. NO USER DATA IS MODIFIED.
-- ============================================================================

BEGIN;

-- ── guard: every hash must be v1-compatible ─────────────────────────────────
DO $m6r$
DECLARE
    v_uid uuid;
    v_enc text;
    v_pin text;
    v_matched boolean;
    v_checked int := 0;
BEGIN
    IF (SELECT count(*) FROM auth.users
         WHERE encrypted_password IS NOT NULL AND encrypted_password <> '') > 500 THEN
        RAISE EXCEPTION 'REFUSED: more than 500 password hashes to verify — do a manual rollback';
    END IF;

    FOR v_uid, v_enc IN
        SELECT id, encrypted_password FROM auth.users
         WHERE encrypted_password IS NOT NULL AND encrypted_password <> ''
    LOOP
        IF v_enc NOT LIKE '$2%' THEN
            RAISE EXCEPTION 'REFUSED: user % has an unexpected hash format — manual rollback', v_uid;
        END IF;
        v_matched := false;
        FOR i IN 0..9999 LOOP
            v_pin := lpad(i::text, 4, '0');
            IF extensions.crypt('madjana$' || v_pin, v_enc) = v_enc THEN
                v_matched := true;
                EXIT;
            END IF;
        END LOOP;
        IF NOT v_matched THEN
            RAISE EXCEPTION 'REFUSED: user % has no v1-compatible hash (v2-only?) — manual rollback', v_uid;
        END IF;
        v_checked := v_checked + 1;
    END LOOP;

    RAISE NOTICE 'M6a rollback: verified % existing hashes are v1-compatible', v_checked;
END;
$m6r$;

-- ── 1) restore the four writers to v1 ──────────────────────────────────────
DO $m6r$
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
        IF strpos(r.prosrc, 'public.app_password_from_pin(') > 0 THEN
            CONTINUE; -- already v1 (idempotent)
        END IF;
        IF strpos(r.prosrc, 'public.app_password_from_pin_v2(') = 0 THEN
            RAISE EXCEPTION 'FAIL: % has no v2 call to undo', r.fqn;
        END IF;
        v_prosrc := replace(r.prosrc, 'public.app_password_from_pin_v2(',
                                     'public.app_password_from_pin(');
        v_ddl := format(
            'CREATE OR REPLACE FUNCTION %s(%s) RETURNS %s '
            'LANGUAGE plpgsql SECURITY DEFINER '
            'SET search_path = public, pg_temp AS $m6rfn$%s$m6rfn$',
            r.fqn, r.idargs, r.res, v_prosrc);
        EXECUTE v_ddl;
    END LOOP;
END;
$m6r$;

-- ── 2) restore record_login_success(uuid) exactly as init.sql wrote it ────
DROP FUNCTION IF EXISTS public.record_login_success(uuid, text);
CREATE OR REPLACE FUNCTION public.record_login_success(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6rfn$
BEGIN
    IF p_uid IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: معرف غير صالح';
    END IF;
    UPDATE public.users SET
        failed_attempts = 0,
        locked_until = NULL,
        updated_at = NOW()
    WHERE id = p_uid AND is_active = true;
END;
$m6rfn$;

GRANT EXECUTE ON FUNCTION public.record_login_success(uuid) TO anon, authenticated;

-- ── 3) drop the v2 derivation ──────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.app_password_from_pin_v2(text);

-- ── 4) unset the GUCs for this session; flag the database-level reset ──────
DO $m6r$
BEGIN
    IF current_setting('app.pin_secret', true) IS NOT NULL THEN
        EXECUTE 'RESET app.pin_secret';
    END IF;
    IF current_setting('app.v1_grace_until', true) IS NOT NULL THEN
        EXECUTE 'RESET app.v1_grace_until';
    END IF;
    RAISE NOTICE 'M6a rollback: امسح السرين إن وُجدا: ALTER ROLE postgres RESET app.pin_secret; ALTER ROLE postgres RESET app.v1_grace_until  (أو على مستوى القاعدة: ALTER DATABASE % RESET app.pin_secret; ALTER DATABASE % RESET app.v1_grace_until)', current_database(), current_database();
END;
$m6r$;

COMMIT;

-- ============================================================================
-- VERIFICATION (after COMMIT: a failure here never rolls the work back)
-- ============================================================================
DO $m6r$
DECLARE
    v_n int;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'app_password_from_pin_v2') THEN
        RAISE EXCEPTION 'FAIL: app_password_from_pin_v2 outlived the rollback';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_login_success'
      AND p.pronargs = 1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FAIL: record_login_success(uuid) not restored';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_login_success'
      AND p.pronargs = 2;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: record_login_success(uuid, text) outlived the rollback';
    END IF;

    IF NOT has_function_privilege('anon', 'public.record_login_success(uuid)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.record_login_success(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL: record_login_success(uuid) lost its original grants';
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('admin_create_user', 'create_farm_with_manager',
                        'admin_reset_pin', 'bootstrap_create_farm_and_manager')
      AND p.prokind = 'f'
      AND strpos(p.prosrc, 'public.app_password_from_pin(') > 0;
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FAIL: % writers back on v1, expected 4', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('admin_create_user', 'create_farm_with_manager',
                        'admin_reset_pin', 'bootstrap_create_farm_and_manager')
      AND p.prokind = 'f'
      AND strpos(p.prosrc, 'public.app_password_from_pin_v2(') > 0;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FAIL: % writers still target v2', v_n;
    END IF;

    RAISE NOTICE 'OK: M6a rolled back cleanly - v1 scheme restored, v2 gone';
END;
$m6r$;
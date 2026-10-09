-- ============================================================================
--  p0_schema_version_test.sql
--  حارس إصدار مخطط الخادم (M9) — الجدول، الصف، الدالة، RLS، والتراجع.
-- ============================================================================
--
--  PURPOSE
--  -------
--  M9 (20261003000900) introduced the client/server schema-version contract:
--
--      * `public.app_schema_version`  — single-row version marker, metadata
--        only, deliberately NOT in `sync_table_registry` (never replicated);
--      * `current_schema_version()`   — safe-to-call RPC the apps use at boot,
--        SECURITY DEFINER, STABLE, pinned `search_path`;
--      * RLS `app_schema_version_read` — `USING (true)` by design (a version
--        number is not farm data); `anon` is granted nothing.
--
--  The client compares that number against its LOCAL schema version
--  (`_dbVersion` stored in `local_schema_meta`, DB v30). Boot gate + Sync
--  Center display are documented in docs/SYNC.md.
--
--  This file proves, in order: the built database carries the marker; the
--  function and RLS behave; the migration is idempotent (re-apply is a
--  no-op); the rollback removes it all; and a re-apply brings it back.
--
--  HOW TO RUN (exactly like every other suite in run_all.py):
--
--      psql -h 127.0.0.1 -p 5433 -U postgres -d madjana_test \
--           -v ON_ERROR_STOP=1 \
--           -c "SET ROLE test_runner" \
--           -f p0_schema_version_test.sql
--
--  MUST run as a NON-SUPERUSER (test_runner). RLS is not FORCE anywhere, so
--  as `postgres` the read-open policy would still hide nothing and this file
--  would prove nothing.
--
--  Everything runs inside BEGIN/ROLLBACK, so the DB is untouched afterwards.
-- ============================================================================

BEGIN;

-- ============================================================================
--  Harness — self-contained (same contract as p0_financial_rls_guard_test.sql).
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS tests;

CREATE OR REPLACE FUNCTION tests.set_user(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
        true
    );
END;
$$;

CREATE OR REPLACE FUNCTION tests.assert(p_label text, p_cond boolean,
                                        p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond THEN
        RAISE NOTICE 'PASS [%] %', p_label, p_detail;
    ELSE
        RAISE EXCEPTION 'FAIL [%] %', p_label, p_detail;
    END IF;
END;
$$;

-- ============================================================================
--  STEP 0) Preconditions — a test that cannot fail proves nothing
-- ============================================================================
DO $step0$
DECLARE
    v_super boolean;
    v_bypass boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
      FROM pg_roles WHERE rolname = current_user;
    IF v_super OR v_bypass THEN
        RAISE EXCEPTION
            'ABORT: current_user (%) هو superuser أو BYPASSRLS — النتائج ستكون '
            'كاذبة. شغّل هذا الملف كـ test_runner.', current_user;
    END IF;
    RAISE NOTICE 'STEP0: current_user=% super=% bypassrls=%',
                 current_user, v_super, v_bypass;

    PERFORM tests.assert('M9: جدول app_schema_version موجود',
        to_regclass('public.app_schema_version') IS NOT NULL, '');
    PERFORM tests.assert('M9: دالة current_schema_version موجودة',
        EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'current_schema_version'),
        '');
    PERFORM tests.assert('M9: جدول العلامات فيه صف واحد بالضبط',
        (SELECT count(*) FROM public.app_schema_version) = 1,
        format('rows=%s', (SELECT count(*) FROM public.app_schema_version)));
END;
$step0$;

-- ============================================================================
--  STEP 1) الدلالة — الصف، الدالة، RLS، والأذونات
-- ============================================================================
DO $step1$
DECLARE
    v_version int;
    v_min int;
    v_notes text;
    v_pol_ok boolean;
BEGIN
    SELECT version, min_client_version, notes
      INTO v_version, v_min, v_notes
      FROM public.app_schema_version
     LIMIT 1;

    PERFORM tests.assert('M9: الصف هو (version=1, min_client_version=1, initial)',
        v_version = 1 AND v_min = 1 AND v_notes = 'initial',
        format('v=%s min=%s notes=%s', v_version, v_min, v_notes));

    PERFORM tests.assert('M9: applied_at مُسقّط بافتراض now()',
        (SELECT applied_at IS NOT NULL FROM public.app_schema_version LIMIT 1), '');

    PERFORM tests.assert('M9: current_schema_version() = 1',
        current_schema_version() = 1,
        format('res=%s', current_schema_version()));

    -- أي مستخدم authenticated يقرأ (السياسة USING(true) ليست مرتبطة بالهوية).
    PERFORM tests.set_user('00000000-0000-0000-0000-0000000000ff');
    PERFORM tests.assert('M9: أي authenticated يقرأ الجدول',
        (SELECT count(*) FROM public.app_schema_version) = 1, '');

    -- anon لا يملك شيئاً: لا SELECT على الجدول ولا EXECUTE على الدالة.
    PERFORM tests.assert('M9: anon بلا SELECT على الجدول',
        NOT has_table_privilege('anon', 'public.app_schema_version', 'SELECT'), '');
    PERFORM tests.assert('M9: anon بلا EXECUTE على الدالة',
        NOT has_function_privilege('anon', 'public.current_schema_version()', 'EXECUTE'), '');

    -- authenticated يملك الثنائي.
    PERFORM tests.assert('M9: authenticated يملك SELECT + EXECUTE',
        has_table_privilege('authenticated', 'public.app_schema_version', 'SELECT')
        AND has_function_privilege('authenticated', 'public.current_schema_version()', 'EXECUTE'),
        '');

    -- السياسة: FOR SELECT TO authenticated USING (true).
    SELECT EXISTS (
        SELECT 1 FROM pg_policies
         WHERE schemaname = 'public' AND tablename = 'app_schema_version'
           AND policyname = 'app_schema_version_read'
           AND cmd = 'SELECT'
           AND roles::text LIKE '%authenticated%'
           AND coalesce(qual, '') ILIKE '%true%'
    ) INTO v_pol_ok;
    PERFORM tests.assert('M9: سياسة app_schema_version_read (SELECT TO authenticated USING true)',
        v_pol_ok, '');

    -- جدول واصف لا يُزامن أبداً.
    PERFORM tests.assert('M9: الجدول ليس في sync_table_registry',
        NOT EXISTS (SELECT 1 FROM public.sync_table_registry
                     WHERE table_name = 'app_schema_version'), '');
END;
$step1$;

-- ============================================================================
--  STEP 2) إعادة تطبيق الـ forward — idempotent
--  Replays 20261003000900 verbatim as a re-apply would (DDL under SET ROLE
--  postgres, exactly like STEP 11 of p0_financial_rls_guard_test.sql).
-- ============================================================================
SET ROLE postgres;

CREATE TABLE IF NOT EXISTS public.app_schema_version (
    version integer NOT NULL PRIMARY KEY,
    min_client_version integer NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    notes text
);

INSERT INTO public.app_schema_version (version, min_client_version, notes)
VALUES (1, 1, 'initial')
ON CONFLICT (version) DO NOTHING;

CREATE OR REPLACE FUNCTION public.current_schema_version()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT version
      FROM public.app_schema_version
     ORDER BY version DESC
     LIMIT 1;
$$;

GRANT SELECT ON public.app_schema_version TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_schema_version() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.current_schema_version() FROM PUBLIC;

ALTER TABLE public.app_schema_version ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS app_schema_version_read ON public.app_schema_version;
CREATE POLICY app_schema_version_read ON public.app_schema_version
    FOR SELECT TO authenticated
    USING (true);

DO $step2$
DECLARE
    v_pol int;
BEGIN
    PERFORM tests.assert('M9 re-apply: ما زال صفاً واحداً (ON CONFLICT DO NOTHING)',
        (SELECT count(*) FROM public.app_schema_version) = 1,
        format('rows=%s', (SELECT count(*) FROM public.app_schema_version)));
    PERFORM tests.assert('M9 re-apply: الدالة ما زالت ترجع 1',
        current_schema_version() = 1,
        format('res=%s', current_schema_version()));
    SELECT count(*) INTO v_pol FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'app_schema_version';
    PERFORM tests.assert('M9 re-apply: سياسة واحدة بالضبط', v_pol = 1,
        format('policies=%s', v_pol));
END;
$step2$;

-- ============================================================================
--  STEP 3) التراجع — rollback فعلية
--  Replays 20261003000901_rollback_app_schema_version.sql verbatim.
-- ============================================================================
DROP FUNCTION IF EXISTS public.current_schema_version();

DROP TABLE IF EXISTS public.app_schema_version;

DO $step3$
BEGIN
    PERFORM tests.assert('M9 rollback: الجدول اختفى',
        to_regclass('public.app_schema_version') IS NULL, '');
    PERFORM tests.assert('M9 rollback: الدالة اختفت',
        NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                     WHERE n.nspname = 'public' AND p.proname = 'current_schema_version'),
        '');
END;
$step3$;

-- ============================================================================
--  STEP 4) إعادة التطبيق بعد التراجع — تعود العلامة كاملة
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.app_schema_version (
    version integer NOT NULL PRIMARY KEY,
    min_client_version integer NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    notes text
);

INSERT INTO public.app_schema_version (version, min_client_version, notes)
VALUES (1, 1, 'initial')
ON CONFLICT (version) DO NOTHING;

CREATE OR REPLACE FUNCTION public.current_schema_version()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT version
      FROM public.app_schema_version
     ORDER BY version DESC
     LIMIT 1;
$$;

GRANT SELECT ON public.app_schema_version TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_schema_version() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.current_schema_version() FROM PUBLIC;

ALTER TABLE public.app_schema_version ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS app_schema_version_read ON public.app_schema_version;
CREATE POLICY app_schema_version_read ON public.app_schema_version
    FOR SELECT TO authenticated
    USING (true);

DO $step4$
DECLARE
    v_pol int;
BEGIN
    PERFORM tests.assert('M9 re-apply بعد التراجع: الجدول عاد',
        to_regclass('public.app_schema_version') IS NOT NULL, '');
    PERFORM tests.assert('M9 re-apply بعد التراجع: الدالة عادت وترجع 1',
        current_schema_version() = 1,
        format('res=%s', current_schema_version()));
    SELECT count(*) INTO v_pol FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'app_schema_version';
    PERFORM tests.assert('M9 re-apply بعد التراجع: سياسة واحدة بالضبط', v_pol = 1,
        format('policies=%s', v_pol));
END;
$step4$;

SET ROLE test_runner;

-- ============================================================================
--  النتيجة
-- ============================================================================
DO $final$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'p0_schema_version_test: كل الفحوص PASS';
    RAISE NOTICE 'app_schema_version (1) متاح عبر current_schema_version()،';
    RAISE NOTICE 'RLS مفتوح للقراءة، anon محروم، idempotent مع تراجع سليم.';
    RAISE NOTICE 'ROLLBACK — لا تغيير دائم.';
    RAISE NOTICE '============================================================';
END;
$final$;

ROLLBACK;
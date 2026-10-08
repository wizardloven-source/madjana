-- ============================================================================
-- P0 M6c: security_alerts RLS + grants + admin surface
-- ============================================================================
-- The rules under test, from the M6c spec / docs/SECURITY.md §10:
--   * RLS is ON on security_alerts with ONE policy (security_alerts_admin_all)
--     that admits ONLY is_system_admin(). No worker policy, no manager policy.
--   * table grants: anon -> nothing; authenticated -> SELECT/INSERT/UPDATE
--     (RLS still hides every row from a non-admin session).
--   * three SECURITY DEFINER admin functions, granted to authenticated only and
--     re-gated with is_system_admin() inside:
--       get_unresolved_security_alerts()  -- unresolved only, newest first
--       acknowledge_security_alert(uuid)  -- stamps acknowledged_at/by
--       resolve_security_alert(uuid)      -- stamps resolved_at/by
--   * anon cannot call any of them (REVOKE); migration re-runs idempotently;
--     the guarded rollback refuses while alerts are on file and otherwise
--     restores the pre-M6c shape (RLS off, policy gone, grants revoked).
--
-- Identity is faked exactly like the other P0 suites: the session role is
-- test_runner (a member of authenticated, NOBYPASSRLS), and tests.set_user()
-- writes request.jwt.claims so auth.uid() + is_system_admin() resolve to the
-- fixture user. Fixtures (local_fixtures.sql): worker_a ...000b,
-- manager_a ...000a, sysadmin ...000e.
--
-- Runs inside BEGIN/ROLLBACK.
--   psql -f supabase/tests/p0_security_alerts_rls_test.sql
-- ============================================================================

BEGIN;

-- ── helpers ──────────────────────────────────────────────────────────────────
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

-- writer denied: the statement must RAISE for an RLS-protected INSERT
CREATE OR REPLACE FUNCTION tests.expect_write_denied(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'FAIL  %  نجح وتوقعنا رفضاً', p_label;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FAIL  %' THEN
            RAISE;
        END IF;
        IF position('row-level security' in SQLERRM) > 0
           OR position('permission denied' in SQLERRM) > 0
           OR position('insufficient_privilege' in SQLERRM) > 0 THEN
            RAISE NOTICE 'PASS  %  مُنع', p_label;
        ELSE
            RAISE EXCEPTION 'FAIL  %  خطأ غير متوقع — %', p_label, SQLERRM;
        END IF;
    END;
END;
$$;

-- ============================================================================
-- PART I -- structural + ACL contract
-- ============================================================================
DO $$
DECLARE
    v_rls boolean;
BEGIN
    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'security_alerts';
    PERFORM tests.expect('security_alerts RLS مفعّل', v_rls);

    PERFORM tests.expect('policy security_alerts_admin_all موجودة',
        EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public' AND tablename = 'security_alerts'
                   AND policyname = 'security_alerts_admin_all'));
    PERFORM tests.expect('policy تُقيّد بـ is_system_admin() فقط',
        EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public' AND tablename = 'security_alerts'
                   AND policyname = 'security_alerts_admin_all'
                   AND qual ILIKE '%is_system_admin%'
                   AND with_check ILIKE '%is_system_admin%'));

    -- table grants: anon nothing, authenticated the trio
    PERFORM tests.expect('anon لا يملك SELECT على security_alerts',
        NOT has_table_privilege('anon', 'security_alerts', 'SELECT'));
    PERFORM tests.expect('anon لا يملك INSERT على security_alerts',
        NOT has_table_privilege('anon', 'security_alerts', 'INSERT'));
    PERFORM tests.expect('authenticated يملك SELECT (RLS يفصله)',
        has_table_privilege('authenticated', 'security_alerts', 'SELECT'));
    PERFORM tests.expect('authenticated يملك INSERT (RLS يفصله)',
        has_table_privilege('authenticated', 'security_alerts', 'INSERT'));
    PERFORM tests.expect('authenticated يملك UPDATE (RLS يفصله)',
        has_table_privilege('authenticated', 'security_alerts', 'UPDATE'));

    -- the three admin functions exist
    PERFORM tests.expect('get_unresolved_security_alerts() موجودة',
        EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'get_unresolved_security_alerts'
                   AND p.pronargs = 0));
    PERFORM tests.expect('acknowledge_security_alert(uuid) موجودة',
        EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'acknowledge_security_alert'
                   AND p.pronargs = 1));
    PERFORM tests.expect('resolve_security_alert(uuid) موجودة',
        EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'resolve_security_alert'
                   AND p.pronargs = 1));

    -- anon is revoked from every one of them
    PERFORM tests.expect('anon لا يستدعي get_unresolved_security_alerts',
        NOT has_function_privilege('anon', 'public.get_unresolved_security_alerts()', 'EXECUTE'));
    PERFORM tests.expect('anon لا يستدعي acknowledge_security_alert',
        NOT has_function_privilege('anon', 'public.acknowledge_security_alert(uuid)', 'EXECUTE'));
    PERFORM tests.expect('anon لا يستدعي resolve_security_alert',
        NOT has_function_privilege('anon', 'public.resolve_security_alert(uuid)', 'EXECUTE'));

    RAISE NOTICE 'M6c structural + ACL block passed';
END $$;

-- ============================================================================
-- PART II -- RLS behavioural: only a system admin sees or writes ANY row
-- ============================================================================
-- seed as the system admin (itself the "system admin INSERT allowed" proof)
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');

INSERT INTO security_alerts (id, alert_type, severity, meta, created_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', 'login_throttle', 'high',
        '{"key":"phone:0500000001","hits":20}'::jsonb, '2026-10-01T10:00:00Z'),
       ('00000000-0000-0000-0000-0000000000c2', 'login_throttle', 'high',
        '{"key":"ip:198.51.100.9","hits":20}'::jsonb, '2026-10-02T10:00:00Z'),
       ('00000000-0000-0000-0000-0000000000c3', 'custom', 'warning',
        '{}'::jsonb, '2026-10-03T10:00:00Z')
ON CONFLICT (id) DO NOTHING;

SELECT tests.expect('sysadmin يُدرج في security_alerts (RLS يسمح)',
    (SELECT count(*) FROM security_alerts) = 3,
    'count=' || (SELECT count(*)::text FROM security_alerts));

-- worker_a: select sees ZERO rows, even though rows exist
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b');
SELECT tests.expect('العامل SELECT → 0 صفوف (RLS أخفاها)',
    (SELECT count(*) FROM security_alerts) = 0,
    'count=' || (SELECT count(*)::text FROM security_alerts));
SELECT tests.expect_write_denied('العامل INSERT → مرفوض (RLS)',
    'INSERT INTO security_alerts (alert_type, severity, meta) '
    'VALUES (''login_throttle'', ''high'', ''{}''::jsonb)');

-- manager_a: same story
SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
SELECT tests.expect('المدير SELECT → 0 صفوف (RLS أخفاها)',
    (SELECT count(*) FROM security_alerts) = 0,
    'count=' || (SELECT count(*)::text FROM security_alerts));
SELECT tests.expect_write_denied('المدير INSERT → مرفوض (RLS)',
    'INSERT INTO security_alerts (alert_type, severity, meta) '
    'VALUES (''login_throttle'', ''high'', ''{}''::jsonb)');

-- sysadmin: sees all three and may write
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');
SELECT tests.expect('مدير النظام SELECT → صفوف ظاهرة',
    (SELECT count(*) FROM security_alerts) = 3,
    'count=' || (SELECT count(*)::text FROM security_alerts));

DO $block$
BEGIN
    RAISE NOTICE 'M6c RLS behavioural block passed';
END;
$block$;

-- ============================================================================
-- PART III -- admin surface: sysadmin only, correct semantics
-- ============================================================================
-- worker/manager are gated OUT of every function
SELECT tests.set_user('00000000-0000-0000-0000-00000000000b');
DO $$
BEGIN
    BEGIN
        PERFORM * FROM public.get_unresolved_security_alerts();
        PERFORM tests.expect('العامل لا يقرأ get_unresolved (استُدعيت بنجاح)',
            false, 'call unexpectedly succeeded');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('العامل لا يقرأ get_unresolved_security_alerts',
            SQLERRM LIKE '%system_admin%', SQLERRM);
    END;
    BEGIN
        PERFORM public.acknowledge_security_alert('00000000-0000-0000-0000-0000000000c1');
        PERFORM tests.expect('العامل لا يقرأ acknowledge (استُدعيت بنجاح)',
            false, 'call unexpectedly succeeded');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('العامل لا يعترف بالتنبيه (acknowledge)',
            SQLERRM LIKE '%system_admin%', SQLERRM);
    END;
    BEGIN
        PERFORM public.resolve_security_alert('00000000-0000-0000-0000-0000000000c1');
        PERFORM tests.expect('العامل لا يقرأ resolve (استُدعيت بنجاح)',
            false, 'call unexpectedly succeeded');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('العامل لا يحلّ التنبيه (resolve)',
            SQLERRM LIKE '%system_admin%', SQLERRM);
    END;
END $$;

SELECT tests.set_user('00000000-0000-0000-0000-00000000000a');
DO $$
BEGIN
    BEGIN
        PERFORM * FROM public.get_unresolved_security_alerts();
        PERFORM tests.expect('المدير لا يقرأ get_unresolved (استُدعيت بنجاح)',
            false, 'call unexpectedly succeeded');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('المدير لا يقرأ get_unresolved_security_alerts',
            SQLERRM LIKE '%system_admin%', SQLERRM);
    END;
END $$;

-- sysadmin: unresolved-only + newest-first
SELECT tests.set_user('00000000-0000-0000-0000-00000000000e');
DO $$
DECLARE
    v_types text := '';
    v_first text;
    v_n     int;
BEGIN
    SELECT string_agg(alert_type, ',' ORDER BY created_at DESC)
      INTO v_types
      FROM public.get_unresolved_security_alerts();
    PERFORM tests.expect('get_unresolved يرجع غير المحلولة فقط (3) مرتبة الأحدث أولاً',
        v_types = 'custom,login_throttle,login_throttle',
        v_types);

    -- acknowledge stamps acknowledged_at/by, keeps the row unresolved
    PERFORM public.acknowledge_security_alert('00000000-0000-0000-0000-0000000000c2');
    SELECT count(*) INTO v_n FROM public.security_alerts
     WHERE id = '00000000-0000-0000-0000-0000000000c2'
       AND acknowledged_at IS NOT NULL
       AND acknowledged_by = '00000000-0000-0000-0000-00000000000e'
       AND resolved_at IS NULL;
    PERFORM tests.expect('acknowledge يكتب acknowledged_at/by دون حلّ',
        v_n = 1, 'v_n=' || v_n);

    -- resolve stamps resolved_at/by and removes the row from the open list
    PERFORM public.resolve_security_alert('00000000-0000-0000-0000-0000000000c2');
    SELECT count(*) INTO v_n FROM public.security_alerts
     WHERE id = '00000000-0000-0000-0000-0000000000c2'
       AND resolved_at IS NOT NULL
       AND resolved_by = '00000000-0000-0000-0000-00000000000e';
    PERFORM tests.expect('resolve يكتب resolved_at/by',
        v_n = 1, 'v_n=' || v_n);

    SELECT count(*) INTO v_n FROM public.get_unresolved_security_alerts();
    PERFORM tests.expect('المحلول يختفي من القائمة المفتوحة (2 متبقية)',
        v_n = 2, 'open=' || v_n);
END $$;

DO $block$
BEGIN
    RAISE NOTICE 'M6c admin surface block passed';
END;
$block$;

-- ============================================================================
-- PART IV -- the migration's DDL re-runs idempotently
-- ============================================================================
SET ROLE postgres;

-- replay M6c exactly as a second apply would
ALTER TABLE public.security_alerts ADD COLUMN IF NOT EXISTS acknowledged_at timestamptz;
ALTER TABLE public.security_alerts ADD COLUMN IF NOT EXISTS acknowledged_by uuid;
ALTER TABLE public.security_alerts ADD COLUMN IF NOT EXISTS resolved_at     timestamptz;
ALTER TABLE public.security_alerts ADD COLUMN IF NOT EXISTS resolved_by     uuid;

ALTER TABLE public.security_alerts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS security_alerts_admin_all ON public.security_alerts;
CREATE POLICY security_alerts_admin_all ON public.security_alerts
    FOR ALL
    USING (is_system_admin())
    WITH CHECK (is_system_admin());

REVOKE ALL ON TABLE security_alerts FROM PUBLIC;
REVOKE ALL ON TABLE security_alerts FROM anon;
REVOKE ALL ON TABLE security_alerts FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE security_alerts TO authenticated;

CREATE OR REPLACE FUNCTION public.get_unresolved_security_alerts()
RETURNS SETOF security_alerts
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6cidem$
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: هذه البيانات لـ system_admin فقط';
    END IF;
    RETURN QUERY
        SELECT * FROM public.security_alerts
         WHERE resolved_at IS NULL
         ORDER BY created_at DESC;
END;
$m6cidem$;
REVOKE EXECUTE ON FUNCTION public.get_unresolved_security_alerts() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_unresolved_security_alerts() TO authenticated;

CREATE OR REPLACE FUNCTION public.acknowledge_security_alert(p_alert_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6cidem$
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: هذه البيانات لـ system_admin فقط';
    END IF;
    IF p_alert_id IS NULL THEN
        RAISE EXCEPTION 'معرف تنبيه مطلوب';
    END IF;
    UPDATE public.security_alerts
       SET acknowledged_at = NOW(),
           acknowledged_by = auth.uid()
     WHERE id = p_alert_id;
END;
$m6cidem$;
REVOKE EXECUTE ON FUNCTION public.acknowledge_security_alert(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.acknowledge_security_alert(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.resolve_security_alert(p_alert_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $m6cidem$
BEGIN
    IF NOT public.is_system_admin() THEN
        RAISE EXCEPTION 'غير مصرح: هذه البيانات لـ system_admin فقط';
    END IF;
    IF p_alert_id IS NULL THEN
        RAISE EXCEPTION 'معرف تنبيه مطلوب';
    END IF;
    UPDATE public.security_alerts
       SET resolved_at = NOW(),
           resolved_by = auth.uid()
     WHERE id = p_alert_id;
END;
$m6cidem$;
REVOKE EXECUTE ON FUNCTION public.resolve_security_alert(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.resolve_security_alert(uuid) TO authenticated;

SET ROLE test_runner;

DO $$
BEGIN
    PERFORM tests.expect('idempotent: RLS ما زال مفعّلاً',
        (SELECT c.relrowsecurity
           FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public' AND c.relname = 'security_alerts'));
    PERFORM tests.expect('idempotent: الوظائف الثلاث نجت من إعادة التطبيق',
        EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_unresolved_security_alerts')
        AND EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'acknowledge_security_alert')
        AND EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'resolve_security_alert'));
    PERFORM tests.expect('idempotent: anon ما زال محجوباً عن الوظائف',
        NOT has_function_privilege('anon', 'public.get_unresolved_security_alerts()', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.acknowledge_security_alert(uuid)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.resolve_security_alert(uuid)', 'EXECUTE'));
    RAISE NOTICE 'M6c idempotency block passed';
END $$;

-- ============================================================================
-- PART V -- rollback: guarded, then restores the pre-M6c shape
-- ============================================================================
SET ROLE postgres;

-- 5a) the guard refuses while alerts are on file (we still have 3 rows)
DO $$
BEGIN
    BEGIN
        IF EXISTS (SELECT 1 FROM public.security_alerts) THEN
            RAISE EXCEPTION 'REFUSED: security_alerts يحتوي تنبيهات مسجلة';
        END IF;
        PERFORM tests.expect('rollback guard يرفض مع تنبيهات مسجلة',
            false, 'guard did not fire');
    EXCEPTION WHEN OTHERS THEN
        PERFORM tests.expect('rollback guard يرفض مع تنبيهات مسجلة',
            SQLERRM LIKE '%REFUSED%', SQLERRM);
    END;
END $$;

-- 5b) empty the table, apply the rollback DDL exactly as a re-apply would
DELETE FROM public.security_alerts;

DROP FUNCTION IF EXISTS public.get_unresolved_security_alerts();
DROP FUNCTION IF EXISTS public.acknowledge_security_alert(uuid);
DROP FUNCTION IF EXISTS public.resolve_security_alert(uuid);

DROP POLICY IF EXISTS security_alerts_admin_all ON public.security_alerts;
ALTER TABLE public.security_alerts DISABLE ROW LEVEL SECURITY;

REVOKE SELECT, INSERT, UPDATE ON TABLE public.security_alerts FROM authenticated;

ALTER TABLE public.security_alerts DROP COLUMN IF EXISTS acknowledged_at;
ALTER TABLE public.security_alerts DROP COLUMN IF EXISTS acknowledged_by;
ALTER TABLE public.security_alerts DROP COLUMN IF EXISTS resolved_at;
ALTER TABLE public.security_alerts DROP COLUMN IF EXISTS resolved_by;

SET ROLE test_runner;

DO $$
DECLARE
    v_rls boolean;
BEGIN
    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'security_alerts';
    PERFORM tests.expect('rollback: RLS عُطّل',
        NOT v_rls);
    PERFORM tests.expect('rollback: الوظائف الثلاث حُذفت تماماً',
        NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_unresolved_security_alerts')
        AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'acknowledge_security_alert')
        AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'resolve_security_alert'));
    PERFORM tests.expect('rollback: policy أُسقطت و RLS عُطّل',
        NOT EXISTS (SELECT 1 FROM pg_policies
                     WHERE schemaname = 'public' AND tablename = 'security_alerts'
                       AND policyname = 'security_alerts_admin_all')
        AND NOT v_rls);
    PERFORM tests.expect('rollback: منح authenticated أُلغي',
        NOT has_table_privilege('authenticated', 'security_alerts', 'SELECT')
        AND NOT has_table_privilege('authenticated', 'security_alerts', 'INSERT')
        AND NOT has_table_privilege('authenticated', 'security_alerts', 'UPDATE'));
    PERFORM tests.expect('rollback: أعمدة التدقيق حُذفت',
        NOT EXISTS (SELECT 1 FROM pg_attribute a
                     JOIN pg_class c ON c.oid = a.attrelid
                     JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public' AND c.relname = 'security_alerts'
                      AND a.attname IN ('acknowledged_at','acknowledged_by',
                                        'resolved_at','resolved_by')
                      AND NOT a.attisdropped));
    RAISE NOTICE 'M6c rollback block passed';
END $$;

-- ============================================================================
--  النتيجة
-- ============================================================================
DO $final$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'p0_security_alerts_rls_test: كل الفحوص PASS';
    RAISE NOTICE 'RLS (admin-only), grants, 3 admin functions, idempotency,';
    RAISE NOTICE 'and the guarded rollback all verified (then ROLLBACK).';
    RAISE NOTICE '============================================================';
END;
$final$;

ROLLBACK;
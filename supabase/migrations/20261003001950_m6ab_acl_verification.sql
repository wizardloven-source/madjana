-- ============================================================================
-- Documentation: the correct PUBLIC-exposure ACL check for W2 M6a/M6b
-- ============================================================================
-- The first M6a/M6b verification blocks used
--     has_function_privilege('PUBLIC', 'public.<fn>(...)', 'EXECUTE')
-- which fails at run time with
--     ERROR 42704: role "PUBLIC" does not exist
-- because PUBLIC is not a role that can be named to has_function_privilege: it
-- is the pseudo-grantee 0 inside the ACL. The correct test expands the ACL:
--     aclexplode(COALESCE(proacl, acldefault('f', proowner)))
-- and looks for grantee = 0.
--
-- This file adds no objects and changes nothing; it only asserts the corrected
-- check, and skips any function that is not installed. Safe to apply anywhere.
-- ============================================================================

DO $m6acl$
DECLARE
    v_sigs text[] := ARRAY[
        'public.app_password_from_pin_v2(text)',
        'public.record_login_success(uuid,text)',
        'public.record_security_alert(text,text,jsonb)',
        'public.throttle_exceeded(text)'
    ];
    v_sig text;
    v_oid regprocedure;
BEGIN
    FOREACH v_sig IN ARRAY v_sigs LOOP
        v_oid := to_regprocedure(v_sig);
        CONTINUE WHEN v_oid IS NULL;

        IF EXISTS (
            SELECT 1
              FROM pg_proc p
              CROSS JOIN LATERAL aclexplode(
                  COALESCE(p.proacl, acldefault('f', p.proowner))) a
             WHERE p.oid = v_oid
               AND a.grantee = 0
               AND a.privilege_type = 'EXECUTE'
        ) THEN
            RAISE EXCEPTION 'FAIL: % still grants EXECUTE to PUBLIC (grantee 0)', v_sig;
        END IF;
    END LOOP;

    RAISE NOTICE 'OK: no M6 auth function grants EXECUTE to PUBLIC (grantee 0)';
END;
$m6acl$;

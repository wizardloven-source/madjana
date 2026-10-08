-- Test RAISE NOTICE syntax variants in plpgsql
DO $$
BEGIN
  RAISE NOTICE 'variant A plain args: %, %, %', 'x', 1, true;
END $$;
DO $$
BEGIN
  RAISE NOTICE 'variant B with function call: %', public.current_user_role();
END $$;
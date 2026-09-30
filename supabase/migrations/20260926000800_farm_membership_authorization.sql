-- ══════════════════════════════════════════════════════════════════════════════
-- 20260926000800_-farm_membership_authorization.sql
--
-- PURPOSE
--   Replace the single-active-farm authorization model with a MEMBERSHIP model,
--   matching the domain the app actually implements:
--
--     farm  ─ created by system_admin only, owned by him (all farms, same owner)
--     ├── flock (1..n) ─ each flock has one or more sections (sections_count)
--     ├── manager (a manager may manage MANY farms)
--     └── worker  (a worker  may work at MANY farms)
--
--     worker  -> sees flocks of the farms he belongs to, never another farm's
--     manager -> sees the farms he manages and every flock inside them
--     admin   -> creates farms and assigns managers/workers
--
-- WHAT WAS BROKEN
--   Every RLS policy compared farm_id to current_user_farm_id(), i.e. the ONE
--   farm stored in users.farm_id (the "active" farm chosen in the dropdown).
--   That single column was simultaneously:
--     - the tenancy boundary  -> a manager who belongs to 3 farms could read and
--       write only the active one, and could never see the others.
--     - the sync farm binding -> sync_records_batch stamped farm_id from
--       current_user_farm_id() and ignored the record's real farm entirely.
--       A flock created on the desktop while farm A was selected was written
--       under whatever farm was active at upload time. This is how flock
--       019d8bee (1250 -> 1021 birds, "نديم بركات") ended up filed under
--       الجرار with no trace in audit_log.
--
--   Additional holes closed here:
--     - farms UPDATE policy had NO farm check at all: any manager could rewrite
--       the settings of ANY farm.
--     - app_settings SELECT/UPDATE was `is_system_admin() OR role='manager'`,
--       so every manager could read and rewrite secure.bootstrap_token.
--     - users UPDATE policy let any manager UPDATE ANY user row.
--     - stock_adjustments and sync_table_registry had full grants to anon.
--
-- IDEMPOTENT: safe to re-run.
-- ══════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────────
-- 1. Membership helpers
-- ──────────────────────────────────────────────────────────────────────────────

-- Does the current user belong to this farm at all (manager or worker)?
CREATE OR REPLACE FUNCTION public.user_has_farm_access(p_farm_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
    SELECT p_farm_id IS NOT NULL
       AND (
            public.is_system_admin()
         OR EXISTS (
                SELECT 1 FROM public.user_farms uf
                 WHERE uf.user_id = auth.uid()
                   AND uf.farm_id = p_farm_id
            )
       );
$fn$;

-- Does the current user MANAGE this farm? system_admin manages everything.
CREATE OR REPLACE FUNCTION public.user_manages_farm(p_farm_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
    SELECT p_farm_id IS NOT NULL
       AND (
            public.is_system_admin()
         OR ( public.current_user_role() = 'manager'
              AND EXISTS (
                    SELECT 1 FROM public.user_farms uf
                     WHERE uf.user_id = auth.uid()
                       AND uf.farm_id = p_farm_id
              )
         )
       );
$fn$;

-- Every farm the caller may see. Empty for anon; all farms for system_admin.
CREATE OR REPLACE FUNCTION public.user_farm_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
    SELECT uf.farm_id
      FROM public.user_farms uf
     WHERE uf.user_id = auth.uid()
    UNION
    SELECT f.id FROM public.farms f WHERE public.is_system_admin();
$fn$;

COMMENT ON FUNCTION public.user_has_farm_access(uuid) IS
    'true when the caller belongs to the farm (via user_farms) or is system_admin.';
COMMENT ON FUNCTION public.user_manages_farm(uuid) IS
    'true when the caller is a manager of the farm, or system_admin.';
COMMENT ON FUNCTION public.user_farm_ids() IS
    'all farm ids the caller may read: their memberships, or every farm for admin.';

-- Backstop: every user must have at least the membership matching their active
-- farm. data is already consistent, but this keeps the invariant enforced if a
-- row is ever inserted by a path that bypasses user_farms.
INSERT INTO public.user_farms (user_id, farm_id)
SELECT u.id, u.farm_id
  FROM public.users u
 WHERE u.farm_id IS NOT NULL
   AND u.is_active
   AND NOT EXISTS (SELECT 1 FROM public.user_farms uf
                    WHERE uf.user_id = u.id AND uf.farm_id = u.farm_id)
ON CONFLICT (user_id, farm_id) DO NOTHING;

-- Index the lookup the policies run on every row.
CREATE INDEX IF NOT EXISTS idx_user_farms_user_farm
    ON public.user_farms (user_id, farm_id);

-- ──────────────────────────────────────────────────────────────────────────────
-- 2. Farms: owned by system_admin, managers see only the farms they manage
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.farms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS farms_select_own      ON public.farms;
DROP POLICY IF EXISTS farms_insert_manager  ON public.farms;
DROP POLICY IF EXISTS farms_update_manager  ON public.farms;
DROP POLICY IF EXISTS farms_delete_manager  ON public.farms;
DROP POLICY IF EXISTS farms_select_accessible ON public.farms;
DROP POLICY IF EXISTS farms_insert_admin      ON public.farms;
DROP POLICY IF EXISTS farms_update_managing   ON public.farms;
DROP POLICY IF EXISTS farms_delete_admin      ON public.farms;

-- A manager can read every farm he belongs to -- needed for the farm dropdown
-- to list all of them, not just the active one.
CREATE POLICY farms_select_accessible ON public.farms
    FOR SELECT TO authenticated
    USING (public.user_has_farm_access(id));

-- Only system_admin creates or deletes farms.
CREATE POLICY farms_insert_admin ON public.farms
    FOR INSERT TO authenticated
    WITH CHECK (public.is_system_admin());

-- Managers may edit the settings of the farms they manage. The previous policy
-- had no farm predicate, so ANY manager could rewrite ANY farm.
CREATE POLICY farms_update_managing ON public.farms
    FOR UPDATE TO authenticated
    USING (public.user_manages_farm(id))
    WITH CHECK (public.user_manages_farm(id));

CREATE POLICY farms_delete_admin ON public.farms
    FOR DELETE TO authenticated
    USING (public.is_system_admin());

-- Every farm belongs to the super admin.
UPDATE public.farms f
   SET owner_id = a.uid
  FROM (SELECT u.id AS uid
          FROM public.users u
         WHERE u.role = 'system_admin'
           AND u.is_active
         ORDER BY u.created_at
         LIMIT 1) a
 WHERE f.owner_id IS NULL;

-- ──────────────────────────────────────────────────────────────────────────────
-- 3. user_farms: admin assigns, a manager may staff the farms they manage
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.user_farms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_farms_select_own       ON public.user_farms;
DROP POLICY IF EXISTS user_farms_admin_write     ON public.user_farms;
DROP POLICY IF EXISTS user_farms_admin_delete     ON public.user_farms;
DROP POLICY IF EXISTS user_farms_select_accessible ON public.user_farms;
DROP POLICY IF EXISTS user_farms_insert_admin      ON public.user_farms;
DROP POLICY IF EXISTS user_farms_insert_manager    ON public.user_farms;
DROP POLICY IF EXISTS user_farms_delete_admin      ON public.user_farms;
DROP POLICY IF EXISTS user_farms_delete_manager    ON public.user_farms;

-- See your own memberships; managers see the roster of farms they manage.
CREATE POLICY user_farms_select_accessible ON public.user_farms
    FOR SELECT TO authenticated
    USING (
        public.is_system_admin()
     OR user_id = auth.uid()
     OR public.user_manages_farm(farm_id)
    );

-- system_admin assigns anyone anywhere.
CREATE POLICY user_farms_insert_admin ON public.user_farms
    FOR INSERT TO authenticated
    WITH CHECK (public.is_system_admin());

-- A manager may add or remove staff -- but only inside a farm they manage,
-- and never grant the system_admin role through this path.
CREATE POLICY user_farms_insert_manager ON public.user_farms
    FOR INSERT TO authenticated
    WITH CHECK (
        public.user_manages_farm(farm_id)
        AND NOT EXISTS (
            SELECT 1 FROM public.users u
             WHERE u.id = user_farms.user_id
               AND u.role = 'system_admin'
        )
    );

CREATE POLICY user_farms_delete_admin ON public.user_farms
    FOR DELETE TO authenticated
    USING (public.is_system_admin());

CREATE POLICY user_farms_delete_manager ON public.user_farms
    FOR DELETE TO authenticated
    USING (
        public.user_manages_farm(farm_id)
        AND NOT EXISTS (
            SELECT 1 FROM public.users u
             WHERE u.id = user_farms.user_id
               AND u.role = 'system_admin'
        )
    );

-- ──────────────────────────────────────────────────────────────────────────────
-- 4. Farm-scoped operational tables
--    read/write = membership, delete = manager of that farm
-- ──────────────────────────────────────────────────────────────────────────────

-- Tables carrying their own farm_id.
--   flocks, egg_production, mortality, feed_consumption, feed_received,
--   egg_dispatch, medications, expenses, payments, revenue, opening_balances,
--   stock_adjustments, dispatch_requests, inventory_items, app_notifications,
--   sync_conflicts, audit_log
DO $do$
DECLARE
    t text;
    scoped text[] := ARRAY[
        'flocks','egg_production','mortality','feed_consumption','feed_received',
        'egg_dispatch','medications','expenses','payments','revenue',
        'opening_balances','stock_adjustments','dispatch_requests',
        'inventory_items','app_notifications','sync_conflicts'
    ];
BEGIN
    FOREACH t IN ARRAY scoped LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

        -- clear whatever legacy policy shape this table carried
        EXECUTE format(
            'DO $x$ DECLARE p record; BEGIN
                 FOR p IN SELECT policyname FROM pg_policies
                           WHERE schemaname = ''public'' AND tablename = %L
                 LOOP
                     EXECUTE format(''DROP POLICY IF EXISTS %%I ON public.%%I'', p.policyname, %L);
                 END LOOP;
             END $x$', t, t);

        -- and the names this migration itself creates, so a re-run is a no-op
        EXECUTE format('DROP POLICY IF EXISTS %I_read   ON public.%I', t, t);
        EXECUTE format('DROP POLICY IF EXISTS %I_insert ON public.%I', t, t);
        EXECUTE format('DROP POLICY IF EXISTS %I_update ON public.%I', t, t);
        EXECUTE format('DROP POLICY IF EXISTS %I_delete ON public.%I', t, t);
    END LOOP;
END;
$do$;

-- Membership-scoped read/write; manager-scoped delete.
DO $do$
DECLARE
    t text;
    scoped text[] := ARRAY[
        'flocks','egg_production','mortality','feed_consumption','feed_received',
        'egg_dispatch','medications','expenses','payments','revenue',
        'opening_balances','stock_adjustments','dispatch_requests',
        'inventory_items','app_notifications','sync_conflicts'
    ];
BEGIN
    FOREACH t IN ARRAY scoped LOOP
        EXECUTE format($f$
            CREATE POLICY %1$I_read ON public.%1$I
                FOR SELECT TO authenticated
                USING (public.user_has_farm_access(farm_id));

            CREATE POLICY %1$I_insert ON public.%1$I
                FOR INSERT TO authenticated
                WITH CHECK (public.user_has_farm_access(farm_id));

            CREATE POLICY %1$I_update ON public.%1$I
                FOR UPDATE TO authenticated
                USING (public.user_has_farm_access(farm_id))
                WITH CHECK (public.user_has_farm_access(farm_id));

            CREATE POLICY %1$I_delete ON public.%1$I
                FOR DELETE TO authenticated
                USING (public.user_manages_farm(farm_id));
        $f$, t);
    END LOOP;
END;
$do$;

-- ──────────────────────────────────────────────────────────────────────────────
-- 5. customers: farm members see their farm's customers plus global ones
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS op_select ON public.customers;
DROP POLICY IF EXISTS op_insert ON public.customers;
DROP POLICY IF EXISTS op_update ON public.customers;
DROP POLICY IF EXISTS op_delete ON public.customers;

CREATE POLICY op_select ON public.customers
    FOR SELECT TO authenticated
    USING (public.is_system_admin() OR is_global OR public.user_has_farm_access(farm_id));

CREATE POLICY op_insert ON public.customers
    FOR INSERT TO authenticated
    WITH CHECK (public.user_has_farm_access(farm_id));

-- is_global stays out of reach of non-admins: promoting a customer to global
-- would leak it into every farm.
CREATE POLICY op_update ON public.customers
    FOR UPDATE TO authenticated
    USING (public.is_system_admin() OR is_global OR public.user_has_farm_access(farm_id))
    WITH CHECK (public.is_system_admin() OR NOT is_global);

CREATE POLICY op_delete ON public.customers
    FOR DELETE TO authenticated
    USING (public.is_system_admin() OR public.user_manages_farm(farm_id));

-- ──────────────────────────────────────────────────────────────────────────────
-- 6. inventory_transactions: no farm_id of its own, reach it through the item
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.inventory_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mgr_tx ON public.inventory_transactions;

CREATE POLICY mgr_tx ON public.inventory_transactions
    FOR ALL TO authenticated
    USING (
        public.is_system_admin()
        OR EXISTS (SELECT 1 FROM public.inventory_items i
                    WHERE i.id = inventory_transactions.item_id
                      AND public.user_has_farm_access(i.farm_id))
    )
    WITH CHECK (
        public.is_system_admin()
        OR EXISTS (SELECT 1 FROM public.inventory_items i
                    WHERE i.id = inventory_transactions.item_id
                      AND public.user_manages_farm(i.farm_id))
    );

-- ──────────────────────────────────────────────────────────────────────────────
-- 7. flock_movements: workers move birds inside their farm, managers manage
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.flock_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS flock_movements_select ON public.flock_movements;
DROP POLICY IF EXISTS flock_movements_insert ON public.flock_movements;
DROP POLICY IF EXISTS flock_movements_update ON public.flock_movements;
DROP POLICY IF EXISTS flock_movements_delete ON public.flock_movements;

CREATE POLICY flock_movements_select ON public.flock_movements
    FOR SELECT TO authenticated
    USING (public.user_has_farm_access(farm_id));

CREATE POLICY flock_movements_insert ON public.flock_movements
    FOR INSERT TO authenticated
    WITH CHECK (public.user_has_farm_access(farm_id));

CREATE POLICY flock_movements_update ON public.flock_movements
    FOR UPDATE TO authenticated
    USING (public.user_manages_farm(farm_id))
    WITH CHECK (public.user_manages_farm(farm_id));

CREATE POLICY flock_movements_delete ON public.flock_movements
    FOR DELETE TO authenticated
    USING (public.user_manages_farm(farm_id));

-- ──────────────────────────────────────────────────────────────────────────────
-- 8. audit_log: managers read the log of farms they manage
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_select_manager ON public.audit_log;

CREATE POLICY audit_select_manager ON public.audit_log
    FOR SELECT TO authenticated
    USING (public.user_manages_farm(farm_id));

-- ──────────────────────────────────────────────────────────────────────────────
-- 9. sync_changes: a member pulls only the changes of farms he belongs to
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.sync_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sync_changes_select ON public.sync_changes;

CREATE POLICY sync_changes_select ON public.sync_changes
    FOR SELECT TO authenticated
    USING (public.user_has_farm_access(farm_id));

-- ──────────────────────────────────────────────────────────────────────────────
-- 10. sync_checkpoint / sync_conflicts follow the same rule
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.sync_checkpoint ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sync_checkpoint_read ON public.sync_checkpoint;
CREATE POLICY sync_checkpoint_read ON public.sync_checkpoint
    FOR SELECT TO authenticated
    USING (public.user_has_farm_access(farm_id));

ALTER TABLE public.sync_conflicts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS conflicts_manager ON public.sync_conflicts;
DROP POLICY IF EXISTS conflicts_read    ON public.sync_conflicts;
CREATE POLICY conflicts_read ON public.sync_conflicts
    FOR SELECT TO authenticated
    USING (public.user_has_farm_access(farm_id));

-- ──────────────────────────────────────────────────────────────────────────────
-- 11. users: no more manager-edits-anyone
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS users_select_self  ON public.users;
DROP POLICY IF EXISTS users_update_self  ON public.users;
DROP POLICY IF EXISTS users_select_scoped ON public.users;
DROP POLICY IF EXISTS users_update_scoped ON public.users;

CREATE POLICY users_select_scoped ON public.users
    FOR SELECT TO authenticated
    USING (
        id = auth.uid()
     OR public.is_system_admin()
     OR EXISTS (   -- someone who shares at least one farm with the caller
            SELECT 1
              FROM public.user_farms mine
              JOIN public.user_farms theirs ON theirs.farm_id = mine.farm_id
             WHERE mine.user_id = auth.uid()
               AND theirs.user_id = users.id
        )
    );

-- Self-service edits stay allowed, but a manager may only touch users inside
-- farms they manage, and nobody may hand out the system_admin role here.
CREATE POLICY users_update_scoped ON public.users
    FOR UPDATE TO authenticated
    USING (
        id = auth.uid()
     OR public.is_system_admin()
     OR public.user_manages_farm(users.farm_id)
    )
    WITH CHECK (
        id = auth.uid()
     OR public.is_system_admin()
     OR (
            public.user_manages_farm(users.farm_id)
        AND role <> 'system_admin'
        )
    );

-- ──────────────────────────────────────────────────────────────────────────────
-- 12. app_settings: stop handing every manager the bootstrap token
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS app_settings_manager_select ON public.app_settings;
DROP POLICY IF EXISTS app_settings_manager_update ON public.app_settings;
DROP POLICY IF EXISTS app_settings_manager_write  ON public.app_settings;
DROP POLICY IF EXISTS app_settings_admin_all       ON public.app_settings;
DROP POLICY IF EXISTS app_settings_read_public_keys ON public.app_settings;

CREATE POLICY app_settings_admin_all ON public.app_settings
    FOR ALL TO authenticated
    USING (public.is_system_admin())
    WITH CHECK (public.is_system_admin());

-- A manager may read ordinary settings but never a secure.* key.
CREATE POLICY app_settings_read_public_keys ON public.app_settings
    FOR SELECT TO authenticated
    USING (
        public.is_system_admin()
     OR (public.current_user_role() = 'manager' AND key NOT LIKE 'secure.%')
    );

-- ──────────────────────────────────────────────────────────────────────────────
-- 13. medicines_catalog: global catalog, readable by all, writable by manager
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.medicines_catalog ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS catalog_manager ON public.medicines_catalog;

CREATE POLICY catalog_manager ON public.medicines_catalog
    FOR ALL TO authenticated
    USING (public.is_system_admin() OR public.current_user_role() = 'manager')
    WITH CHECK (public.is_system_admin() OR public.current_user_role() = 'manager');

-- ──────────────────────────────────────────────────────────────────────────────
-- 14. Grants: anon must not touch application tables
-- ──────────────────────────────────────────────────────────────────────────────

-- ──────────────────────────────────────────────────────────────────────────────
-- 13c. feed_consumption bags mode must use the FARM's bag weight
--
--     check_feed_consumption_mode was written as
--         quantity_kg = bags_count * 24
--     which silently only works for farms whose feed_bag_weight_kg is 24. On a
--     50 kg farm (حكمون, نديم بركات) EVERY bags-mode insert failed with
--     "violates check constraint check_feed_consumption_mode", so those farms
--     could only ever enter feed by hand-weight.
--
--     A CHECK constraint cannot reference another table, so the arithmetic moves
--     into a trigger that can read the farm's own setting. The plain sanity
--     checks (positive counts, kg > 0, date <= today) stay as constraints.
-- ──────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.feed_consumption
    DROP CONSTRAINT IF EXISTS check_feed_consumption_mode;

ALTER TABLE public.feed_consumption
    DROP CONSTRAINT IF EXISTS feed_consumption_bags_check;

ALTER TABLE public.feed_consumption
    ADD CONSTRAINT feed_consumption_bags_check
    CHECK (entry_mode <> 'bags' OR (bags_count IS NOT NULL AND bags_count > 0));

CREATE OR REPLACE FUNCTION public.trg_feed_consumption_bag_weight()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
    v_bag_weight numeric;
BEGIN
    IF NEW.entry_mode IS DISTINCT FROM 'bags' THEN
        RETURN NEW;
    END IF;

    SELECT COALESCE(f.feed_bag_weight_kg, 24) INTO v_bag_weight
      FROM public.farms f
     WHERE f.id = NEW.farm_id;

    IF v_bag_weight IS NULL THEN
        RAISE EXCEPTION 'FEED_BAG_WEIGHT_UNKNOWN: cannot resolve farm % for feed_consumption',
              NEW.farm_id;
    END IF;

    IF NEW.quantity_kg IS DISTINCT FROM (NEW.bags_count * v_bag_weight) THEN
        RAISE EXCEPTION
            'FEED_BAG_WEIGHT_MISMATCH: % bags at % kg/bag = % kg, but quantity_kg is %',
            NEW.bags_count, v_bag_weight, NEW.bags_count * v_bag_weight,
            COALESCE(NEW.quantity_kg::text, 'NULL');
    END IF;

    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS feed_consumption_bag_weight ON public.feed_consumption;
CREATE TRIGGER feed_consumption_bag_weight
    BEFORE INSERT OR UPDATE OF entry_mode, bags_count, quantity_kg, farm_id
    ON public.feed_consumption
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_feed_consumption_bag_weight();

-- ──────────────────────────────────────────────────────────────────────────────
-- 13b. prevent_self_privilege_escalation must not block set_active_farm
--
--     The guard reverted NEW.farm_id whenever auth.uid() = NEW.id for a
--     non-admin, assuming only a manager editing somebody else should ever move
--     a user between farms. But set_active_farm() IS a self-update, so the
--     trigger silently undid every farm switch: the RPC returned the OLD
--     farm_id with no error at all, which is why the desktop farm dropdown
--     looked dead.
--
--     The real invariant is membership, not "who issued the UPDATE". A user may
--     only ever point their own farm_id at a farm they belong to -- which is
--     exactly what set_active_farm() checks. So the guard now reverts a self
--     move to a NON-member farm and allows a self move to a member farm. That
--     needs no session flag (a transaction-local flag would stay set for the
--     rest of the transaction and re-open the hole after one RPC call) and it
--     grants the caller nothing set_active_farm does not already grant.
--
--     The role guard below is unchanged: self-escalation stays impossible.
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.prevent_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
BEGIN
    IF auth.uid() = NEW.id AND NOT public.is_system_admin() THEN
        -- Revert only if the target farm is one this user is not a member of.
        IF NEW.farm_id IS DISTINCT FROM OLD.farm_id
           AND NOT EXISTS (SELECT 1 FROM public.user_farms uf
                            WHERE uf.user_id = auth.uid()
                              AND uf.farm_id = NEW.farm_id) THEN
            NEW.farm_id := OLD.farm_id;
        END IF;
        IF NEW.role IS DISTINCT FROM OLD.role THEN
            NEW.role := OLD.role;
        END IF;
    END IF;
    RETURN NEW;
END;
$fn$;

-- ──────────────────────────────────────────────────────────────────────────────
-- 14. Grants: anon must not touch application tables
-- ──────────────────────────────────────────────────────────────────────────────

REVOKE ALL ON public.stock_adjustments    FROM anon;
REVOKE ALL ON public.sync_table_registry  FROM anon;
REVOKE ALL ON public.sync_changes         FROM anon;
REVOKE ALL ON public.sync_checkpoint      FROM anon;
REVOKE ALL ON public.sync_conflicts       FROM anon;
REVOKE ALL ON public.idempotency_log      FROM anon;
REVOKE ALL ON public.audit_log            FROM anon;
REVOKE ALL ON public.app_settings         FROM anon;
REVOKE ALL ON public.user_farms           FROM anon;
REVOKE ALL ON public.users                FROM anon;
REVOKE ALL ON public.farms                FROM anon;
REVOKE ALL ON public.login_throttle       FROM anon;

-- idempotency_log must not be client-writable at all; the RPC writes it.
REVOKE ALL ON public.idempotency_log      FROM authenticated;
REVOKE ALL ON public.sync_table_registry  FROM authenticated;

-- ──────────────────────────────────────────────────────────────────────────────
-- 15. sync_records_batch: honour the record's own farm_id
--
--     The batch used to write v_user_farm (the caller's ACTIVE farm) into every
--     row, so a record created for farm B while farm A was selected was filed
--     under A. Now the record's farm_id is used, and is validated against the
--     caller's MEMBERSHIP -- not against whichever farm happens to be active.
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sync_records_batch(p_records jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
    v_rec            jsonb;
    v_record_id      uuid;
    v_table_name     text;
    v_operation      text;
    v_data           jsonb;
    v_active_farm    uuid;
    v_farm           uuid;   -- farm this record belongs to (from the payload)
    v_user_role      text;
    v_operation_id   text;
    v_device         text;
    v_affected       int := 0;
    v_skipped        int := 0;
    v_errors         int := 0;
    v_result         jsonb := '[]'::jsonb;
    v_new_version    bigint;
    v_prev_version   bigint;
    v_allowed_cols   text[];
    v_real_cols      text[];
    v_cols           text[];
    v_vals           text[];
    v_set_parts      text[];
    v_col            text;
    v_existing_ver   bigint;
    v_row_exists     boolean;
    v_prev_result    jsonb;
    v_id_mismatch    int;
    v_inserted       int;
    v_upd_count      int;
    v_force_worker_id boolean := false;
    v_del_count      int;
    v_schema_broken  text[];
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: not signed in';
    END IF;

    v_active_farm := current_user_farm_id();
    v_user_role   := current_user_role();

    IF v_active_farm IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: no farm bound to this user';
    END IF;

    SELECT array_agg(r.table_name) INTO v_schema_broken
    FROM public.sync_table_registry r
    WHERE to_regclass('public.' || r.table_name) IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = to_regclass('public.' || r.table_name)
                        AND a.attname = 'version'
                        AND a.attnum > 0 AND NOT a.attisdropped);

    FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records) LOOP
        v_record_id    := NULLIF(v_rec->>'record_id', '')::uuid;
        v_table_name   := v_rec->>'table_name';
        v_operation    := upper(v_rec->>'operation');
        v_data         := COALESCE(v_rec->'data', '{}'::jsonb);
        v_operation_id := NULLIF(v_rec->>'operation_id', '');
        v_device       := NULLIF(v_rec->>'device_id', '');
        v_prev_version := NULLIF(v_rec->>'previous_version', '')::bigint;
        v_force_worker_id := false;

        IF v_record_id IS NULL OR v_table_name IS NULL
           OR v_operation NOT IN ('INSERT','UPDATE','DELETE') THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', COALESCE(v_rec->>'record_id', ''),
                'table_name', COALESCE(v_table_name, ''),
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'invalid record shape'
            );
            CONTINUE;
        END IF;

        IF NOT public.sync_can_write(v_user_role, v_table_name) THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'AUTHORIZATION_DENIED: role may not write ' || v_table_name
            );
            CONTINUE;
        END IF;

        -- ── THE FIX ──────────────────────────────────────────────────────────
        -- Take the farm from the record itself; fall back to the caller's active
        -- farm only for legacy clients that omit it. Either way the farm must be
        -- one the caller BELONGS to. Before this, the farm was never read from
        -- the payload and always came from current_user_farm_id(), so a record
        -- was silently re-homed to whichever farm was selected at upload time.
        v_farm := COALESCE(
            NULLIF(v_data->>'farm_id', '')::uuid,
            NULLIF(v_rec->>'farm_id', '')::uuid,
            v_active_farm
        );

        IF v_farm IS NULL THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'AUTHORIZATION_DENIED: record has no farm and caller has no active farm'
            );
            CONTINUE;
        END IF;

        IF NOT public.user_has_farm_access(v_farm) THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'AUTHORIZATION_DENIED: not a member of farm ' || v_farm::text
            );
            CONTINUE;
        END IF;
        -- ─────────────────────────────────────────────────────────────────────

        IF v_operation_id IS NOT NULL THEN
            SELECT r.result INTO v_prev_result
            FROM public.idempotency_log r
            WHERE r.operation_id = v_operation_id
              AND r.user_id   = auth.uid()
              AND r.farm_id    = v_farm
              AND r.table_name = v_table_name
              AND r.record_id  = v_record_id
              AND r.operation  = v_operation
              AND r.status     = 'done'
            LIMIT 1;

            IF v_prev_result IS NOT NULL THEN
                v_skipped := v_skipped + 1;
                v_result  := v_result || v_prev_result;
                CONTINUE;
            END IF;

            SELECT 1 INTO v_id_mismatch
            FROM public.idempotency_log r
            WHERE r.operation_id = v_operation_id
              AND NOT (r.user_id   IS NOT DISTINCT FROM auth.uid()
                   AND r.farm_id    IS NOT DISTINCT FROM v_farm
                   AND r.table_name = v_table_name
                   AND r.record_id  IS NOT DISTINCT FROM v_record_id
                   AND r.operation  = v_operation)
            LIMIT 1;

            IF v_id_mismatch IS NOT NULL THEN
                v_errors := v_errors + 1;
                v_result := v_result || jsonb_build_object(
                    'record_id', v_record_id,
                    'table_name', v_table_name,
                    'operation_id', v_operation_id,
                    'status', 'error',
                    'message', 'IDEMPOTENCY_MISMATCH: operation_id already used'
                              || ' for a different record'
                );
                CONTINUE;
            END IF;
        END IF;

        IF v_schema_broken IS NOT NULL
           AND v_table_name = ANY(v_schema_broken) THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'SYNC_SCHEMA_MISSING: table ' || v_table_name
                          || ' has no version column - apply'
                          || ' migration 20260926000700_sync_registry.sql'
            );
            CONTINUE;
        END IF;

        CASE v_table_name
            WHEN 'flocks' THEN v_allowed_cols := ARRAY['breed','start_date','initial_count','current_count','status','sections_count'];
            WHEN 'egg_production' THEN v_allowed_cols := ARRAY['flock_id','date','cartons','trays','loose_eggs','total_eggs','broken_eggs','dirty_eggs','tray_weight_kg','section_no','worker_id'];
            WHEN 'mortality' THEN v_allowed_cols := ARRAY['flock_id','date','count','reason','reason_other','notes','image_url','section_no','worker_id'];
            WHEN 'feed_consumption' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','bags_count','quantity_kg','section_no','worker_id'];
            WHEN 'feed_received' THEN v_allowed_cols := ARRAY['flock_id','date','entry_mode','quantity','quantity_kg','feed_type','supplier','invoice_number','notes','price_per_kg','section_no','worker_id'];
            WHEN 'egg_dispatch' THEN v_allowed_cols := ARRAY['flock_id','date','customer_id','cartons','trays','total_eggs','tray_weight_kg','notes','payment_status','worker_id'];
            WHEN 'medications' THEN v_allowed_cols := ARRAY['flock_id','date','type','medicine_name','dosage','administration_route','treatment_days','withdrawal_days','notes','worker_id'];
            WHEN 'expenses' THEN v_allowed_cols := ARRAY['date','category','description','amount','currency','exchange_rate','carton_bundles'];
            WHEN 'inventory_items' THEN v_allowed_cols := ARRAY['name','unit','low_stock_threshold','notes','flock_id'];
            WHEN 'inventory_transactions' THEN v_allowed_cols := ARRAY['item_id','date','type','quantity','note','user_id'];
            WHEN 'opening_balances' THEN v_allowed_cols := ARRAY['eggs_produced','eggs_dispatched','feed_consumed_kg','initial_birds','mortality_count','total_payments','total_revenues','sections'];
            WHEN 'payments' THEN v_allowed_cols := ARRAY['dispatch_id','customer_id','date','price_per_carton','total_due','amount_paid','payment_method','currency','exchange_rate','due_date','notes','manager_id'];
            WHEN 'revenue' THEN v_allowed_cols := ARRAY['date','category','description','amount','currency','exchange_rate','quantity','unit','reference_id','worker_id'];
            WHEN 'stock_adjustments' THEN v_allowed_cols := ARRAY['stock_type','delta_qty','reason','notes','date','manager_id'];
            WHEN 'dispatch_requests'
            THEN v_allowed_cols := CASE
                    WHEN v_user_role = 'manager'
                        THEN ARRAY['flock_id','customer_id','cartons','trays',
                                    'total_eggs','stock_eggs','status','worker_id',
                                    'decided_at','decided_by']
                    ELSE ARRAY['flock_id','customer_id','cartons','trays',
                                'total_eggs','stock_eggs']
                END;
            WHEN 'customers' THEN v_allowed_cols := ARRAY['name','phone','notes'];
            ELSE v_allowed_cols := ARRAY[]::text[];
        END CASE;

        -- farm_id is never a client-writable column: it is decided by the
        -- membership check above, not by the payload.
        v_allowed_cols := array_remove(COALESCE(v_allowed_cols, ARRAY[]::text[]), 'farm_id');

        IF v_user_role <> 'manager' THEN
            IF v_table_name = 'feed_received' THEN
                v_allowed_cols := array_remove(v_allowed_cols, 'price_per_kg');
            ELSIF v_table_name = 'egg_dispatch' THEN
                v_allowed_cols := array_remove(v_allowed_cols, 'payment_status');
            ELSIF v_table_name IN ('flocks', 'customers') THEN
                v_allowed_cols := ARRAY[]::text[];
            END IF;
            IF v_user_role = 'worker' THEN
                -- A worker must not be able to record somebody else's id, but
                -- worker_id is NOT NULL on every operational table. Stripping it
                -- outright made the INSERT fail on the NOT NULL constraint, so a
                -- worker could never log mortality/egg production/feed at all.
                -- It is removed here and re-injected as auth.uid() below.
                v_allowed_cols := array_remove(v_allowed_cols, 'worker_id');
                v_force_worker_id := true;
            END IF;
        END IF;

        SELECT array_agg(c.column_name) INTO v_real_cols
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name   = v_table_name;

        IF v_real_cols IS NOT NULL THEN
            v_allowed_cols := ARRAY(
                SELECT unnest(v_allowed_cols)
                INTERSECT
                SELECT unnest(v_real_cols)
            );
        END IF;

        IF v_operation = 'DELETE' AND v_user_role <> 'manager' THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'error',
                'message', 'AUTHORIZATION_DENIED: delete is manager only'
            );
            CONTINUE;
        END IF;

        BEGIN
            IF v_operation = 'INSERT' THEN
                EXECUTE format(
                    'SELECT 1 FROM %I WHERE id = $1 AND farm_id = $2 LIMIT 1',
                    v_table_name
                ) INTO v_row_exists USING v_record_id, v_farm;

                v_row_exists := (v_row_exists IS NOT NULL);

                IF v_row_exists THEN
                    EXECUTE format(
                        'SELECT version FROM %I WHERE id = $1 AND farm_id = $2',
                        v_table_name
                    ) INTO v_existing_ver USING v_record_id, v_farm;
                END IF;

                v_cols := ARRAY['id','farm_id','version'];
                v_vals := ARRAY[
                    quote_literal(v_record_id::text),
                    quote_literal(v_farm::text),
                    '1'
                ];
                FOR v_col IN SELECT jsonb_object_keys(v_data) LOOP
                    IF v_col = ANY(v_allowed_cols) THEN
                        v_cols := array_append(v_cols, v_col);
                        v_vals := array_append(v_vals, quote_nullable(v_data->>v_col));
                    END IF;
                END LOOP;

                -- A worker always authors as themselves; worker_id was stripped
                -- from the payload above so it cannot be spoofed.
                IF v_force_worker_id
                   AND EXISTS (SELECT 1 FROM information_schema.columns c
                                WHERE c.table_schema = 'public'
                                  AND c.table_name   = v_table_name
                                  AND c.column_name  = 'worker_id') THEN
                    IF 'worker_id' = ANY(v_cols) THEN
                        v_vals[array_position(v_cols, 'worker_id')] := quote_nullable(auth.uid()::text);
                    ELSE
                        v_cols := array_append(v_cols, 'worker_id');
                        v_vals := array_append(v_vals, quote_nullable(auth.uid()::text));
                    END IF;
                END IF;

                IF v_row_exists THEN
                    v_existing_ver := COALESCE(v_existing_ver, 1);

                    v_set_parts := ARRAY[]::text[];
                    FOR v_col IN SELECT jsonb_object_keys(v_data) LOOP
                        IF v_col = ANY(v_allowed_cols) THEN
                            v_set_parts := array_append(v_set_parts,
                                format('%I = %s', v_col, quote_nullable(v_data->>v_col)));
                        END IF;
                    END LOOP;

                    IF array_length(v_set_parts, 1) IS NULL THEN
                        v_skipped := v_skipped + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'table_name', v_table_name,
                            'operation_id', v_operation_id,
                            'status', 'skipped',
                            'message', 'no writable columns in payload'
                        );
                        CONTINUE;
                    END IF;

                    EXECUTE format(
                        'UPDATE %I SET %s, version = version + 1, updated_at = NOW()
                         WHERE id = %s AND farm_id = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote_nullable(v_record_id::text),
                        quote_nullable(v_farm::text)
                    );
                    GET DIAGNOSTICS v_upd_count = ROW_COUNT;

                    IF v_upd_count = 0 THEN
                        v_errors := v_errors + 1;
                        v_result := v_result || jsonb_build_object(
                            'record_id', v_record_id,
                            'table_name', v_table_name,
                            'operation_id', v_operation_id,
                            'status', 'error',
                            'message', 'update affected no rows'
                        );
                        CONTINUE;
                    END IF;

                    v_affected := v_affected + 1;
                    v_new_version := v_existing_ver + 1;
                ELSE
                    EXECUTE format(
                        'INSERT INTO %I (%s) VALUES (%s)',
                        v_table_name,
                        array_to_string(v_cols, ', '),
                        array_to_string(v_vals, ', ')
                    );
                    GET DIAGNOSTICS v_inserted = ROW_COUNT;
                    v_affected := v_affected + 1;
                    v_new_version := 1;
                END IF;

            ELSIF v_operation = 'UPDATE' THEN
                v_set_parts := ARRAY[]::text[];
                FOR v_col IN SELECT jsonb_object_keys(v_data) LOOP
                    IF v_col = ANY(v_allowed_cols) THEN
                        v_set_parts := array_append(v_set_parts,
                            format('%I = %s', v_col, quote_nullable(v_data->>v_col)));
                    END IF;
                END LOOP;

                IF array_length(v_set_parts, 1) IS NULL THEN
                    v_skipped := v_skipped + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'table_name', v_table_name,
                        'operation_id', v_operation_id,
                        'status', 'skipped',
                        'message', 'no writable columns in update'
                    );
                    CONTINUE;
                END IF;

                IF v_prev_version IS NULL THEN
                    EXECUTE format(
                        'UPDATE %I SET %s, version = version + 1, updated_at = NOW()
                         WHERE id = %s AND farm_id = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote_nullable(v_record_id::text),
                        quote_nullable(v_farm::text)
                    );
                ELSE
                    EXECUTE format(
                        'UPDATE %I SET %s, version = version + 1, updated_at = NOW()
                         WHERE id = %s AND farm_id = %s AND version = %s',
                        v_table_name,
                        array_to_string(v_set_parts, ', '),
                        quote_nullable(v_record_id::text),
                        quote_nullable(v_farm::text),
                        v_prev_version
                    );
                END IF;

                GET DIAGNOSTICS v_upd_count = ROW_COUNT;
                IF v_upd_count = 0 THEN
                    v_errors := v_errors + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'table_name', v_table_name,
                        'operation_id', v_operation_id,
                        'status', 'conflict',
                        'message', 'version conflict on update'
                    );
                    CONTINUE;
                END IF;

                v_affected := v_affected + 1;
                v_new_version := COALESCE(v_prev_version, 0) + 1;

            ELSE
                EXECUTE format(
                    'UPDATE %I SET deleted_at = NOW(), version = version + 1
                     WHERE id = %s AND farm_id = %s',
                    v_table_name,
                    quote_nullable(v_record_id::text),
                    quote_nullable(v_farm::text)
                );
                GET DIAGNOSTICS v_del_count = ROW_COUNT;

                IF v_del_count = 0 THEN
                    v_skipped := v_skipped + 1;
                    v_result := v_result || jsonb_build_object(
                        'record_id', v_record_id,
                        'table_name', v_table_name,
                        'operation_id', v_operation_id,
                        'status', 'skipped',
                        'message', 'row not found on server'
                    );
                    CONTINUE;
                END IF;

                v_affected := v_affected + 1;
                v_new_version := 1;
            END IF;

            SELECT sc.server_version INTO v_new_version
            FROM public.sync_changes sc
            WHERE sc.table_name = v_table_name
              AND sc.record_id  = v_record_id
            ORDER BY sc.server_version DESC
            LIMIT 1;

            v_result := v_result || jsonb_build_object(
                'record_id', v_record_id,
                'table_name', v_table_name,
                'operation_id', v_operation_id,
                'status', 'ok',
                'new_version', COALESCE(v_new_version, 1)
            );

            IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                INSERT INTO idempotency_log
                    (operation_id, user_id, farm_id, table_name, record_id, operation, status, result)
                VALUES
                    (v_operation_id, auth.uid(), v_farm, v_table_name,
                     v_record_id, v_operation, 'done',
                     jsonb_build_object('new_version', COALESCE(v_new_version, 1)))
                ON CONFLICT (operation_id) DO NOTHING;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors + 1;
            v_result := v_result || jsonb_build_object(
                'record_id', COALESCE(v_rec->>'record_id', ''),
                'table_name', COALESCE(v_table_name, ''),
                'operation_id', v_operation_id,
                'status', 'error',
                'message', SQLERRM
            );

            IF v_operation_id IS NOT NULL AND length(v_operation_id) > 0 THEN
                INSERT INTO public.idempotency_log
                    (operation_id, user_id, farm_id, table_name, record_id,
                     operation, status, result)
                VALUES
                    (v_operation_id, auth.uid(), v_farm,
                     COALESCE(NULLIF(v_table_name, ''), 'unknown'),
                     COALESCE(v_record_id,
                              '00000000-0000-0000-0000-000000000000'::uuid),
                     COALESCE(v_operation, 'unknown'), 'error',
                     jsonb_build_object('message', SQLERRM))
                ON CONFLICT (operation_id) DO NOTHING;
            END IF;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'affected', v_affected,
        'skipped',  v_skipped,
        'errors',   v_errors,
        'details',  v_result
    );
END;
$fn$;

-- ──────────────────────────────────────────────────────────────────────────────
-- 16. pull_remote_changes: membership instead of "the one active farm"
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.pull_remote_changes(p_farm_id uuid, p_from_version bigint DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
    v_role            text;
    v_latest          bigint;
    v_min_keep        bigint;
    v_changes         jsonb;
    v_operational_only boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHORIZATION_DENIED: not signed in';
    END IF;

    IF NOT public.is_system_admin() THEN
        SELECT public.current_user_role() INTO v_role;

        IF v_role NOT IN ('manager', 'worker') THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: role not allowed to pull';
        END IF;

        -- Membership, not "is this the farm currently selected".
        IF NOT public.user_has_farm_access(p_farm_id) THEN
            RAISE EXCEPTION 'AUTHORIZATION_DENIED: foreign farm';
        END IF;

        IF v_role = 'worker' THEN
            v_operational_only := true;
        END IF;
    END IF;

    SELECT latest_version, purged_below INTO v_latest, v_min_keep
    FROM sync_checkpoint WHERE farm_id = p_farm_id;

    IF v_latest IS NULL THEN
        SELECT COALESCE(MAX(server_version), 0), COALESCE(MIN(server_version), 0)
            INTO v_latest, v_min_keep
        FROM sync_changes WHERE farm_id = p_farm_id;

        IF v_min_keep = 0 THEN
            v_min_keep := v_latest;
        END IF;

        INSERT INTO sync_checkpoint (farm_id, latest_version, purged_below, updated_at)
        VALUES (p_farm_id, v_latest, v_min_keep, NOW())
        ON CONFLICT (farm_id) DO UPDATE SET
            latest_version = EXCLUDED.latest_version,
            purged_below   = EXCLUDED.purged_below,
            updated_at     = NOW();
    END IF;

    IF v_operational_only THEN
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        ) ORDER BY sc.server_version ASC) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND public.sync_can_read('worker', sc.table_name)
          AND sc.server_version > p_from_version
          AND (sc.operation = 'DELETE'
               OR public.sync_live_exists(sc.table_name, sc.record_id, sc.farm_id));

        SELECT COALESCE(MAX(server_version), p_from_version) INTO v_latest
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name)
          AND server_version > p_from_version;

        SELECT COALESCE(MIN(server_version), v_latest) INTO v_min_keep
        FROM sync_changes
        WHERE farm_id = p_farm_id
          AND public.sync_can_read('worker', table_name);
    ELSE
        SELECT jsonb_agg(jsonb_build_object(
            'table_name', sc.table_name,
            'record_id', sc.record_id,
            'operation', sc.operation,
            'payload', sc.payload,
            'server_version', sc.server_version,
            'created_at', sc.created_at
        ) ORDER BY sc.server_version ASC) INTO v_changes
        FROM sync_changes sc
        WHERE sc.farm_id = p_farm_id
          AND public.sync_can_read(COALESCE(v_role, 'system_admin'), sc.table_name)
          AND sc.server_version > p_from_version
          AND (sc.operation = 'DELETE'
               OR public.sync_live_exists(sc.table_name, sc.record_id, sc.farm_id));
    END IF;

    IF p_from_version > 0 AND p_from_version < v_min_keep THEN
        RETURN jsonb_build_object(
            'resync_required', true,
            'message', 'device is older than the retention window; full resync required',
            'latest_version', v_latest
        );
    END IF;

    RETURN jsonb_build_object(
        'resync_required', false,
        'latest_version', v_latest,
        'changes', COALESCE(v_changes, '[]'::jsonb)
    );
END;
$fn$;

-- ──────────────────────────────────────────────────────────────────────────────
-- 17. set_active_farm: membership is mandatory, and refresh the JWT claim
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_active_farm(p_farm_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
    v_farm_uuid   uuid;
    v_user_record record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
    END IF;

    v_farm_uuid := NULLIF(p_farm_id, '')::uuid;
    IF v_farm_uuid IS NULL THEN
        RAISE EXCEPTION 'حدد المدجنة أولاً';
    END IF;

    -- Membership is the only way in, admin included (who owns every farm).
    IF NOT public.user_has_farm_access(v_farm_uuid) THEN
        RAISE EXCEPTION 'أنت غير مرتبط بهذه المدجنة';
    END IF;

    UPDATE public.users
    SET farm_id = v_farm_uuid, updated_at = NOW()
    WHERE id = auth.uid();

    UPDATE auth.users
    SET raw_user_meta_data = raw_user_meta_data
        || jsonb_build_object('farm_id', v_farm_uuid::text)
    WHERE id = auth.uid();

    SELECT * INTO v_user_record FROM public.users WHERE id = auth.uid();
    RETURN to_jsonb(v_user_record);
END;
$fn$;

-- ──────────────────────────────────────────────────────────────────────────────
-- 18. Admin helper: the farms a user may act in (used by the client)
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.my_farms()
RETURNS TABLE (id uuid, name text, feed_bag_weight_kg numeric, eggs_per_carton integer,
                eggs_per_tray integer, default_mortality_rate numeric,
                carton_low_threshold integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
    SELECT f.id, f.name, f.feed_bag_weight_kg, f.eggs_per_carton, f.eggs_per_tray,
           f.default_mortality_rate, f.carton_low_threshold
      FROM public.farms f
     WHERE public.user_has_farm_access(f.id)
     ORDER BY f.name;
$fn$;

COMMIT;

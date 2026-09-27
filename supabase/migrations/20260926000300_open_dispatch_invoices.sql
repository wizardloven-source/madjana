-- ============================================================================
-- 20260926000300 - open an invoice row for every dispatch that lacks one.
--
-- Why
-- ---
-- Every revenue / profitability / receivables figure in the app is derived
-- from the `payments` table. A dispatch produced no `payments` row until a
-- manager registered a collection, so any unpaid dispatch was invisible to
-- those reports: it contributed neither revenue nor an outstanding balance.
-- It simply vanished.
--
-- The Flutter layer now opens a zero-value invoice at dispatch time
-- (SaveDispatchUseCase._openInvoice). This migration backfills the rows that
-- predate that change, so historic dispatches appear in the reports too.
--
-- Zero is the correct value: the analytics take MAX(total_due) per dispatch,
-- so a 0 row neither adds revenue nor double counts. It only makes the
-- dispatch visible, with the real price applied when it is settled.
--
-- manager_id is NOT NULL REFERENCES users(id), so the dispatch's worker_id is
-- reused: a valid user, and semantically "who opened this row".
--
-- Idempotent. Single transaction. ASCII only.
-- ============================================================================

BEGIN;

-- ── 1) تقرير قبل التعديل ───────────────────────────────────────────────
DO $$
DECLARE
    v_dispatches bigint;
    v_without    bigint;
    v_duplicates bigint;
BEGIN
    SELECT count(*) INTO v_dispatches
    FROM egg_dispatch
    WHERE deleted_at IS NULL;

    SELECT count(*) INTO v_without
    FROM egg_dispatch d
    WHERE d.deleted_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM payments p WHERE p.dispatch_id = d.id
      );

    SELECT count(*) INTO v_duplicates
    FROM (
        SELECT dispatch_id
        FROM payments
        WHERE dispatch_id IS NOT NULL
        GROUP BY dispatch_id
        HAVING count(*) > 1
    ) x;

    RAISE NOTICE 'before: % dispatches, % without invoice, % with multiple rows',
        v_dispatches, v_without, v_duplicates;
END;
$$;

-- ── 2) فاتورة بقيمة صفر لكل تخريج بلا أي سجل قبض ────────────────────────
INSERT INTO payments (
    id, farm_id, dispatch_id, customer_id, date,
    price_per_carton, total_due, amount_paid,
    payment_method, currency, notes, manager_id,
    created_at, updated_at, sync_status
)
SELECT
    gen_random_uuid(),
    d.farm_id,
    d.id,
    d.customer_id,
    d.date,
    0, 0, 0,
    'credit', 'dollar',
    'فاتورة تلقائية - بانتظار التسعير',
    d.worker_id,
    COALESCE(d.created_at, NOW()),
    NOW(),
    'synced'
FROM egg_dispatch d
WHERE d.deleted_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM payments p WHERE p.dispatch_id = d.id
  );

-- ── 3) الإبلاغ عن التكرار (لا نحذف: سجلات التقسيم شرعية) ─────────────
-- ملاحظة مقصودة: التخريج الواحد قد يكون له عدة صفوف قبض (تقسيط على دفعات).
-- هذا طبيعي، والتحليلات تتعامل معه عبر MAX(total_due) وSUM(amount_paid).
-- لذلك لا يُدمج شيء هنا. الهدف فقط: منع تضخيم الإيراد.

-- ── 4) تقرير بعد التعديل ──────────────────────────────────────────────
DO $$
DECLARE
    v_without bigint;
BEGIN
    SELECT count(*) INTO v_without
    FROM egg_dispatch d
    WHERE d.deleted_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM payments p WHERE p.dispatch_id = d.id
      );

    IF v_without > 0 THEN
        RAISE WARNING 'still % dispatch(es) without an invoice row', v_without;
    ELSE
        RAISE NOTICE 'after: every live dispatch has an invoice row';
    END IF;
END;
$$;

COMMIT;

-- ═══════════════════════════════════════════════════════
-- Migration 002: المصروفات والمخزون
-- تشغّل عبر: supabase db push أو SQL Editor
-- ═══════════════════════════════════════════════════════

-- ─────────────── جدول المصروفات ───────────────
create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references farms(id) on delete cascade,
  date date not null default current_date,
  category text not null check (category in (
    'electricity', 'water', 'labor', 'maintenance',
    'transport', 'feed', 'medicine', 'other'
  )),
  description text,
  amount numeric(12,2) not null check (amount > 0),
  created_at timestamptz not null default now()
);

comment on table expenses is 'مصروفات التشغيل - للمدير فقط';

alter table expenses enable row level security;

create policy "manager_full_access_expenses"
  on expenses for all
  using (
    farm_id in (select farm_id from users where id = auth.uid() and role = 'manager')
  )
  with check (
    farm_id in (select farm_id from users where id = auth.uid() and role = 'manager')
  );

create index if not exists idx_expenses_farm_date on expenses(farm_id, date);
create index if not exists idx_expenses_category on expenses(category);

-- ─────────────── جدول عناصر المخزون ───────────────
create table if not exists inventory_items (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references farms(id) on delete cascade,
  name text not null,
  unit text not null default 'piece' check (unit in (
    'piece', 'kg', 'liter', 'bag', 'vial', 'box'
  )),
  quantity numeric(12,2) not null default 0 check (quantity >= 0),
  low_stock_threshold numeric(12,2) not null default 5,
  notes text,
  updated_at timestamptz not null default now(),
  unique (farm_id, name)
);

comment on table inventory_items is 'مخزون الأدوية والمستلزمات - للمدير فقط';

alter table inventory_items enable row level security;

create policy "manager_full_access_inventory"
  on inventory_items for all
  using (
    farm_id in (select farm_id from users where id = auth.uid() and role = 'manager')
  )
  with check (
    farm_id in (select farm_id from users where id = auth.uid() and role = 'manager')
  );

create index if not exists idx_inventory_items_farm on inventory_items(farm_id);

-- ─────────────── جدول حركات المخزون ───────────────
create table if not exists inventory_transactions (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references inventory_items(id) on delete cascade,
  date timestamptz not null default now(),
  type text not null check (type in ('in', 'out')),
  quantity numeric(12,2) not null check (quantity > 0),
  note text,
  user_id uuid references users(id)
);

comment on table inventory_transactions is 'حركات إدخال/إخراج المخزون';

alter table inventory_transactions enable row level security;

create policy "manager_full_access_inventory_tx"
  on inventory_transactions for all
  using (
    item_id in (
      select i.id from inventory_items i
      join users u on u.farm_id = i.farm_id
      where u.id = auth.uid() and u.role = 'manager'
    )
  )
  with check (
    item_id in (
      select i.id from inventory_items i
      join users u on u.farm_id = i.farm_id
      where u.id = auth.uid() and u.role = 'manager'
    )
  );

create index if not exists idx_inventory_tx_item on inventory_transactions(item_id, date);

-- ─────────────── تدقيق تلقائي ───────────────
create or replace function audit_expenses_changes()
returns trigger as $$
begin
  insert into audit_log (user_id, action, table_name, record_id, new_values)
  values (
    auth.uid(),
    tg_op,
    'expenses',
    coalesce(new.id, old.id),
    to_jsonb(coalesce(new, old))
  );
  return coalesce(new, old);
end;
$$ language plpgsql security definer;

drop trigger if exists expenses_audit_trigger on expenses;
create trigger expenses_audit_trigger
  after insert or update or delete on expenses
  for each row execute function audit_expenses_changes();

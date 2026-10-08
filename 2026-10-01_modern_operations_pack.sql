-- SATATA X-RAY: Modern Operations Pack
-- Adds: Audit Log, Cash Drawer/Counter Closing, Film Low-Stock Thresholds,
-- Duplicate Patient Check, and secure operational reporting.
-- Run AFTER the existing Satata role/device/expense/owner migrations.

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  action text not null,
  table_name text,
  record_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists idx_audit_logs_created_at on public.audit_logs(created_at desc);
create index if not exists idx_audit_logs_user_created on public.audit_logs(user_id, created_at desc);

alter table public.audit_logs enable row level security;

drop policy if exists "Admins can read audit logs" on public.audit_logs;
create policy "Admins can read audit logs"
on public.audit_logs for select
to authenticated
using ((select public.is_admin()));

create or replace function public.write_audit_log(
  p_action text,
  p_table_name text,
  p_record_id uuid,
  p_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $audit$
begin
  insert into public.audit_logs(user_id,action,table_name,record_id,details)
  values(auth.uid(),p_action,p_table_name,p_record_id,coalesce(p_details,'{}'::jsonb));
end;
$audit$;

create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $trigger$
declare
  rid uuid;
  payload jsonb;
begin
  rid := coalesce((case when TG_OP='DELETE' then OLD.id else NEW.id end), null);
  payload := jsonb_build_object(
    'operation', TG_OP,
    'record', case when TG_OP='DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end
  );
  perform public.write_audit_log(TG_OP, TG_TABLE_NAME, rid, payload);
  return case when TG_OP='DELETE' then OLD else NEW end;
end;
$trigger$;

drop trigger if exists audit_patients on public.patients;
create trigger audit_patients after insert or update or delete on public.patients
for each row execute procedure public.audit_row_change();

drop trigger if exists audit_film_stock on public.film_stock;
create trigger audit_film_stock after insert or update or delete on public.film_stock
for each row execute procedure public.audit_row_change();

drop trigger if exists audit_expenses on public.expenses;
create trigger audit_expenses after insert or update or delete on public.expenses
for each row execute procedure public.audit_row_change();

drop trigger if exists audit_referrer_transactions on public.referrer_transactions;
create trigger audit_referrer_transactions after insert or update or delete on public.referrer_transactions
for each row execute procedure public.audit_row_change();

drop trigger if exists audit_referrer_receivables on public.referrer_receivables;
create trigger audit_referrer_receivables after insert or update or delete on public.referrer_receivables
for each row execute procedure public.audit_row_change();

create table if not exists public.cash_drawers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  drawer_date date not null default current_date,
  opening_cash numeric(12,2) not null default 0,
  expected_cash numeric(12,2) not null default 0,
  actual_cash numeric(12,2),
  difference numeric(12,2),
  status text not null default 'open' check(status in ('open','closed')),
  opened_at timestamptz not null default timezone('utc', now()),
  closed_at timestamptz,
  note text
);

create unique index if not exists ux_cash_drawer_user_date
on public.cash_drawers(user_id, drawer_date);

alter table public.cash_drawers enable row level security;

drop policy if exists "Users can read own cash drawers" on public.cash_drawers;
drop policy if exists "Users can insert own cash drawers" on public.cash_drawers;
drop policy if exists "Users can update own cash drawers" on public.cash_drawers;

create policy "Users can read own cash drawers"
on public.cash_drawers for select to authenticated
using (user_id = auth.uid() or (select public.is_admin()));

create policy "Users can insert own cash drawers"
on public.cash_drawers for insert to authenticated
with check (user_id = auth.uid() or (select public.is_admin()));

create policy "Users can update own cash drawers"
on public.cash_drawers for update to authenticated
using (user_id = auth.uid() or (select public.is_admin()))
with check (user_id = auth.uid() or (select public.is_admin()));

create table if not exists public.film_stock_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  film_size text not null,
  minimum_qty numeric(12,2) not null default 5 check(minimum_qty >= 0),
  updated_at timestamptz not null default timezone('utc', now()),
  unique(user_id, film_size)
);

alter table public.film_stock_settings enable row level security;

drop policy if exists "Users can read own film thresholds" on public.film_stock_settings;
drop policy if exists "Admins manage film thresholds" on public.film_stock_settings;

create policy "Users can read own film thresholds"
on public.film_stock_settings for select to authenticated
using (user_id = auth.uid() or (select public.is_admin()));

create policy "Admins manage film thresholds"
on public.film_stock_settings for all to authenticated
using ((select public.is_admin()) and user_id = auth.uid())
with check ((select public.is_admin()) and user_id = auth.uid());

create or replace function public.find_duplicate_patient(
  p_name text,
  p_age text,
  p_sex text,
  p_xray_type text,
  p_report_date date default current_date
)
returns table(
  id uuid,
  name text,
  age text,
  sex text,
  xray_type text,
  total numeric,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $dup$
  select p.id,p.name,p.age,p.sex,p.xray_type,p.total,p.created_at
  from public.patients p
  where p.user_id = auth.uid()
    and lower(trim(coalesce(p.name,''))) = lower(trim(coalesce(p_name,'')))
    and coalesce(p.age::text,'') = coalesce(p_age,'')
    and lower(coalesce(p.sex,'')) = lower(coalesce(p_sex,''))
    and lower(coalesce(p.xray_type,'')) = lower(coalesce(p_xray_type,''))
    and (p.created_at at time zone 'Asia/Dhaka')::date = p_report_date
  order by p.created_at desc
  limit 5;
$dup$;

grant execute on function public.find_duplicate_patient(text,text,text,text,date) to authenticated;

create or replace function public.get_cash_drawer_summary(
  p_user_id uuid,
  p_drawer_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $cash$
declare
  opening numeric := 0;
  patient_cash numeric := 0;
  ref_cash numeric := 0;
  expense_cash numeric := 0;
  commission_cash numeric := 0;
  expected numeric := 0;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if auth.uid() <> p_user_id and not public.is_admin() then
    raise exception 'Access denied';
  end if;

  select coalesce(opening_cash,0) into opening
  from public.cash_drawers
  where user_id=p_user_id and drawer_date=p_drawer_date
  limit 1;

  select coalesce(sum(paid),0) into patient_cash
  from public.patients
  where user_id=p_user_id
    and (created_at at time zone 'Asia/Dhaka')::date=p_drawer_date;

  select coalesce(sum(case when type in ('payment','adjustment') then amount else 0 end),0)
    into ref_cash
  from public.referrer_receivables
  where user_id=p_user_id
    and (created_at at time zone 'Asia/Dhaka')::date=p_drawer_date;

  select coalesce(sum(amount),0) into expense_cash
  from public.expenses
  where user_id=p_user_id and expense_date=p_drawer_date and lower(payment_method)='cash';

  select coalesce(sum(case when type='paid' then amount else 0 end),0)
    into commission_cash
  from public.referrer_transactions
  where user_id=p_user_id
    and (created_at at time zone 'Asia/Dhaka')::date=p_drawer_date;

  expected := opening + patient_cash + ref_cash - expense_cash - commission_cash;

  return jsonb_build_object(
    'opening_cash',opening,
    'patient_cash',patient_cash,
    'referrer_cash',ref_cash,
    'cash_expense',expense_cash,
    'commission_cash',commission_cash,
    'expected_cash',expected
  );
end;
$cash$;

grant execute on function public.get_cash_drawer_summary(uuid,date) to authenticated;

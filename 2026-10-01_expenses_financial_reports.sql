-- SATATA X-RAY: Expenses + Financial Report
-- Run AFTER the existing Satata migrations.

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  expense_date date not null default current_date,
  category text not null,
  description text,
  amount numeric(12,2) not null check (amount > 0),
  payment_method text not null default 'Cash',
  note text,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists idx_expenses_user_date
  on public.expenses(user_id, expense_date desc);

alter table public.expenses enable row level security;

drop policy if exists "Admins can select own expenses" on public.expenses;
drop policy if exists "Admins can insert own expenses" on public.expenses;
drop policy if exists "Admins can update own expenses" on public.expenses;
drop policy if exists "Admins can delete own expenses" on public.expenses;

create policy "Admins can select own expenses"
on public.expenses for select
to authenticated
using (
  (select public.is_admin())
  and user_id = (select auth.uid())
);

create policy "Admins can insert own expenses"
on public.expenses for insert
to authenticated
with check (
  (select public.is_admin())
  and user_id = (select auth.uid())
);

create policy "Admins can update own expenses"
on public.expenses for update
to authenticated
using (
  (select public.is_admin())
  and user_id = (select auth.uid())
)
with check (
  (select public.is_admin())
  and user_id = (select auth.uid())
);

create policy "Admins can delete own expenses"
on public.expenses for delete
to authenticated
using (
  (select public.is_admin())
  and user_id = (select auth.uid())
);

create or replace function public.get_financial_report(
  p_start date,
  p_end date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $report$
declare
  patient_billing numeric := 0;
  patient_paid numeric := 0;
  patient_due numeric := 0;
  ref_commission_due numeric := 0;
  ref_commission_paid numeric := 0;
  ref_bill_due numeric := 0;
  ref_bill_collected numeric := 0;
  expenses_total numeric := 0;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can generate financial reports';
  end if;

  select
    coalesce(sum(total),0),
    coalesce(sum(paid),0),
    coalesce(sum(due),0)
  into patient_billing, patient_paid, patient_due
  from public.patients
  where user_id=auth.uid()
    and created_at >= p_start::timestamptz
    and created_at < (p_end + 1)::timestamptz;

  select
    coalesce(sum(case when type='due' then amount else 0 end),0),
    coalesce(sum(case when type='paid' then amount else 0 end),0)
  into ref_commission_due, ref_commission_paid
  from public.referrer_transactions
  where user_id=auth.uid()
    and created_at >= p_start::timestamptz
    and created_at < (p_end + 1)::timestamptz;

  select
    coalesce(sum(case when type='bill_due' then amount else 0 end),0),
    coalesce(sum(case when type in ('payment','adjustment') then amount else 0 end),0)
  into ref_bill_due, ref_bill_collected
  from public.referrer_receivables
  where user_id=auth.uid()
    and created_at >= p_start::timestamptz
    and created_at < (p_end + 1)::timestamptz;

  select coalesce(sum(amount),0)
  into expenses_total
  from public.expenses
  where user_id=auth.uid()
    and expense_date between p_start and p_end;

  return jsonb_build_object(
    'patient_billing', patient_billing,
    'patient_paid', patient_paid,
    'patient_due', patient_due,
    'ref_commission_due', ref_commission_due,
    'ref_commission_paid', ref_commission_paid,
    'ref_bill_due', ref_bill_due,
    'ref_bill_collected', ref_bill_collected,
    'expenses_total', expenses_total,
    'net_cash', patient_paid + ref_bill_collected - ref_commission_paid - expenses_total
  );
end;
$report$;

grant execute on function public.get_financial_report(date,date) to authenticated;

-- SATATA X-RAY: Secure Owner Daily POS Report
-- Run AFTER the existing role/device/expense migrations.
-- COUNTER can execute the report function, but raw financial/patient tables remain protected.

alter table public.user_profiles
  add column if not exists owner_whatsapp text;

comment on column public.user_profiles.owner_whatsapp
is 'Owner WhatsApp number used for the Admin/Counter daily POS-style owner report.';

create or replace function public.get_owner_daily_report(
  p_report_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $report$
declare
  active_admin_count integer;
  owner_id uuid;
  owner_email text;
  owner_whatsapp text;

  patient_count bigint := 0;
  patient_billing numeric := 0;
  patient_paid numeric := 0;
  patient_due numeric := 0;
  ref_commission_due numeric := 0;
  ref_commission_paid numeric := 0;
  ref_bill_due numeric := 0;
  ref_bill_collected numeric := 0;
  expenses_total numeric := 0;

  film_14x17 numeric := 0;
  film_10x14 numeric := 0;
  film_8x10 numeric := 0;
  month_patient_paid numeric := 0;
  total_records bigint := 0;
  total_patient_due numeric := 0;
  total_film_stock numeric := 0;
  total_referrer_commission_balance numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.user_profiles
    where id = auth.uid()
      and active = true
  ) then
    raise exception 'Your account is inactive';
  end if;

  /*
    Safety boundary:
    This installation currently has no center/organization_id column.
    Therefore the report may aggregate users only when there is exactly
    one active ADMIN. If multiple centers/admins are later introduced,
    this function stops instead of risking cross-center data exposure.
  */
  select count(*)
    into active_admin_count
  from public.user_profiles
  where role = 'admin'
    and active = true;

  if active_admin_count <> 1 then
    raise exception 'Owner report requires exactly one active ADMIN account. Center scope is not configured for multiple centers.';
  end if;

  select id, email, owner_whatsapp
    into owner_id, owner_email, owner_whatsapp
  from public.user_profiles
  where role = 'admin'
    and active = true
  limit 1;

  /*
    Bangladesh local date is used for timestamp-based daily figures.
  */
  select
    count(*),
    coalesce(sum(total),0),
    coalesce(sum(paid),0),
    coalesce(sum(due),0)
  into patient_count, patient_billing, patient_paid, patient_due
  from public.patients
  where (created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select
    coalesce(sum(case when type = 'due' then amount else 0 end),0),
    coalesce(sum(case when type = 'paid' then amount else 0 end),0)
  into ref_commission_due, ref_commission_paid
  from public.referrer_transactions
  where (created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select
    coalesce(sum(case when type = 'bill_due' then amount else 0 end),0),
    coalesce(sum(case when type in ('payment','adjustment') then amount else 0 end),0)
  into ref_bill_due, ref_bill_collected
  from public.referrer_receivables
  where (created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select coalesce(sum(amount),0)
    into expenses_total
  from public.expenses
  where expense_date = p_report_date;

  /* Dashboard-wide center totals use the same safe one-admin boundary. */
  select
    coalesce(sum(case
      when (created_at at time zone 'Asia/Dhaka')::date >= date_trunc('month', p_report_date)::date
       and (created_at at time zone 'Asia/Dhaka')::date <= p_report_date
      then paid else 0 end),0),
    count(*),
    coalesce(sum(due),0)
  into month_patient_paid, total_records, total_patient_due
  from public.patients;

  select coalesce(sum(
    case
      when lower(trim(type)) = 'in' then quantity
      when lower(trim(type)) = 'out' then -quantity
      else 0
    end
  ),0)
  into total_film_stock
  from public.film_stock
  where (created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select greatest(
    0,
    coalesce(sum(case when type = 'due' then amount else 0 end),0)
    - coalesce(sum(case when type = 'paid' then amount else 0 end),0)
  )
  into total_referrer_commission_balance
  from public.referrer_transactions;

  /*
    Film stock is cumulative through the selected report date.
    Normalize common labels such as 14 × 17, 14x17 and 14 X 17.
  */
  select coalesce(sum(
    case
      when lower(regexp_replace(trim(film_size), '[^0-9]+', 'x', 'g')) = '14x17'
        then case when lower(trim(type)) = 'in' then quantity else -quantity end
      else 0
    end
  ),0)
  into film_14x17
  from public.film_stock
  where (created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(sum(
    case
      when lower(regexp_replace(trim(film_size), '[^0-9]+', 'x', 'g')) = '10x14'
        then case when lower(trim(type)) = 'in' then quantity else -quantity end
      else 0
    end
  ),0)
  into film_10x14
  from public.film_stock
  where (created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(sum(
    case
      when lower(regexp_replace(trim(film_size), '[^0-9]+', 'x', 'g')) = '8x10'
        then case when lower(trim(type)) = 'in' then quantity else -quantity end
      else 0
    end
  ),0)
  into film_8x10
  from public.film_stock
  where (created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  return jsonb_build_object(
    'report_date', p_report_date,
    'owner_email', owner_email,
    'owner_whatsapp', coalesce(owner_whatsapp,''),
    'patient_count', patient_count,
    'patient_billing', patient_billing,
    'patient_paid', patient_paid,
    'patient_due', patient_due,
    'ref_commission_due', ref_commission_due,
    'ref_commission_paid', ref_commission_paid,
    'ref_bill_due', ref_bill_due,
    'ref_bill_collected', ref_bill_collected,
    'expenses_total', expenses_total,
    'net_cash', patient_paid + ref_bill_collected - ref_commission_paid - expenses_total,
    'film_14x17', film_14x17,
    'film_10x14', film_10x14,
    'film_8x10', film_8x10,
    'month_patient_paid', month_patient_paid,
    'total_records', total_records,
    'total_patient_due', total_patient_due,
    'total_film_stock', total_film_stock,
    'total_referrer_commission_balance', total_referrer_commission_balance
  );
end;
$report$;

revoke all on function public.get_owner_daily_report(date) from public;
grant execute on function public.get_owner_daily_report(date) to authenticated;

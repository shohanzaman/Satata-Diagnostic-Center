-- SATATA X-RAY: Owner Daily Report scope fix
-- Run this once in Supabase SQL Editor.
-- The Owner Report and Dashboard must use the same user-scoped data.
-- This installation has no center_id/organization_id, so aggregating every
-- user's rows can include old/test-user data and make the report disagree
-- with the records and film stock visible to the logged-in user.

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
    from public.user_profiles as me
    where me.id = auth.uid()
      and me.active = true
  ) then
    raise exception 'Your account is inactive';
  end if;

  select count(*)
    into active_admin_count
  from public.user_profiles as admins
  where admins.role = 'admin'
    and admins.active = true;

  if active_admin_count <> 1 then
    raise exception 'Owner report requires exactly one active ADMIN account. Center scope is not configured for multiple centers.';
  end if;

  select up.id, up.email, up.owner_whatsapp
    into owner_id, owner_email, owner_whatsapp
  from public.user_profiles as up
  where up.role = 'admin'
    and up.active = true
  limit 1;

  select
    count(*),
    coalesce(sum(p.total),0),
    coalesce(sum(p.paid),0),
    coalesce(sum(p.due),0)
  into patient_count, patient_billing, patient_paid, patient_due
  from public.patients as p
  where p.user_id = auth.uid()
    and (p.created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select
    coalesce(sum(case when rt.type = 'due' then rt.amount else 0 end),0),
    coalesce(sum(case when rt.type = 'paid' then rt.amount else 0 end),0)
  into ref_commission_due, ref_commission_paid
  from public.referrer_transactions as rt
  where rt.user_id = auth.uid()
    and (rt.created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select
    coalesce(sum(case when rr.type = 'bill_due' then rr.amount else 0 end),0),
    coalesce(sum(case when rr.type in ('payment','adjustment') then rr.amount else 0 end),0)
  into ref_bill_due, ref_bill_collected
  from public.referrer_receivables as rr
  where rr.user_id = auth.uid()
    and (rr.created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select coalesce(sum(e.amount),0)
    into expenses_total
  from public.expenses as e
  where e.user_id = auth.uid()
    and e.expense_date = p_report_date;

  select
    coalesce(sum(case
      when (p.created_at at time zone 'Asia/Dhaka')::date >= date_trunc('month', p_report_date)::date
       and (p.created_at at time zone 'Asia/Dhaka')::date <= p_report_date
      then p.paid else 0 end),0),
    count(*),
    coalesce(sum(p.due),0)
  into month_patient_paid, total_records, total_patient_due
  from public.patients as p
  where p.user_id = auth.uid();

  select coalesce(sum(
    case
      when lower(trim(fs0.type)) = 'in' then fs0.quantity
      when lower(trim(fs0.type)) = 'out' then -fs0.quantity
      else 0
    end
  ),0)
  into total_film_stock
  from public.film_stock as fs0
  where fs0.user_id = auth.uid()
    and (fs0.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select greatest(
    0,
    coalesce(sum(case when rt0.type = 'due' then rt0.amount else 0 end),0)
    - coalesce(sum(case when rt0.type = 'paid' then rt0.amount else 0 end),0)
  )
  into total_referrer_commission_balance
  from public.referrer_transactions as rt0
  where rt0.user_id = auth.uid();

  select coalesce(sum(
    case
      when lower(regexp_replace(trim(fs.film_size), '[^0-9]+', 'x', 'g')) = '14x17'
        then case when lower(trim(fs.type)) = 'in' then fs.quantity else -fs.quantity end
      else 0
    end
  ),0)
  into film_14x17
  from public.film_stock as fs
  where fs.user_id = auth.uid()
    and (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(sum(
    case
      when lower(regexp_replace(trim(fs.film_size), '[^0-9]+', 'x', 'g')) = '10x14'
        then case when lower(trim(fs.type)) = 'in' then fs.quantity else -fs.quantity end
      else 0
    end
  ),0)
  into film_10x14
  from public.film_stock as fs
  where fs.user_id = auth.uid()
    and (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(sum(
    case
      when lower(regexp_replace(trim(fs.film_size), '[^0-9]+', 'x', 'g')) = '8x10'
        then case when lower(trim(fs.type)) = 'in' then fs.quantity else -fs.quantity end
      else 0
    end
  ),0)
  into film_8x10
  from public.film_stock as fs
  where fs.user_id = auth.uid()
    and (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

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

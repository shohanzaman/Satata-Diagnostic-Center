-- SATATA X-RAY: Counter center dashboard sync
-- Counter dashboard must see the same center-wide patient and film data
-- without exposing raw tables through RLS.
-- This installation has no center_id/organization_id, so exactly one active
-- ADMIN is treated as the center owner and all authenticated center users
-- are included in the dashboard aggregation.

create or replace function public.get_counter_dashboard_data(
  p_report_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  active_admin_count integer;
  today_patients jsonb;
  recent_patients jsonb;
  film_logs jsonb;
  patient_count bigint := 0;
  patient_paid numeric := 0;
  month_patient_paid numeric := 0;
  total_records bigint := 0;
  total_patient_due numeric := 0;
  total_film_stock numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.active = true
  ) then
    raise exception 'Your account is inactive';
  end if;

  select count(*) into active_admin_count
  from public.user_profiles up
  where up.role = 'admin' and up.active = true;

  if active_admin_count <> 1 then
    raise exception 'Center scope requires exactly one active ADMIN account.';
  end if;

  select
    count(*),
    coalesce(sum(p.paid),0)
  into patient_count, patient_paid
  from public.patients p
  where (p.created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select coalesce(sum(
    case
      when (p.created_at at time zone 'Asia/Dhaka')::date >= date_trunc('month', p_report_date)::date
       and (p.created_at at time zone 'Asia/Dhaka')::date <= p_report_date
      then p.paid else 0
    end
  ),0), count(*), coalesce(sum(p.due),0)
  into month_patient_paid, total_records, total_patient_due
  from public.patients p;

  select coalesce(sum(
    case
      when lower(trim(fs.type))='in' then fs.quantity
      when lower(trim(fs.type))='out' then -fs.quantity
      else 0
    end
  ),0)
  into total_film_stock
  from public.film_stock fs;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
  into recent_patients
  from (
    select p.*
    from public.patients p
    order by p.created_at desc
    limit 20
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
  into film_logs
  from (
    select fs.*
    from public.film_stock fs
    order by fs.created_at desc
    limit 200
  ) x;

  return jsonb_build_object(
    'patient_count', patient_count,
    'patient_paid', patient_paid,
    'month_patient_paid', month_patient_paid,
    'total_records', total_records,
    'total_patient_due', total_patient_due,
    'total_film_stock', total_film_stock,
    'recent_patients', recent_patients,
    'film_logs', film_logs
  );
end;
$$;

revoke all on function public.get_counter_dashboard_data(date) from public;
grant execute on function public.get_counter_dashboard_data(date) to authenticated;

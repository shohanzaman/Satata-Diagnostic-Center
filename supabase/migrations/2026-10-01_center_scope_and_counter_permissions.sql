-- SATATA X-RAY: Center-wide Counter workspace + Counter permissions
-- Single-center architecture: one active ADMIN is the center owner.
-- COUNTER can view shared records/film stock, send Owner WhatsApp reports,
-- and add new X-Ray Types. COUNTER cannot edit/delete existing records.

create or replace function public.get_counter_dashboard_data(
  p_report_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  active_admin_count integer;
  admin_id uuid;
  patient_data jsonb;
  film_data jsonb;
  xray_data jsonb;
  patient_count bigint := 0;
  patient_paid numeric := 0;
  month_patient_paid numeric := 0;
  total_records bigint := 0;
  total_patient_due numeric := 0;
  total_film_stock numeric := 0;
  total_referrer_commission_balance numeric := 0;
  film_14x17 numeric := 0;
  film_10x14 numeric := 0;
  film_8x10 numeric := 0;
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

  select up.id into admin_id
  from public.user_profiles up
  where up.role = 'admin' and up.active = true
  order by up.created_at asc
  limit 1;

  select
    count(*),
    coalesce(sum(p.paid),0)
  into patient_count, patient_paid
  from public.patients p
  where (p.created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select
    coalesce(sum(case
      when (p.created_at at time zone 'Asia/Dhaka')::date >= date_trunc('month', p_report_date)::date
       and (p.created_at at time zone 'Asia/Dhaka')::date <= p_report_date
      then p.paid else 0 end),0),
    count(*),
    coalesce(sum(p.due),0)
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
  from public.film_stock fs
  where (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select greatest(
    0,
    coalesce(sum(case when rt.type='due' then rt.amount else 0 end),0)
    - coalesce(sum(case when rt.type='paid' then rt.amount else 0 end),0)
  )
  into total_referrer_commission_balance
  from public.referrer_transactions rt;

  select coalesce(sum(case
    when lower(regexp_replace(trim(fs.film_size), '[^0-9]+', 'x', 'g'))='14x17'
    then case when lower(trim(fs.type))='in' then fs.quantity else -fs.quantity end
    else 0 end),0)
  into film_14x17
  from public.film_stock fs
  where (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(sum(case
    when lower(regexp_replace(trim(fs.film_size), '[^0-9]+', 'x', 'g'))='10x14'
    then case when lower(trim(fs.type))='in' then fs.quantity else -fs.quantity end
    else 0 end),0)
  into film_10x14
  from public.film_stock fs
  where (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(sum(case
    when lower(regexp_replace(trim(fs.film_size), '[^0-9]+', 'x', 'g'))='8x10'
    then case when lower(trim(fs.type))='in' then fs.quantity else -fs.quantity end
    else 0 end),0)
  into film_8x10
  from public.film_stock fs
  where (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
  into patient_data
  from (
    select p.*
    from public.patients p
    order by p.created_at desc
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
  into film_data
  from (
    select fs.*
    from public.film_stock fs
    order by fs.created_at desc
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb)
  into xray_data
  from (
    select x.*
    from public.xray_types x
    where x.user_id = admin_id
  ) x;

  return jsonb_build_object(
    'patient_count', patient_count,
    'patient_paid', patient_paid,
    'month_patient_paid', month_patient_paid,
    'total_records', total_records,
    'total_patient_due', total_patient_due,
    'total_film_stock', total_film_stock,
    'total_referrer_commission_balance', total_referrer_commission_balance,
    'film_14x17', film_14x17,
    'film_10x14', film_10x14,
    'film_8x10', film_8x10,
    'patients', patient_data,
    'film_logs', film_data,
    'xray_types', xray_data
  );
end;
$$;

revoke all on function public.get_counter_dashboard_data(date) from public;
grant execute on function public.get_counter_dashboard_data(date) to authenticated;

create or replace function public.counter_add_xray_type(
  p_name text,
  p_film_size text,
  p_price numeric default 0,
  p_commission numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_id uuid;
  active_admin_count integer;
  new_row public.xray_types;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid()
      and up.active = true
      and up.role = 'counter'
  ) then
    raise exception 'COUNTER access required';
  end if;

  select count(*) into active_admin_count
  from public.user_profiles up
  where up.role = 'admin' and up.active = true;

  if active_admin_count <> 1 then
    raise exception 'Center scope requires exactly one active ADMIN account.';
  end if;

  select up.id into admin_id
  from public.user_profiles up
  where up.role = 'admin' and up.active = true
  order by up.created_at asc
  limit 1;

  if nullif(trim(coalesce(p_name,'')),'') is null then
    raise exception 'X-Ray name is required';
  end if;

  insert into public.xray_types(user_id,name,film_size,price,commission)
  values(
    admin_id,
    trim(p_name),
    coalesce(nullif(trim(p_film_size),''),'14 × 17'),
    greatest(coalesce(p_price,0),0),
    greatest(coalesce(p_commission,0),0)
  )
  returning * into new_row;

  return to_jsonb(new_row);
end;
$$;

revoke all on function public.counter_add_xray_type(text,text,numeric,numeric) from public;
grant execute on function public.counter_add_xray_type(text,text,numeric,numeric) to authenticated;

-- Center-wide Owner Daily Report.
-- The same center totals are used by ADMIN and COUNTER, including WhatsApp reporting.
create or replace function public.get_owner_daily_report(
  p_report_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
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
    select 1 from public.user_profiles me
    where me.id = auth.uid() and me.active = true
  ) then
    raise exception 'Your account is inactive';
  end if;

  select count(*) into active_admin_count
  from public.user_profiles admins
  where admins.role='admin' and admins.active=true;

  if active_admin_count <> 1 then
    raise exception 'Owner report requires exactly one active ADMIN account.';
  end if;

  select up.id, up.email, up.owner_whatsapp
    into owner_id, owner_email, owner_whatsapp
  from public.user_profiles up
  where up.role='admin' and up.active=true
  order by up.created_at asc
  limit 1;

  select count(*), coalesce(sum(p.total),0), coalesce(sum(p.paid),0), coalesce(sum(p.due),0)
  into patient_count, patient_billing, patient_paid, patient_due
  from public.patients p
  where (p.created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select
    coalesce(sum(case when rt.type='due' then rt.amount else 0 end),0),
    coalesce(sum(case when rt.type='paid' then rt.amount else 0 end),0)
  into ref_commission_due, ref_commission_paid
  from public.referrer_transactions rt
  where (rt.created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select
    coalesce(sum(case when rr.type='bill_due' then rr.amount else 0 end),0),
    coalesce(sum(case when rr.type in ('payment','adjustment') then rr.amount else 0 end),0)
  into ref_bill_due, ref_bill_collected
  from public.referrer_receivables rr
  where (rr.created_at at time zone 'Asia/Dhaka')::date = p_report_date;

  select coalesce(sum(e.amount),0)
  into expenses_total
  from public.expenses e
  where e.expense_date = p_report_date;

  select
    coalesce(sum(case
      when (p.created_at at time zone 'Asia/Dhaka')::date >= date_trunc('month',p_report_date)::date
       and (p.created_at at time zone 'Asia/Dhaka')::date <= p_report_date
      then p.paid else 0 end),0),
    count(*),
    coalesce(sum(p.due),0)
  into month_patient_paid,total_records,total_patient_due
  from public.patients p;

  select coalesce(sum(case
    when lower(trim(fs.type))='in' then fs.quantity
    when lower(trim(fs.type))='out' then -fs.quantity
    else 0 end),0)
  into total_film_stock
  from public.film_stock fs
  where (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select greatest(
    0,
    coalesce(sum(case when rt0.type='due' then rt0.amount else 0 end),0)
    - coalesce(sum(case when rt0.type='paid' then rt0.amount else 0 end),0)
  )
  into total_referrer_commission_balance
  from public.referrer_transactions rt0;

  select coalesce(sum(case
    when lower(regexp_replace(trim(fs.film_size),'[^0-9]+','x','g'))='14x17'
    then case when lower(trim(fs.type))='in' then fs.quantity else -fs.quantity end
    else 0 end),0)
  into film_14x17
  from public.film_stock fs
  where (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(sum(case
    when lower(regexp_replace(trim(fs.film_size),'[^0-9]+','x','g'))='10x14'
    then case when lower(trim(fs.type))='in' then fs.quantity else -fs.quantity end
    else 0 end),0)
  into film_10x14
  from public.film_stock fs
  where (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  select coalesce(sum(case
    when lower(regexp_replace(trim(fs.film_size),'[^0-9]+','x','g'))='8x10'
    then case when lower(trim(fs.type))='in' then fs.quantity else -fs.quantity end
    else 0 end),0)
  into film_8x10
  from public.film_stock fs
  where (fs.created_at at time zone 'Asia/Dhaka')::date <= p_report_date;

  return jsonb_build_object(
    'report_date',p_report_date,
    'owner_email',owner_email,
    'owner_whatsapp',coalesce(owner_whatsapp,''),
    'patient_count',patient_count,
    'patient_billing',patient_billing,
    'patient_paid',patient_paid,
    'patient_due',patient_due,
    'ref_commission_due',ref_commission_due,
    'ref_commission_paid',ref_commission_paid,
    'ref_bill_due',ref_bill_due,
    'ref_bill_collected',ref_bill_collected,
    'expenses_total',expenses_total,
    'net_cash',patient_paid+ref_bill_collected-ref_commission_paid-expenses_total,
    'film_14x17',film_14x17,
    'film_10x14',film_10x14,
    'film_8x10',film_8x10,
    'month_patient_paid',month_patient_paid,
    'total_records',total_records,
    'total_patient_due',total_patient_due,
    'total_film_stock',total_film_stock,
    'total_referrer_commission_balance',total_referrer_commission_balance
  );
end;
$report$;

revoke all on function public.get_owner_daily_report(date) from public;
grant execute on function public.get_owner_daily_report(date) to authenticated;

-- Defense-in-depth: COUNTER is never allowed to UPDATE or DELETE existing
-- patient/film/configuration/financial rows, even if a client bypasses the UI.
create or replace function public.prevent_counter_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and exists (
       select 1 from public.user_profiles up
       where up.id = auth.uid()
         and up.active = true
         and up.role = 'counter'
     ) then
    raise exception 'COUNTER is read-only for existing entries.';
  end if;
  if TG_OP = 'DELETE' then
    return OLD;
  end if;
  return NEW;
end;
$$;

revoke all on function public.prevent_counter_mutation() from public;
grant execute on function public.prevent_counter_mutation() to authenticated;

drop trigger if exists trg_counter_no_mutate_patients on public.patients;
create trigger trg_counter_no_mutate_patients
before update or delete on public.patients
for each row execute function public.prevent_counter_mutation();

drop trigger if exists trg_counter_no_mutate_film_stock on public.film_stock;
create trigger trg_counter_no_mutate_film_stock
before update or delete on public.film_stock
for each row execute function public.prevent_counter_mutation();

drop trigger if exists trg_counter_no_mutate_xray_types on public.xray_types;
create trigger trg_counter_no_mutate_xray_types
before update or delete on public.xray_types
for each row execute function public.prevent_counter_mutation();

drop trigger if exists trg_counter_no_mutate_doctors on public.doctors;
create trigger trg_counter_no_mutate_doctors
before update or delete on public.doctors
for each row execute function public.prevent_counter_mutation();

drop trigger if exists trg_counter_no_mutate_referrers on public.referrers;
create trigger trg_counter_no_mutate_referrers
before update or delete on public.referrers
for each row execute function public.prevent_counter_mutation();

drop trigger if exists trg_counter_no_mutate_referrer_transactions on public.referrer_transactions;
create trigger trg_counter_no_mutate_referrer_transactions
before update or delete on public.referrer_transactions
for each row execute function public.prevent_counter_mutation();

drop trigger if exists trg_counter_no_mutate_referrer_receivables on public.referrer_receivables;
create trigger trg_counter_no_mutate_referrer_receivables
before update or delete on public.referrer_receivables
for each row execute function public.prevent_counter_mutation();

drop trigger if exists trg_counter_no_mutate_expenses on public.expenses;
create trigger trg_counter_no_mutate_expenses
before update or delete on public.expenses
for each row execute function public.prevent_counter_mutation();

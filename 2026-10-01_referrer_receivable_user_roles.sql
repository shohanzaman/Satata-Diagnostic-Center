-- SATATA X-RAY: Referrer Receivable + User Roles Migration
-- Run this AFTER Satata_XRay_Complete_Supabase_v2.sql
-- Safe for an existing database: creates only new objects and policies.

create table if not exists public.referrer_receivables (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  referrer_id uuid not null references public.referrers(id) on delete cascade,
  patient_id uuid references public.patients(id) on delete set null,
  invoice_no text,
  type text not null check (type in ('bill_due','payment','adjustment')),
  amount numeric(12,2) not null check (amount > 0),
  payment_method text,
  note text,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists idx_referrer_receivables_user_created
  on public.referrer_receivables(user_id, created_at desc);
create index if not exists idx_referrer_receivables_referrer
  on public.referrer_receivables(referrer_id, created_at desc);
create index if not exists idx_referrer_receivables_patient
  on public.referrer_receivables(patient_id);

alter table public.patients
  add column if not exists payment_responsibility text not null default 'patient'
  check (payment_responsibility in ('patient','referrer'));

alter table public.referrer_receivables enable row level security;

drop policy if exists "Users can select own referrer receivables" on public.referrer_receivables;
drop policy if exists "Users can insert own referrer receivables" on public.referrer_receivables;
drop policy if exists "Users can update own referrer receivables" on public.referrer_receivables;
drop policy if exists "Users can delete own referrer receivables" on public.referrer_receivables;

create policy "Users can select own referrer receivables"
on public.referrer_receivables for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Users can insert own referrer receivables"
on public.referrer_receivables for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "Users can update own referrer receivables"
on public.referrer_receivables for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "Users can delete own referrer receivables"
on public.referrer_receivables for delete
to authenticated
using ((select auth.uid()) = user_id);

-- ------------------------------------------------------------
-- APPLICATION USER ROLES
-- ------------------------------------------------------------
do $fn$ begin
  create type public.app_role as enum ('admin','counter');
exception when duplicate_object then null;
end $fn$;

create table if not exists public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  role public.app_role not null default 'counter',
  active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create index if not exists idx_user_profiles_role on public.user_profiles(role);

alter table public.user_profiles enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.user_profiles
    where id = auth.uid() and role = 'admin' and active = true
  );
$fn$;

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  insert into public.user_profiles(id, email, display_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', split_part(coalesce(new.email,''),'@',1)),
    'counter'
  )
  on conflict (id) do nothing;
  return new;
end;
$fn$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute procedure public.handle_new_user_profile();

-- Backfill existing users as Counter by default.
insert into public.user_profiles(id, email, display_name, role)
select
  u.id,
  u.email,
  coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(coalesce(u.email,''),'@',1)),
  'counter'::public.app_role
from auth.users u
on conflict (id) do nothing;

drop policy if exists "Users can read own profile" on public.user_profiles;
drop policy if exists "Admins can read all profiles" on public.user_profiles;
drop policy if exists "Admins can update profiles" on public.user_profiles;

create policy "Users can read own profile"
on public.user_profiles for select
to authenticated
using ((select auth.uid()) = id);

create policy "Admins can read all profiles"
on public.user_profiles for select
to authenticated
using ((select public.is_admin()));

create policy "Admins can update profiles"
on public.user_profiles for update
to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

-- Secure role change through a function. It prevents removing the last admin.
create or replace function public.set_user_role(target_user uuid, new_role public.app_role)
returns public.user_profiles
language plpgsql
security definer
set search_path = public
as $fn$
declare
  result public.user_profiles;
  admin_count integer;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can change user roles';
  end if;

  if target_user = auth.uid() and new_role <> 'admin' then
    select count(*) into admin_count
    from public.user_profiles
    where role = 'admin' and active = true;
    if admin_count <= 1 then
      raise exception 'The last administrator cannot be demoted';
    end if;
  end if;

  update public.user_profiles
  set role = new_role, updated_at = now()
  where id = target_user
  returning * into result;

  if result.id is null then
    raise exception 'User profile not found';
  end if;

  return result;
end;
$fn$;

grant execute on function public.is_admin() to authenticated;
grant execute on function public.set_user_role(uuid, public.app_role) to authenticated;

-- First verified non-anonymous account can bootstrap itself as Admin if no admin exists.
create or replace function public.bootstrap_first_admin()
returns public.user_profiles
language plpgsql
security definer
set search_path = public
as $fn$
declare
  result public.user_profiles;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if exists (select 1 from public.user_profiles where role='admin' and active=true) then
    raise exception 'An administrator already exists';
  end if;

  update public.user_profiles
  set role='admin', active=true, updated_at=now()
  where id=auth.uid()
  returning * into result;

  if result.id is null then raise exception 'User profile not found'; end if;
  return result;
end;
$fn$;

grant execute on function public.bootstrap_first_admin() to authenticated;

create or replace function public.set_user_active(target_user uuid, new_active boolean)
returns public.user_profiles
language plpgsql
security definer
set search_path = public
as $fn$
declare
  result public.user_profiles;
  admin_count integer;
begin
  if not public.is_admin() then raise exception 'Only administrators can change user status'; end if;

  if target_user = auth.uid() and not new_active then
    raise exception 'You cannot disable your own account';
  end if;

  if not new_active then
    select count(*) into admin_count from public.user_profiles where role='admin' and active=true;
    if exists(select 1 from public.user_profiles where id=target_user and role='admin' and active=true) and admin_count <= 1 then
      raise exception 'The last administrator cannot be disabled';
    end if;
  end if;

  update public.user_profiles set active=new_active,updated_at=now()
  where id=target_user returning * into result;

  if result.id is null then raise exception 'User profile not found'; end if;
  return result;
end;
$fn$;

grant execute on function public.set_user_active(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- ROLE-AWARE RLS
-- Admin: full application control.
-- Counter: create new patient entries and required stock/ledger rows,
-- but cannot edit/delete patients, collect dues, edit master data,
-- or change user roles.
-- ------------------------------------------------------------

-- Patients
drop policy if exists "Users can insert own patients" on public.patients;
drop policy if exists "Users can update own patients" on public.patients;
drop policy if exists "Users can delete own patients" on public.patients;

create policy "Admin can manage patients"
on public.patients for all to authenticated
using ((select public.is_admin()) and (select auth.uid()) = user_id)
with check ((select public.is_admin()) and (select auth.uid()) = user_id);

create policy "Counter can insert patients"
on public.patients for insert to authenticated
with check (
  (select auth.uid()) = user_id
  and exists (
    select 1 from public.user_profiles
    where id=auth.uid() and role in ('admin','counter') and active=true
  )
);

-- Patients
drop policy if exists "Users can select own patients" on public.patients;
create policy "Admin can select patients"
on public.patients for select to authenticated
using ((select public.is_admin()) and (select auth.uid())=user_id);

-- Ledgers are Admin-readable. Counter only creates the required due rows.
drop policy if exists "Users can select own referrer transactions" on public.referrer_transactions;
create policy "Admin can select referrer transactions"
on public.referrer_transactions for select to authenticated
using ((select public.is_admin()) and (select auth.uid())=user_id);

drop policy if exists "Users can select own referrer receivables" on public.referrer_receivables;
create policy "Admin can select referrer receivables"
on public.referrer_receivables for select to authenticated
using ((select public.is_admin()) and (select auth.uid())=user_id);

-- Reference data: counter may read only.
drop policy if exists "Users can insert own film_stock" on public.film_stock;
drop policy if exists "Users can update own film_stock" on public.film_stock;
drop policy if exists "Users can delete own film_stock" on public.film_stock;
create policy "Admin can manage film stock"
on public.film_stock for all to authenticated
using ((select public.is_admin()) and (select auth.uid())=user_id)
with check ((select public.is_admin()) and (select auth.uid())=user_id);
create policy "Counter can add film stock out"
on public.film_stock for insert to authenticated
with check (
  (select auth.uid())=user_id
  and type='out'
  and exists(select 1 from public.user_profiles where id=auth.uid() and role='counter' and active=true)
);

-- Counter must be able to read film stock for availability checking.
-- Existing select policy already permits own rows.

-- Master tables: only Admin can change them.
do $fn$
declare t text;
begin
  foreach t in array array['xray_types','doctors','referrers'] loop
    execute format('drop policy if exists "Users can insert own %s" on public.%I', t, t);
    execute format('drop policy if exists "Users can update own %s" on public.%I', t, t);
    execute format('drop policy if exists "Users can delete own %s" on public.%I', t, t);
    execute format('create policy "Admin can manage %s" on public.%I for all to authenticated using ((select public.is_admin()) and (select auth.uid())=user_id) with check ((select public.is_admin()) and (select auth.uid())=user_id)', t, t);
  end loop;
end $fn$;

-- Referrer commission: Counter may create the due entry during a new patient registration.
drop policy if exists "Users can insert own referrer transactions" on public.referrer_transactions;
drop policy if exists "Users can update own referrer transactions" on public.referrer_transactions;
drop policy if exists "Users can delete own referrer transactions" on public.referrer_transactions;

create policy "Admin can manage referrer transactions"
on public.referrer_transactions for all to authenticated
using ((select public.is_admin()) and (select auth.uid())=user_id)
with check ((select public.is_admin()) and (select auth.uid())=user_id);

create policy "Counter can add commission due"
on public.referrer_transactions for insert to authenticated
with check (
  (select auth.uid())=user_id
  and type='due'
  and exists(select 1 from public.user_profiles where id=auth.uid() and role='counter' and active=true)
);

-- Receivables: Counter may create bill_due only; only Admin can receive payments/adjustments.
drop policy if exists "Users can insert own referrer receivables" on public.referrer_receivables;
drop policy if exists "Users can update own referrer receivables" on public.referrer_receivables;
drop policy if exists "Users can delete own referrer receivables" on public.referrer_receivables;

create policy "Admin can manage referrer receivables"
on public.referrer_receivables for all to authenticated
using ((select public.is_admin()) and (select auth.uid())=user_id)
with check ((select public.is_admin()) and (select auth.uid())=user_id);

create policy "Counter can add referrer bill due"
on public.referrer_receivables for insert to authenticated
with check (
  (select auth.uid())=user_id
  and type='bill_due'
  and exists(select 1 from public.user_profiles where id=auth.uid() and role='counter' and active=true)
);

-- Existing select policies remain so current user's reference data can load.
-- Do NOT expose service_role keys in this PWA.


-- ------------------------------------------------------------
-- DEVICE APPROVAL / STAFF DEVICE BINDING
-- Browser apps cannot reliably read a hardware MAC address.
-- We therefore bind each account to an approved browser/device key.
-- A new browser/device requires an Admin-generated one-time code.
-- ------------------------------------------------------------
create extension if not exists pgcrypto;

create table if not exists public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_key text not null,
  device_label text,
  approved boolean not null default false,
  created_at timestamptz not null default timezone('utc', now()),
  approved_at timestamptz,
  last_seen_at timestamptz,
  revoked_at timestamptz,
  unique(user_id, device_key)
);

create index if not exists idx_user_devices_user on public.user_devices(user_id);

create table if not exists public.device_approval_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_key text not null,
  device_label text,
  status text not null default 'pending' check (status in ('pending','approved','expired','revoked')),
  code_hash text,
  code_expires_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  approved_at timestamptz,
  unique(user_id, device_key, status)
);

create index if not exists idx_device_requests_status_created
  on public.device_approval_requests(status, created_at desc);

alter table public.user_devices enable row level security;
alter table public.device_approval_requests enable row level security;

drop policy if exists "Admins can read all devices" on public.user_devices;
create policy "Admins can read all devices"
on public.user_devices for select to authenticated
using ((select public.is_admin()));

drop policy if exists "Users can read own devices" on public.user_devices;
create policy "Users can read own devices"
on public.user_devices for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Admins can read device requests" on public.device_approval_requests;
create policy "Admins can read device requests"
on public.device_approval_requests for select to authenticated
using ((select public.is_admin()));

create or replace function public.check_device_access(p_device_key text, p_device_label text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $device$
declare
  existing public.user_devices;
  req public.device_approval_requests;
begin
  if auth.uid() is null then
    return jsonb_build_object('allowed',false,'reason','not_authenticated');
  end if;

  if exists (
    select 1 from public.user_profiles
    where id=auth.uid() and active=false
  ) then
    return jsonb_build_object('allowed',false,'reason','account_disabled');
  end if;

  select * into existing
  from public.user_devices
  where user_id=auth.uid() and device_key=p_device_key and approved=true and revoked_at is null
  limit 1;

  if existing.id is not null then
    update public.user_devices
    set last_seen_at=now(), device_label=coalesce(nullif(p_device_label,''),device_label)
    where id=existing.id;
    return jsonb_build_object('allowed',true,'request_id',null);
  end if;

  -- The first device of the first permanent Admin is trusted automatically.
  if not exists (select 1 from public.user_devices where user_id=auth.uid())
     and exists (select 1 from public.user_profiles where id=auth.uid() and role='admin' and active=true)
  then
    insert into public.user_devices(user_id,device_key,device_label,approved,approved_at,last_seen_at)
    values(auth.uid(),p_device_key,p_device_label,true,now(),now())
    on conflict (user_id,device_key) do update
      set approved=true, revoked_at=null, last_seen_at=now();
    return jsonb_build_object('allowed',true,'request_id',null,'first_device',true);
  end if;

  select * into req
  from public.device_approval_requests
  where user_id=auth.uid()
    and device_key=p_device_key
    and status='pending'
    and created_at > now() - interval '24 hours'
  order by created_at desc
  limit 1;

  if req.id is null then
    insert into public.device_approval_requests(user_id,device_key,device_label,status)
    values(auth.uid(),p_device_key,p_device_label,'pending')
    returning * into req;
  end if;

  return jsonb_build_object('allowed',false,'reason','device_not_approved','request_id',req.id);
end;
$device$;

create or replace function public.admin_issue_device_code(p_request_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $device$
declare
  req public.device_approval_requests;
  code text;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can approve devices';
  end if;

  select * into req
  from public.device_approval_requests
  where id=p_request_id and status='pending'
  for update;

  if req.id is null then
    raise exception 'Device request not found or already processed';
  end if;

  -- Avoid dependency on gen_random_bytes(); MD5 is used only to generate a short one-time code.
  code := upper(substr(md5(random()::text || clock_timestamp()::text || req.id::text),1,10));

  update public.device_approval_requests
  set code_hash=encode(digest(code,'sha256'),'hex'),
      code_expires_at=now()+interval '10 minutes'
  where id=req.id;

  return code;
end;
$device$;

create or replace function public.verify_device_code(p_request_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $device$
declare
  req public.device_approval_requests;
begin
  select * into req
  from public.device_approval_requests
  where id=p_request_id
    and user_id=auth.uid()
    and status='pending'
  for update;

  if req.id is null then
    raise exception 'Device approval request not found';
  end if;

  if req.code_hash is null or req.code_expires_at is null or req.code_expires_at < now() then
    raise exception 'Approval code expired. Ask Admin for a new code.';
  end if;

  if encode(digest(upper(trim(coalesce(p_code,''))),'sha256'),'hex') <> req.code_hash then
    raise exception 'Invalid approval code';
  end if;

  insert into public.user_devices(user_id,device_key,device_label,approved,approved_at,last_seen_at)
  values(auth.uid(),req.device_key,req.device_label,true,now(),now())
  on conflict (user_id,device_key) do update
    set approved=true, revoked_at=null, approved_at=now(), last_seen_at=now();

  update public.device_approval_requests
  set status='approved', approved_at=now()
  where id=req.id;

  return true;
end;
$device$;

create or replace function public.revoke_user_device(p_device_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $device$
begin
  if not public.is_admin() then
    raise exception 'Only administrators can revoke devices';
  end if;
  update public.user_devices
  set approved=false, revoked_at=now()
  where id=p_device_id;
  return found;
end;
$device$;

grant execute on function public.check_device_access(text,text) to authenticated;
grant execute on function public.admin_issue_device_code(uuid) to authenticated;
grant execute on function public.verify_device_code(uuid,text) to authenticated;
grant execute on function public.revoke_user_device(uuid) to authenticated;

-- Repair email values for existing profiles and keep anonymous users out of User Management.
update public.user_profiles p
set email=u.email,
    display_name=coalesce(p.display_name,u.raw_user_meta_data->>'full_name',u.raw_user_meta_data->>'name')
from auth.users u
where p.id=u.id and u.email is not null;

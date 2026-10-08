-- SATATA X-RAY: Blood Test invoice-only module
-- No stock, sample, parameter or report workflow.

create table if not exists public.blood_test_types (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  price numeric not null default 0 check (price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists blood_test_types_user_name_uq
  on public.blood_test_types(user_id, lower(trim(name)));

create index if not exists blood_test_types_user_active_idx
  on public.blood_test_types(user_id, active, name);

alter table public.blood_test_types enable row level security;

drop policy if exists "blood_test_admin_select" on public.blood_test_types;
create policy "blood_test_admin_select"
on public.blood_test_types for select to authenticated
using (
  user_id = auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.active = true and up.role = 'admin'
  )
);

drop policy if exists "blood_test_admin_insert" on public.blood_test_types;
create policy "blood_test_admin_insert"
on public.blood_test_types for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.active = true and up.role = 'admin'
  )
);

drop policy if exists "blood_test_admin_update" on public.blood_test_types;
create policy "blood_test_admin_update"
on public.blood_test_types for update to authenticated
using (
  user_id = auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.active = true and up.role = 'admin'
  )
)
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.active = true and up.role = 'admin'
  )
);

drop policy if exists "blood_test_admin_delete" on public.blood_test_types;
create policy "blood_test_admin_delete"
on public.blood_test_types for delete to authenticated
using (
  user_id = auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.active = true and up.role = 'admin'
  )
);

create or replace function public.blood_test_types_set_updated_at()
returns trigger
language plpgsql
as $
begin
  new.updated_at = now();
  return new;
end;
$;

drop trigger if exists trg_blood_test_types_updated_at on public.blood_test_types;
create trigger trg_blood_test_types_updated_at
before update on public.blood_test_types
for each row execute function public.blood_test_types_set_updated_at();

-- Extend the existing shared entry-options RPC so COUNTER can use
-- the active ADMIN's Blood Test catalog without direct table access.
create or replace function public.get_shared_entry_options()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_id uuid;
  xray_data jsonb;
  doctor_data jsonb;
  referrer_data jsonb;
  blood_test_data jsonb;
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

  select up.id into admin_id
  from public.user_profiles up
  where up.role = 'admin' and up.active = true
  order by up.created_at asc
  limit 1;

  if admin_id is null then
    raise exception 'No active ADMIN account found';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb)
    into xray_data
  from public.xray_types x where x.user_id = admin_id;

  select coalesce(jsonb_agg(to_jsonb(d) order by d.name), '[]'::jsonb)
    into doctor_data
  from public.doctors d where d.user_id = admin_id;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.name), '[]'::jsonb)
    into referrer_data
  from public.referrers r where r.user_id = admin_id;

  select coalesce(jsonb_agg(to_jsonb(bt) order by bt.name), '[]'::jsonb)
    into blood_test_data
  from public.blood_test_types bt
  where bt.user_id = admin_id and bt.active = true;

  return jsonb_build_object(
    'xray_types', xray_data,
    'doctors', doctor_data,
    'referrers', referrer_data,
    'blood_tests', blood_test_data
  );
end;
$$;

revoke all on function public.get_shared_entry_options() from public;
grant execute on function public.get_shared_entry_options() to authenticated;

-- Counter reads Blood Test catalog only through the secure shared-options RPC.
-- No direct COUNTER table policy is granted.

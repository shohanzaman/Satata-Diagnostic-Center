-- SATATA X-RAY & ECG CENTER
-- Final Blood Test invoice-only migration.
-- Blood tests are services only: no reagent, sample, result, stock or report workflow.

create table if not exists public.blood_test_types (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  name text not null,
  rate numeric(12,2) not null default 0 check (rate >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Make this migration compatible with either earlier blood-test migration
-- that used price/created_by or the newer rate/user_id structure.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='blood_test_types' and column_name='user_id'
  ) then
    alter table public.blood_test_types add column user_id uuid references auth.users(id) on delete cascade;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='blood_test_types' and column_name='rate'
  ) then
    alter table public.blood_test_types add column rate numeric(12,2) not null default 0;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='blood_test_types' and column_name='price'
  ) then
    update public.blood_test_types
       set rate=coalesce(price,0)
     where coalesce(rate,0)=0 and price is not null;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='blood_test_types' and column_name='created_by'
  ) then
    update public.blood_test_types
       set user_id=created_by
     where user_id is null and created_by is not null;
  end if;

  update public.blood_test_types
     set user_id=(
       select up.id
       from public.user_profiles up
       where up.role='admin' and up.active=true
       order by up.created_at asc
       limit 1
     )
   where user_id is null;

  if not exists (
    select 1 from public.blood_test_types where user_id is null
  ) then
    alter table public.blood_test_types alter column user_id set not null;
  end if;
end $$;

create unique index if not exists blood_test_types_user_name_uq
  on public.blood_test_types(user_id, lower(trim(name)));

alter table public.blood_test_types add column if not exists price numeric(12,2) not null default 0;

update public.blood_test_types set price=rate where coalesce(price,0)=0;

create index if not exists blood_test_types_user_active_idx
  on public.blood_test_types(user_id, active, name);

alter table public.blood_test_types enable row level security;

drop policy if exists "blood_test_types_admin_all" on public.blood_test_types;
drop policy if exists "blood_test_types_select" on public.blood_test_types;
drop policy if exists "blood_test_types_admin_insert" on public.blood_test_types;
drop policy if exists "blood_test_types_admin_update" on public.blood_test_types;
drop policy if exists "blood_test_types_admin_delete" on public.blood_test_types;

create policy "blood_test_types_select"
on public.blood_test_types
for select
to authenticated
using (
  user_id=auth.uid()
  and (
    active=true
    or exists (
      select 1 from public.user_profiles up
      where up.id=auth.uid() and up.active=true and up.role='admin'
    )
  )
);

create policy "blood_test_types_admin_insert"
on public.blood_test_types
for insert
to authenticated
with check (
  user_id=auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id=auth.uid() and up.active=true and up.role='admin'
  )
);

create policy "blood_test_types_admin_update"
on public.blood_test_types
for update
to authenticated
using (
  user_id=auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id=auth.uid() and up.active=true and up.role='admin'
  )
)
with check (
  user_id=auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id=auth.uid() and up.active=true and up.role='admin'
  )
);

create policy "blood_test_types_admin_delete"
on public.blood_test_types
for delete
to authenticated
using (
  user_id=auth.uid()
  and exists (
    select 1 from public.user_profiles up
    where up.id=auth.uid() and up.active=true and up.role='admin'
  )
);

create or replace function public.get_shared_blood_test_types()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  admin_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.user_profiles up
    where up.id=auth.uid() and up.active=true
  ) then
    raise exception 'Your account is inactive';
  end if;

  select up.id into admin_id
  from public.user_profiles up
  where up.role='admin' and up.active=true
  order by up.created_at asc
  limit 1;

  if admin_id is null then
    raise exception 'No active ADMIN account found';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',x.id,
        'user_id',x.user_id,
        'name',x.name,
        'rate',x.rate,
        'price',coalesce(x.price,x.rate),
        'active',x.active,
        'created_at',x.created_at
      )
      order by x.name
    )
    from public.blood_test_types x
    where x.user_id=admin_id and x.active=true
  ),'[]'::jsonb);
end;
$$;

revoke all on function public.get_shared_blood_test_types() from public;
grant execute on function public.get_shared_blood_test_types() to authenticated;

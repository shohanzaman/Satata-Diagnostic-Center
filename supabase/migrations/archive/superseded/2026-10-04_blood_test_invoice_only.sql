-- SATATA X-RAY: Blood Test invoice-only service
-- Blood tests use the existing multi-service invoice engine.
-- No reagent, sample, stock or report workflow is created.

create table if not exists public.blood_test_types (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  rate numeric(12,2) not null default 0 check (rate >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create unique index if not exists blood_test_types_user_name_uq
  on public.blood_test_types(user_id, lower(trim(name)));

create index if not exists blood_test_types_user_active_idx
  on public.blood_test_types(user_id, active, name);

alter table public.blood_test_types enable row level security;

drop policy if exists "blood_test_types_admin_all" on public.blood_test_types;
create policy "blood_test_types_admin_all"
on public.blood_test_types
for all
to authenticated
using (
  user_id = auth.uid()
  and public.is_admin()
)
with check (
  user_id = auth.uid()
  and public.is_admin()
);

create or replace function public.get_shared_blood_test_types()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.user_profiles up
    where up.id = auth.uid()
      and up.active = true
  ) then
    raise exception 'Your account is inactive';
  end if;

  select up.id into admin_id
  from public.user_profiles up
  where up.role = 'admin'
    and up.active = true
  order by up.created_at asc
  limit 1;

  if admin_id is null then
    raise exception 'No active ADMIN account found';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.name)
    from public.blood_test_types x
    where x.user_id = admin_id
      and x.active = true
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_shared_blood_test_types() from public;
grant execute on function public.get_shared_blood_test_types() to authenticated;

-- COUNTER may CREATE local referrers, but cannot UPDATE or DELETE them.
create or replace function public.counter_add_referrer(
  p_name text,
  p_mobile text default '',
  p_address text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_id uuid;
  active_admin_count integer;
  new_row public.referrers;
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
    raise exception 'Referrer name is required';
  end if;

  insert into public.referrers(user_id,name,mobile,address)
  values(
    admin_id,
    trim(p_name),
    trim(coalesce(p_mobile,'')),
    trim(coalesce(p_address,''))
  )
  returning * into new_row;

  return to_jsonb(new_row);
end;
$$;

revoke all on function public.counter_add_referrer(text,text,text) from public;
grant execute on function public.counter_add_referrer(text,text,text) to authenticated;

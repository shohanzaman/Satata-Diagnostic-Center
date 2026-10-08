-- SATATA X-RAY: Shared configuration for ADMIN + COUNTER entry
-- Counter users need to read the center's X-Ray Types, Doctors and Referrers.
-- The application has no center_id/organization_id, so the active ADMIN is
-- treated as the center owner/configuration source.

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

  select up.id
    into admin_id
  from public.user_profiles up
  where up.role = 'admin'
    and up.active = true
  order by up.created_at asc
  limit 1;

  if admin_id is null then
    raise exception 'No active ADMIN account found';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb)
    into xray_data
  from public.xray_types x
  where x.user_id = admin_id;

  select coalesce(jsonb_agg(to_jsonb(d) order by d.name), '[]'::jsonb)
    into doctor_data
  from public.doctors d
  where d.user_id = admin_id;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.name), '[]'::jsonb)
    into referrer_data
  from public.referrers r
  where r.user_id = admin_id;

  return jsonb_build_object(
    'xray_types', xray_data,
    'doctors', doctor_data,
    'referrers', referrer_data
  );
end;
$$;

revoke all on function public.get_shared_entry_options() from public;
grant execute on function public.get_shared_entry_options() to authenticated;

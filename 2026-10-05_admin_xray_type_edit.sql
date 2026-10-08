-- SATATA X-RAY: ADMIN-only X-Ray type editing
-- Allows ADMIN to change X-Ray name, film size, price and referrer commission.
-- COUNTER has no update path through this function.

create or replace function public.admin_update_xray_type(
  p_xray_type_id uuid,
  p_name text,
  p_film_size text,
  p_price numeric,
  p_commission numeric
)
returns public.xray_types
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_row public.xray_types;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.user_profiles up
    where up.id = auth.uid()
      and up.active = true
      and up.role = 'admin'
  ) then
    raise exception 'ADMIN access required';
  end if;

  if nullif(trim(coalesce(p_name,'')),'') is null then
    raise exception 'X-Ray name is required';
  end if;

  if coalesce(p_price,0) < 0 then
    raise exception 'Price cannot be negative';
  end if;

  if coalesce(p_commission,0) < 0 then
    raise exception 'Commission cannot be negative';
  end if;

  update public.xray_types
     set name = trim(p_name),
         film_size = trim(coalesce(p_film_size,'')),
         price = coalesce(p_price,0),
         commission = coalesce(p_commission,0)
   where id = p_xray_type_id
     and user_id = auth.uid()
  returning * into updated_row;

  if updated_row.id is null then
    raise exception 'X-Ray type not found or not owned by ADMIN';
  end if;

  return updated_row;
end;
$$;

revoke all on function public.admin_update_xray_type(uuid,text,text,numeric,numeric) from public;
grant execute on function public.admin_update_xray_type(uuid,text,text,numeric,numeric) to authenticated;

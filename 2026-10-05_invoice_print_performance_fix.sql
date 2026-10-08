-- SATATA X-RAY: Invoice Print performance fix
-- Server-side search/date filtering and hard limit prevent the print-only
-- account from loading the entire patients table into the browser.

drop function if exists public.get_invoice_print_records_page(text,date,integer);

create or replace function public.get_invoice_print_records_page(
  p_search text default null,
  p_date date default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  result jsonb;
  v_search text := lower(trim(coalesce(p_search,'')));
  v_limit integer := least(greatest(coalesce(p_limit,100),1),100);
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.user_profiles
    where id = auth.uid()
      and role = 'invoice_print'
      and active = true
  ) then
    raise exception 'Invoice Print access required';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',p.id,
        'user_id',p.user_id,
        'name',p.name,
        'age',p.age,
        'sex',p.sex,
        'xray_type',p.xray_type,
        'film_size',p.film_size,
        'film_qty',p.film_qty,
        'price_per_film',p.price_per_film,
        'doctor',p.doctor,
        'referrer',p.referrer,
        'referrer_id',p.referrer_id,
        'payment_responsibility',p.payment_responsibility,
        'discount',p.discount,
        'paid',p.paid,
        'total',p.total,
        'due',p.due,
        'created_at',p.created_at,
        'service_items',p.service_items
      )
      order by p.created_at desc
    ),
    '[]'::jsonb
  )
  into result
  from (
    select p.*
    from public.patients p
    where (p_date is null or (p.created_at >= (p_date::timestamp at time zone 'Asia/Dhaka') and p.created_at < ((p_date + 1)::timestamp at time zone 'Asia/Dhaka')))
      and (
        v_search = ''
        or lower(coalesce(p.name,'')) like '%' || v_search || '%'
        or lower(coalesce(p.xray_type,'')) like '%' || v_search || '%'
        or lower(coalesce(p.doctor,'')) like '%' || v_search || '%'
        or lower(coalesce(p.referrer,'')) like '%' || v_search || '%'
        or lower(coalesce(p.id::text,'')) like '%' || v_search || '%'
        or lower(coalesce(p.service_items::text,'')) like '%' || v_search || '%'
      )
    order by p.created_at desc
    limit v_limit
  ) p;

  return result;
end;
$fn$;

revoke all on function public.get_invoice_print_records_page(text,date,integer) from public;
grant execute on function public.get_invoice_print_records_page(text,date,integer) to authenticated;

-- SATATA X-RAY: Invoice Print User Role
-- Adds a dedicated read/print-only application role.
-- No existing role is changed and no data is modified.

do $$
begin
  alter type public.app_role add value if not exists 'invoice_print';
exception
  when duplicate_object then null;
end $$;

-- Secure read-only record feed for the invoice-print account.
-- It deliberately returns only fields required to locate and print invoices.
create or replace function public.get_invoice_print_records()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  result jsonb;
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
  from public.patients p;

  return result;
end;
$fn$;

revoke all on function public.get_invoice_print_records() from public;
grant execute on function public.get_invoice_print_records() to authenticated;

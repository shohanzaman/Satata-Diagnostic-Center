-- Allow one patient invoice to contain multiple X-Ray / ECG services.
alter table if exists public.patients
  add column if not exists service_items jsonb not null default '[]'::jsonb;

-- Backfill legacy records as a single service item so old invoices remain printable.
update public.patients
set service_items = jsonb_build_array(
  jsonb_build_object(
    'exam_type', case when upper(coalesce(xray_type,'')) = 'ECG' then 'ecg' else 'xray' end,
    'name', coalesce(xray_type,''),
    'film_size', coalesce(film_size,''),
    'qty', coalesce(film_qty,1),
    'price', coalesce(price_per_film,0),
    'commission', 0
  )
)
where service_items = '[]'::jsonb
   or service_items is null;

-- Fix ADMIN patient deletion stock restoration for invoice service_items.
-- Only X-Ray and ECG services consume film/paper stock.
-- Blood Test and X-Ray Report services never restore stock.

create or replace function public.admin_delete_patient(
  p_patient_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_row public.patients;
  item jsonb;
  service_type text;
  restored_count integer := 0;
  restored_qty numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.active = true and up.role = 'admin'
  ) then
    raise exception 'Only ADMIN can delete patient records';
  end if;

  select * into old_row
  from public.patients
  where id = p_patient_id
  for update;

  if not found then
    raise exception 'Patient record not found';
  end if;

  delete from public.referrer_transactions
  where patient_id = p_patient_id and type = 'due';

  delete from public.referrer_receivables
  where patient_id = p_patient_id and type = 'bill_due';

  if jsonb_typeof(old_row.service_items) = 'array'
     and jsonb_array_length(old_row.service_items) > 0 then

    for item in
      select value from jsonb_array_elements(old_row.service_items)
    loop
      service_type := lower(trim(coalesce(item->>'exam_type','')));

      if service_type in ('xray','ecg')
         and greatest(coalesce((item->>'qty')::numeric,0),0) > 0
         and nullif(trim(coalesce(item->>'film_size','')),'') is not null
         and lower(trim(coalesce(item->>'film_size',''))) not in ('report paper','blood test','no stock') then

        insert into public.film_stock(
          user_id,film_size,quantity,type,note
        )
        values(
          auth.uid(),
          item->>'film_size',
          greatest(coalesce((item->>'qty')::numeric,0),0),
          'in',
          'ADMIN delete: restored ' ||
          coalesce(item->>'name','service') ||
          ' for patient ' || coalesce(old_row.name,'')
        );

        restored_count := restored_count + 1;
        restored_qty := restored_qty +
          greatest(coalesce((item->>'qty')::numeric,0),0);
      end if;
    end loop;

  else
    -- Legacy patient records without service_items.
    if greatest(coalesce(old_row.film_qty,0),0) > 0
       and nullif(trim(coalesce(old_row.film_size,'')),'') is not null
       and lower(trim(coalesce(old_row.film_size,''))) <> 'ecg paper' then

      insert into public.film_stock(
        user_id,film_size,quantity,type,note
      )
      values(
        auth.uid(),
        coalesce(old_row.film_size,'14 × 17'),
        greatest(coalesce(old_row.film_qty,0),0),
        'in',
        'ADMIN delete: restored film for patient ' ||
        coalesce(old_row.name,'')
      );

      restored_count := 1;
      restored_qty := greatest(coalesce(old_row.film_qty,0),0);
    end if;
  end if;

  delete from public.patients where id = p_patient_id;

  return jsonb_build_object(
    'deleted',true,
    'patient_id',p_patient_id,
    'film_restored_lines',restored_count,
    'film_restored_qty',restored_qty
  );
end;
$$;

revoke all on function public.admin_delete_patient(uuid) from public;
grant execute on function public.admin_delete_patient(uuid) to authenticated;

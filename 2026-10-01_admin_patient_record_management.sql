-- SATATA X-RAY: ADMIN patient record edit/delete
-- Fixes center-wide ADMIN management when records were created by COUNTER users.
-- ADMIN actions are executed through security-definer RPCs so RLS/user_id ownership
-- does not prevent the single center ADMIN from managing shared records.

create or replace function public.admin_update_patient(
  p_patient_id uuid,
  p_name text,
  p_age text,
  p_sex text,
  p_xray_type text,
  p_film_size text,
  p_film_qty integer,
  p_price_per_film numeric,
  p_doctor text,
  p_referrer_id uuid,
  p_payment_responsibility text,
  p_discount numeric,
  p_paid numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_row public.patients;
  new_row public.patients;
  old_film_size text;
  old_film_qty integer;
  new_film_size text := coalesce(nullif(trim(p_film_size),''),'14 × 17');
  new_film_qty integer := greatest(coalesce(p_film_qty,1),1);
  new_price numeric := greatest(coalesce(p_price_per_film,0),0);
  new_discount numeric := greatest(coalesce(p_discount,0),0);
  new_total numeric;
  new_paid numeric;
  new_due numeric;
  responsibility text := case when p_payment_responsibility = 'referrer' then 'referrer' else 'patient' end;
  selected_referrer_name text := '';
  commission numeric := 0;
  available numeric := 0;
  old_norm text;
  new_norm text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.active = true and up.role = 'admin'
  ) then
    raise exception 'Only ADMIN can edit patient records';
  end if;

  select * into old_row
  from public.patients
  where id = p_patient_id
  for update;

  if not found then
    raise exception 'Patient record not found';
  end if;

  old_film_size := coalesce(old_row.film_size,'14 × 17');
  old_film_qty := greatest(coalesce(old_row.film_qty,1),0);
  old_norm := lower(regexp_replace(trim(old_film_size),'[^0-9]+','x','g'));
  new_norm := lower(regexp_replace(trim(new_film_size),'[^0-9]+','x','g'));

  if p_referrer_id is not null then
    select coalesce(r.name,''), coalesce(xt.commission,0) * new_film_qty
      into selected_referrer_name, commission
    from public.referrers r
    left join public.xray_types xt
      on xt.user_id = r.user_id
     and lower(trim(xt.name)) = lower(trim(p_xray_type))
    where r.id = p_referrer_id
    limit 1;
    if not found then
      raise exception 'Selected referrer not found';
    end if;
  end if;

  new_total := greatest(0, (new_film_qty * new_price) - new_discount);
  new_paid := case when responsibility = 'referrer' then 0 else greatest(0, coalesce(p_paid,0)) end;
  if new_paid > new_total then new_paid := new_total; end if;
  new_due := case when responsibility = 'referrer' then 0 else greatest(0,new_total-new_paid) end;

  if responsibility = 'referrer' and p_referrer_id is null then
    raise exception 'Referrer is required when payment responsibility is Referrer';
  end if;

  if new_film_qty <= 0 then
    raise exception 'Film quantity must be greater than zero';
  end if;

  -- Check stock available for the edited film requirement. The existing
  -- patient's OUT transaction is still part of stock, so restore its old
  -- quantity virtually when the size is unchanged.
  select coalesce(sum(
    case when lower(trim(fs.type))='in' then fs.quantity
         when lower(trim(fs.type))='out' then -fs.quantity
         else 0 end
  ),0)
  into available
  from public.film_stock fs
  where lower(regexp_replace(trim(fs.film_size),'[^0-9]+','x','g')) = new_norm;

  if old_norm = new_norm then
    available := available + old_film_qty;
  end if;

  if available < new_film_qty then
    raise exception 'Insufficient film stock for edited record. Available: %, required: %', available, new_film_qty;
  end if;

  -- Update the patient record across the center, regardless of creator/user_id.
  update public.patients
  set
    name = trim(coalesce(p_name,'')),
    age = coalesce(p_age,''),
    sex = coalesce(p_sex,'Male'),
    xray_type = trim(coalesce(p_xray_type,'')),
    film_size = new_film_size,
    film_qty = new_film_qty,
    price_per_film = new_price,
    doctor = coalesce(p_doctor,''),
    referrer_id = p_referrer_id,
    referrer = selected_referrer_name,
    payment_responsibility = responsibility,
    discount = new_discount,
    total = new_total,
    paid = new_paid,
    due = new_due
  where id = p_patient_id
  returning * into new_row;

  -- Keep inventory correct by recording compensating stock movements.
  if old_norm = new_norm then
    if old_film_qty > new_film_qty then
      insert into public.film_stock(user_id,film_size,quantity,type,note)
      values(auth.uid(),old_film_size,old_film_qty-new_film_qty,'in','ADMIN edit: restored film difference for patient '||coalesce(new_row.name,''));
    elsif new_film_qty > old_film_qty then
      insert into public.film_stock(user_id,film_size,quantity,type,note)
      values(auth.uid(),new_film_size,new_film_qty-old_film_qty,'out','ADMIN edit: additional film used for patient '||coalesce(new_row.name,''));
    end if;
  else
    if old_film_qty > 0 then
      insert into public.film_stock(user_id,film_size,quantity,type,note)
      values(auth.uid(),old_film_size,old_film_qty,'in','ADMIN edit: restored old film size for patient '||coalesce(new_row.name,''));
    end if;
    insert into public.film_stock(user_id,film_size,quantity,type,note)
    values(auth.uid(),new_film_size,new_film_qty,'out','ADMIN edit: applied new film size for patient '||coalesce(new_row.name,''));
  end if;

  -- Rebuild this patient's commission/receivable due rows from the edited values.
  delete from public.referrer_transactions
  where patient_id = p_patient_id and type = 'due';

  delete from public.referrer_receivables
  where patient_id = p_patient_id and type = 'bill_due';

  if p_referrer_id is not null then
    if commission > 0 then
      insert into public.referrer_transactions(
        user_id,referrer_id,patient_id,invoice_no,type,amount,note
      )
      values(
        auth.uid(),p_referrer_id,p_patient_id,
        'INV-'||upper(right(replace(p_patient_id::text,'-',''),8)),
        'due',commission,
        'Commission for edited record: '||coalesce(new_row.xray_type,'')
      );
    end if;

    if responsibility = 'referrer' and new_total > 0 then
      insert into public.referrer_receivables(
        user_id,referrer_id,patient_id,invoice_no,type,amount,note
      )
      values(
        auth.uid(),p_referrer_id,p_patient_id,
        'INV-'||upper(right(replace(p_patient_id::text,'-',''),8)),
        'bill_due',new_total,
        'Edited patient bill payable by referrer: '||coalesce(new_row.name,'')
      );
    end if;
  end if;

  return to_jsonb(new_row);
end;
$$;

revoke all on function public.admin_update_patient(uuid,text,text,text,text,text,integer,numeric,text,uuid,text,numeric,numeric) from public;
grant execute on function public.admin_update_patient(uuid,text,text,text,text,text,integer,numeric,text,uuid,text,numeric,numeric) to authenticated;


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
  old_film_size text;
  old_film_qty integer;
  restored boolean := false;
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

  old_film_size := coalesce(old_row.film_size,'14 × 17');
  old_film_qty := greatest(coalesce(old_row.film_qty,0),0);

  -- Remove patient-linked financial due rows. Payment rows are not linked
  -- to this patient and are therefore preserved.
  delete from public.referrer_transactions
  where patient_id = p_patient_id and type = 'due';

  delete from public.referrer_receivables
  where patient_id = p_patient_id and type = 'bill_due';

  delete from public.patients where id = p_patient_id;

  if old_film_qty > 0 then
    insert into public.film_stock(user_id,film_size,quantity,type,note)
    values(auth.uid(),old_film_size,old_film_qty,'in','ADMIN delete: restored film for patient '||coalesce(old_row.name,''));
    restored := true;
  end if;

  return jsonb_build_object(
    'deleted',true,
    'patient_id',p_patient_id,
    'film_restored',restored,
    'film_qty',old_film_qty
  );
end;
$$;

revoke all on function public.admin_delete_patient(uuid) from public;
grant execute on function public.admin_delete_patient(uuid) to authenticated;

-- Purchase stock + machine stock separation for X-Ray film inventory.
-- Purchase stock = film purchased but not yet transferred into the machine.
-- Machine stock = existing film_stock ledger; X-Ray entry OUT and deletion RESTORE continue to use it.

create table if not exists public.film_purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  purchase_date date not null default current_date,
  film_size text not null,
  quantity integer not null check (quantity > 0),
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.film_machine_transfers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  film_size text not null,
  quantity integer not null check (quantity > 0),
  transfer_date timestamptz not null default now(),
  note text
);

alter table public.film_purchases enable row level security;
alter table public.film_machine_transfers enable row level security;

drop policy if exists "film_purchases_select_own" on public.film_purchases;
drop policy if exists "film_purchases_insert_admin" on public.film_purchases;
drop policy if exists "film_purchases_delete_admin" on public.film_purchases;
create policy "film_purchases_select_own" on public.film_purchases for select using (user_id = auth.uid());
create policy "film_purchases_insert_admin" on public.film_purchases for insert with check (user_id = auth.uid() and public.is_admin());
create policy "film_purchases_delete_admin" on public.film_purchases for delete using (user_id = auth.uid() and public.is_admin());

drop policy if exists "film_machine_transfers_select_own" on public.film_machine_transfers;
create policy "film_machine_transfers_select_own" on public.film_machine_transfers for select using (user_id = auth.uid());

create or replace function public.transfer_film_to_machine(
  p_film_size text,
  p_quantity integer,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_size text := trim(p_film_size);
  v_available integer;
begin
  if v_user is null then raise exception 'Not authenticated'; end if;
  if not public.is_admin() then raise exception 'Only ADMIN can transfer film into the machine'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'Quantity must be greater than zero'; end if;
  if v_size not in ('14 × 17','10 × 14','8 × 10') then raise exception 'Invalid film size'; end if;

  select
    coalesce((select sum(quantity) from public.film_purchases where user_id=v_user and film_size=v_size),0)
    -
    coalesce((select sum(quantity) from public.film_machine_transfers where user_id=v_user and film_size=v_size),0)
  into v_available;

  if v_available < p_quantity then
    raise exception 'Insufficient purchase stock. Available: %, requested: %', v_available, p_quantity;
  end if;

  insert into public.film_machine_transfers(user_id,film_size,quantity,note)
  values(v_user,v_size,p_quantity,nullif(trim(coalesce(p_note,'')),''));

  insert into public.film_stock(user_id,film_size,quantity,type,note)
  values(v_user,v_size,p_quantity,'in','Transferred from Purchase Stock to Machine Stock');

  return jsonb_build_object(
    'success',true,
    'purchase_stock',v_available-p_quantity,
    'machine_stock',(
      select coalesce(sum(case when lower(coalesce(type,''))='in' then quantity when lower(coalesce(type,''))='out' then -quantity else 0 end),0)
      from public.film_stock where user_id=v_user and lower(replace(replace(film_size,'×','x'),' ','')) =
        lower(replace(replace(v_size,'×','x'),' ',''))
    )
  );
end;
$$;

grant execute on function public.transfer_film_to_machine(text,integer,text) to authenticated;

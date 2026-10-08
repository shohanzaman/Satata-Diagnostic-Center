-- Blood Test catalog compatibility
-- The original Blood Test migration uses price. If an earlier draft created rate,
-- preserve those values and make price the application source of truth.

alter table if exists public.blood_test_types
  add column if not exists price numeric(12,2) not null default 0;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='blood_test_types'
      and column_name='rate'
  ) then
    execute 'update public.blood_test_types set price = rate where coalesce(price,0)=0 and rate is not null';
  end if;
end $$;

alter table if exists public.blood_test_types
  drop constraint if exists blood_test_types_rate_check;

alter table if exists public.blood_test_types
  add constraint blood_test_types_price_check
  check (price >= 0);

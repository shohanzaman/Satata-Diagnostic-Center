-- SATATA X-RAY: Admin-only operational data reset
-- This does NOT delete auth.users or user_profiles.
-- By default it clears transactions/records/stock only.
-- Pass TRUE to also clear X-Ray Types, Doctors and Referrers.

create or replace function public.admin_reset_center_data(
  p_include_master_data boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_patients bigint := 0;
  deleted_film bigint := 0;
  deleted_ref_txn bigint := 0;
  deleted_ref_recv bigint := 0;
  deleted_expenses bigint := 0;
  deleted_cash bigint := 0;
  deleted_audit bigint := 0;
  deleted_xray bigint := 0;
  deleted_doctors bigint := 0;
  deleted_referrers bigint := 0;
begin
  if not public.is_admin() then
    raise exception 'Only ADMIN can reset center data';
  end if;

  delete from public.referrer_receivables;
  get diagnostics deleted_ref_recv = row_count;

  delete from public.referrer_transactions;
  get diagnostics deleted_ref_txn = row_count;

  delete from public.film_stock;
  get diagnostics deleted_film = row_count;

  delete from public.expenses;
  get diagnostics deleted_expenses = row_count;

  delete from public.cash_drawers;
  get diagnostics deleted_cash = row_count;

  delete from public.patients;
  get diagnostics deleted_patients = row_count;

  if p_include_master_data then
    delete from public.xray_types;
    get diagnostics deleted_xray = row_count;

    delete from public.doctors;
    get diagnostics deleted_doctors = row_count;

    delete from public.referrers;
    get diagnostics deleted_referrers = row_count;
  end if;

  -- Remove historical audit entries after the data reset so the audit table
  -- does not preserve the test/reset history.
  if to_regclass('public.audit_logs') is not null then
    delete from public.audit_logs;
    get diagnostics deleted_audit = row_count;
  end if;

  return jsonb_build_object(
    'patients', deleted_patients,
    'film_stock', deleted_film,
    'referrer_transactions', deleted_ref_txn,
    'referrer_receivables', deleted_ref_recv,
    'expenses', deleted_expenses,
    'cash_drawers', deleted_cash,
    'audit_logs', deleted_audit,
    'xray_types', deleted_xray,
    'doctors', deleted_doctors,
    'referrers', deleted_referrers,
    'master_data_cleared', p_include_master_data
  );
end;
$$;

revoke all on function public.admin_reset_center_data(boolean) from public;
grant execute on function public.admin_reset_center_data(boolean) to authenticated;

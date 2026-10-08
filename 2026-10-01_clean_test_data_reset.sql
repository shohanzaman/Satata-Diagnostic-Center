-- SATATA X-RAY: CLEAN TEST DATA RESET
-- Purpose: remove old operational/test data before a fresh stock + patient-entry test.
--
-- PRESERVED:
--   user_profiles / login accounts
--   xray_types
--   doctors
--   referrers
--   film_stock_settings
--   device approvals
--   application configuration
--
-- DELETED:
--   patient records
--   film stock transactions
--   referrer commission ledger
--   referrer patient receivables
--   expenses
--   cash drawer records
--   audit/activity logs
--   legacy deleted-patient / patient-bill rows when those tables exist
--
-- Run this ONCE in Supabase SQL Editor.
-- This is intentionally NOT a DROP/DELETE of users or master configuration.

do $reset$
begin
  -- Child/transaction tables first.
  if to_regclass('public.referrer_receivables') is not null then
    execute 'delete from public.referrer_receivables';
  end if;

  if to_regclass('public.referrer_transactions') is not null then
    execute 'delete from public.referrer_transactions';
  end if;

  if to_regclass('public.patient_bills') is not null then
    execute 'delete from public.patient_bills';
  end if;

  if to_regclass('public.film_stock') is not null then
    execute 'delete from public.film_stock';
  end if;

  if to_regclass('public.expenses') is not null then
    execute 'delete from public.expenses';
  end if;

  if to_regclass('public.cash_drawers') is not null then
    execute 'delete from public.cash_drawers';
  end if;

  if to_regclass('public.deleted_patients') is not null then
    execute 'delete from public.deleted_patients';
  end if;

  if to_regclass('public.patients') is not null then
    execute 'delete from public.patients';
  end if;

  -- Remove generated operational logs after all delete-trigger activity.
  if to_regclass('public.audit_logs') is not null then
    execute 'delete from public.audit_logs';
  end if;

  if to_regclass('public.activity_logs') is not null then
    execute 'delete from public.activity_logs';
  end if;
end
$reset$;

select
  (select count(*) from public.patients) as patients_remaining,
  (select count(*) from public.film_stock) as film_stock_rows_remaining,
  (select count(*) from public.referrer_transactions) as commission_rows_remaining,
  (select count(*) from public.referrer_receivables) as receivable_rows_remaining,
  (select count(*) from public.expenses) as expense_rows_remaining;

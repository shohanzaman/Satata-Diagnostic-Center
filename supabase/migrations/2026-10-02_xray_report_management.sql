-- X-Ray paper-report management
create table if not exists public.xray_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  patient_id uuid not null references public.patients(id) on delete cascade,
  findings text not null default '',
  impression text not null default '',
  reporting_doctor text not null default '',
  report_status text not null default 'draft' check (report_status in ('draft','final')),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique(patient_id)
);

create index if not exists idx_xray_reports_user_created on public.xray_reports(user_id, created_at desc);
create index if not exists idx_xray_reports_patient on public.xray_reports(patient_id);

alter table public.xray_reports enable row level security;

drop policy if exists "Admin can manage xray reports" on public.xray_reports;
create policy "Admin can manage xray reports"
on public.xray_reports for all to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

drop policy if exists "Users can select own xray reports" on public.xray_reports;
create policy "Users can select own xray reports"
on public.xray_reports for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Users can insert own xray reports" on public.xray_reports;
create policy "Users can insert own xray reports"
on public.xray_reports for insert to authenticated
with check (
  (select auth.uid()) = user_id
  and exists (
    select 1 from public.user_profiles
    where id=auth.uid() and active=true and role in ('admin','counter')
  )
);

drop policy if exists "Users can update own xray reports" on public.xray_reports;
create policy "Users can update own xray reports"
on public.xray_reports for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete own xray reports" on public.xray_reports;
create policy "Users can delete own xray reports"
on public.xray_reports for delete to authenticated
using ((select auth.uid()) = user_id);

create or replace function public.touch_xray_report_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := timezone('utc', now());
  return new;
end;
$$;

drop trigger if exists trg_xray_reports_updated_at on public.xray_reports;
create trigger trg_xray_reports_updated_at
before update on public.xray_reports
for each row execute function public.touch_xray_report_updated_at();

revoke all on function public.touch_xray_report_updated_at() from public;
grant execute on function public.touch_xray_report_updated_at() to authenticated;

-- SATATA X-RAY: Final device approval code fix
-- Run this ONCE in Supabase SQL Editor.
-- This version uses only PostgreSQL built-in md5/random functions.
-- It does NOT depend on pgcrypto, gen_random_bytes(), or digest().

create or replace function public.admin_issue_device_code(p_request_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $device$
declare
  req public.device_approval_requests;
  code text;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can approve devices';
  end if;

  select * into req
  from public.device_approval_requests
  where id = p_request_id
    and status = 'pending'
  for update;

  if req.id is null then
    raise exception 'Device request not found or already processed';
  end if;

  code := upper(substr(
    md5(random()::text || clock_timestamp()::text || req.id::text),
    1,
    10
  ));

  update public.device_approval_requests
  set code_hash = md5(code),
      code_expires_at = now() + interval '10 minutes'
  where id = req.id;

  return code;
end;
$device$;

create or replace function public.verify_device_code(p_request_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $device$
declare
  req public.device_approval_requests;
begin
  select * into req
  from public.device_approval_requests
  where id = p_request_id
    and user_id = auth.uid()
    and status = 'pending'
  for update;

  if req.id is null then
    raise exception 'Device approval request not found';
  end if;

  if req.code_hash is null
     or req.code_expires_at is null
     or req.code_expires_at < now() then
    raise exception 'Approval code expired. Ask Admin for a new code.';
  end if;

  if md5(upper(trim(coalesce(p_code,'')))) <> req.code_hash then
    raise exception 'Invalid approval code';
  end if;

  insert into public.user_devices(
    user_id, device_key, device_label, approved, approved_at, last_seen_at
  )
  values(
    auth.uid(), req.device_key, req.device_label, true, now(), now()
  )
  on conflict (user_id, device_key) do update
    set approved=true,
        revoked_at=null,
        approved_at=now(),
        last_seen_at=now();

  update public.device_approval_requests
  set status='approved',
      approved_at=now()
  where id=req.id;

  return true;
end;
$device$;

revoke all on function public.admin_issue_device_code(uuid) from public;
grant execute on function public.admin_issue_device_code(uuid) to authenticated;

revoke all on function public.verify_device_code(uuid,text) from public;
grant execute on function public.verify_device_code(uuid,text) to authenticated;

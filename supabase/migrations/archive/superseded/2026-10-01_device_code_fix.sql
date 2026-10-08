-- SATATA X-RAY: Device code generation fix
-- Run this ONCE in Supabase SQL Editor.
-- Fixes: function gen_random_bytes(integer) does not exist
-- No device/table data is deleted.

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

  -- Generate a 10-character one-time code without gen_random_bytes().
  code := upper(substr(
    md5(random()::text || clock_timestamp()::text || req.id::text),
    1,
    10
  ));

  update public.device_approval_requests
  set code_hash = encode(digest(code,'sha256'),'hex'),
      code_expires_at = now() + interval '10 minutes'
  where id = req.id;

  return code;
end;
$device$;

revoke all on function public.admin_issue_device_code(uuid) from public;
grant execute on function public.admin_issue_device_code(uuid) to authenticated;

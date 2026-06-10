-- Petoki · 009 · Advisor-driven hardening
-- 1. Pin search_path on the one function that lacked it.
-- 2. Internal trigger functions should not be reachable via /rest/v1/rpc.
-- 3. RPCs meant for signed-in users should not be callable by anon.

alter function public.set_updated_at() set search_path = '';

revoke execute on function public.set_updated_at() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.sync_profile_pro() from public, anon, authenticated;
revoke execute on function public.enforce_pet_limit() from public, anon, authenticated;
revoke execute on function public.enforce_activity_type_limit() from public, anon, authenticated;

revoke execute on function public.generate_medication_doses(uuid, date) from public, anon;
revoke execute on function public.daily_activity_summary(uuid, date) from public, anon;

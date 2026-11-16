-- Puzzle Pig: a public keep-alive ping for the daily Supabase check.
-- Since 20261115_lock_down_security_definer_functions, signed-out callers
-- can't read any app table (row-level security calls current_user_family_id,
-- which anon can no longer run), so the daily keep-alive needs its own target.
-- keep_alive() runs a real query in Postgres, returns 'ok' and reads no
-- family data. It is the only thing signed-out callers can run.

create or replace function public.keep_alive()
returns text
language sql
stable
security invoker
set search_path = ''
as $$ select 'ok'::text $$;

comment on function public.keep_alive() is 'Daily keep-alive ping. Returns ok; reads no app data.';

revoke all on function public.keep_alive() from public;
grant execute on function public.keep_alive() to anon, authenticated, service_role;

notify pgrst, 'reload schema';

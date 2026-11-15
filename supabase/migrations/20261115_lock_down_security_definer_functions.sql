-- Puzzle Pig: stop signed-out callers (the "anon" role) from running the
-- SECURITY DEFINER functions. The app always signs in (anonymously) first,
-- so every call it makes runs as "authenticated" and keeps working.
-- Postgres grants EXECUTE to PUBLIC by default, so revoke that too.

-- Called by the app, or used inside row-level security policies.
do $$
declare f text;
begin
  foreach f in array array[
    'public.create_family_for_current_user(text, text, text)',
    'public.join_family_as_parent(text, text)',
    'public.join_family_for_current_user(text, text)',
    'public.parent_pin_status()',
    'public.verify_parent_pin(text)',
    'public.set_parent_pin(text, text)',
    'public.current_user_family_id()',
    'public.current_user_is_parent()',
    'public.add_chore_for_current_user(text)',
    'public.add_chore_for_current_user(text, uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- Trigger and event-trigger functions are never called directly; firing
-- them doesn't check EXECUTE.
revoke execute on function public.enforce_chore_approval() from public, anon, authenticated;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- This was the only one with no sign-in check (it told a signed-out caller
-- whether a family code exists).
create or replace function public.join_family_for_current_user(p_family_code text, p_display_name text default 'Child'::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_family_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select id into v_family_id
  from public.families
  where family_code = p_family_code;

  if v_family_id is null then
    raise exception 'Family code not found. Double-check and try again.';
  end if;

  insert into public.profiles (user_id, family_id, display_name, role)
  values (auth.uid(), v_family_id, p_display_name, 'child')
  on conflict (user_id) do update
    set family_id = v_family_id, display_name = p_display_name, role = 'child';
end;
$function$;

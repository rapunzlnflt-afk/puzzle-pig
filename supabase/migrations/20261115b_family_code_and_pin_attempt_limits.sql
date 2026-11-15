-- Puzzle Pig: attempt limits for family codes and the parent PIN.
--
-- Anyone can get a signed-in (anonymous) session, so the limits can't be per
-- user. Family codes are limited per connection (hashed IP) plus a global
-- backstop; the PIN is limited per family.
--
-- Wrong answers no longer raise an error: an error rolls back the whole
-- request, including the attempt counter, so a raising function can't count
-- its own failures. They return a normal "no" instead.
--
-- Limits
--   wrong family codes (join, or create with a taken code):
--     per connection 10 an hour and 30 a day; everyone together 300 an hour
--   wrong parent PINs: per family 5 per 15 minutes and 20 a day

-- ---------- counters ----------
create table if not exists public.pp_rate (
  bucket       text        not null,
  window_start timestamptz not null,
  hits         integer     not null default 0,
  primary key (bucket, window_start)
);
alter table public.pp_rate enable row level security;
revoke all on public.pp_rate from public, anon, authenticated;

create or replace function public.pp_rate_over(p_bucket text, p_window integer, p_limit integer)
 returns boolean
 language sql
 stable
 security definer
 set search_path to ''
as $$
  select coalesce((
    select r.hits from public.pp_rate r
    where r.bucket = p_bucket || ':' || p_window
      and r.window_start = to_timestamp(floor(extract(epoch from now()) / p_window) * p_window)
  ), 0) >= p_limit;
$$;

create or replace function public.pp_rate_add(p_bucket text, p_window integer)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $$
begin
  insert into public.pp_rate (bucket, window_start, hits)
  values (p_bucket || ':' || p_window,
          to_timestamp(floor(extract(epoch from now()) / p_window) * p_window), 1)
  on conflict (bucket, window_start) do update set hits = public.pp_rate.hits + 1;
  if random() < 0.02 then
    delete from public.pp_rate where window_start < now() - interval '2 days';
  end if;
end;
$$;

-- Caller's IP as a short hash, never stored raw. cf-connecting-ip is set by
-- Cloudflare in front of Supabase and can't be faked by the caller. No IP ->
-- null -> per-connection limits are skipped (the global one still applies).
create or replace function public.pp_client_ip_key()
 returns text
 language sql
 stable
 set search_path to ''
as $$
  select case when ip is null then null
    else left(encode(sha256(convert_to('puzzle-pig:' || ip, 'UTF8')), 'hex'), 32) end
  from (
    select coalesce(
      nullif(trim(h ->> 'cf-connecting-ip'), ''),
      nullif(trim(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1)), ''),
      nullif(trim(h ->> 'x-real-ip'), '')) as ip
    from (select coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json as h) a
  ) b;
$$;

create or replace function public.pp_code_limited(p_ip text)
 returns boolean
 language sql
 stable
 security definer
 set search_path to ''
as $$
  select public.pp_rate_over('code:all', 3600, 300)
      or (p_ip is not null and (public.pp_rate_over('code:ip:' || p_ip, 3600, 10)
                             or public.pp_rate_over('code:ip:' || p_ip, 86400, 30)));
$$;

create or replace function public.pp_code_miss(p_ip text)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $$
begin
  perform public.pp_rate_add('code:all', 3600);
  if p_ip is not null then
    perform public.pp_rate_add('code:ip:' || p_ip, 3600);
    perform public.pp_rate_add('code:ip:' || p_ip, 86400);
  end if;
end;
$$;

-- ---------- joining a family ----------
-- New entry point for the app: never raises for a wrong code, so the miss is
-- counted. Returns {ok:true, family_id} or {ok:false, error}.
create or replace function public.pp_join_family(p_family_code text, p_as_parent boolean default false, p_display_name text default null)
 returns json
 language plpgsql
 security definer
 set search_path to ''
as $$
declare
  v_uid uuid := auth.uid();
  v_ip  text := public.pp_client_ip_key();
  v_fid uuid;
  v_role text := case when p_as_parent then 'parent' else 'child' end;
begin
  if v_uid is null then
    return json_build_object('ok', false, 'error', 'not_signed_in');
  end if;
  if public.pp_code_limited(v_ip) then
    return json_build_object('ok', false, 'error', 'rate_limited');
  end if;
  select f.id into v_fid from public.families f where f.family_code = p_family_code;
  if v_fid is null then
    perform public.pp_code_miss(v_ip);
    return json_build_object('ok', false, 'error', 'not_found');
  end if;
  insert into public.profiles (user_id, family_id, display_name, role)
  values (v_uid, v_fid, coalesce(p_display_name, case when p_as_parent then 'Parent' else 'Kid' end), v_role)
  on conflict (user_id) do update
    set family_id = excluded.family_id, display_name = excluded.display_name, role = excluded.role;
  return json_build_object('ok', true, 'family_id', v_fid);
end;
$$;

-- The old entry points stay for phones still running an older app version.
-- A wrong code (or a limit) now returns nothing instead of raising, so it is
-- counted; the older app then shows "could not read family ID".
create or replace function public.join_family_as_parent(p_family_code text, p_display_name text default 'Parent'::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare r json;
begin
  r := public.pp_join_family(p_family_code, true, p_display_name);
  if r ->> 'error' = 'not_signed_in' then
    raise exception 'Not authenticated';
  end if;
  return (r ->> 'family_id')::uuid;
end;
$$;

create or replace function public.join_family_for_current_user(p_family_code text, p_display_name text default 'Child'::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare r json;
begin
  r := public.pp_join_family(p_family_code, false, p_display_name);
  if r ->> 'error' = 'not_signed_in' then
    raise exception 'Not authenticated';
  end if;
end;
$$;

-- ---------- creating a family ----------
-- A taken code used to raise a unique-violation error, which told the caller
-- the code exists. Now a taken code (or a limit) returns null and is counted
-- like a wrong code; the app just tries a fresh random code.
create or replace function public.create_family_for_current_user(p_family_name text, p_family_code text, p_display_name text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare
  v_user_id uuid := auth.uid();
  v_ip text := public.pp_client_ip_key();
  v_family_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if public.pp_code_limited(v_ip) then
    return null;
  end if;
  if exists (select 1 from public.families where family_code = p_family_code) then
    perform public.pp_code_miss(v_ip);
    return null;
  end if;

  insert into public.families (family_name, family_code)
  values (p_family_name, p_family_code)
  returning id into v_family_id;

  insert into public.profiles (user_id, family_id, role, display_name)
  values (v_user_id, v_family_id, 'parent', p_display_name)
  on conflict (user_id) do update
    set family_id = excluded.family_id,
        role = excluded.role,
        display_name = excluded.display_name;

  return v_family_id;
end;
$$;

-- Creating families directly (not through the function) would also reveal
-- taken codes. The app never does it.
revoke insert on public.families from anon, authenticated;

-- ---------- parent PIN ----------
-- Wrong PINs are counted per family, so new sign-ins don't reset the count.
-- Over the limit it raises too_many_pin_tries (nothing to roll back then); the
-- app still accepts the PIN saved on a parent's own phone, so a kid can't lock
-- a parent out of their own device.
create or replace function public.verify_parent_pin(p_hash text)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare
  v_existing text;
  v_fid uuid;
begin
  select f.id, f.parent_pin_hash into v_fid, v_existing
  from public.families f join public.profiles p on p.family_id = f.id
  where p.user_id = auth.uid();
  if v_existing is null then
    return false;
  end if;
  if public.pp_rate_over('pin:' || v_fid, 900, 5) or public.pp_rate_over('pin:' || v_fid, 86400, 20) then
    raise exception 'too_many_pin_tries';
  end if;
  if v_existing = p_hash then
    return true;
  end if;
  perform public.pp_rate_add('pin:' || v_fid, 900);
  perform public.pp_rate_add('pin:' || v_fid, 86400);
  return false;
end;
$$;

-- ---------- privileges ----------
do $$
declare f text;
begin
  foreach f in array array[
    'public.pp_rate_over(text, integer, integer)',
    'public.pp_rate_add(text, integer)',
    'public.pp_client_ip_key()',
    'public.pp_code_limited(text)',
    'public.pp_code_miss(text)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array[
    'public.pp_join_family(text, boolean, text)',
    'public.join_family_as_parent(text, text)',
    'public.join_family_for_current_user(text, text)',
    'public.create_family_for_current_user(text, text, text)',
    'public.verify_parent_pin(text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

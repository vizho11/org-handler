-- Org Handler — Esports Org Finance & Lobby Console — Supabase setup script
-- Run this once in your Supabase project's SQL Editor (Database -> SQL Editor -> New query).
-- Safe to re-run: uses "if not exists" / "or replace" everywhere.
--
-- Multi-tenant model: ONE shared deployment serves every customer org, isolated by org_id.
-- You (the seller) are the sole "superadmin" — you create each org (and its owner passcode)
-- from superadmin.html, which nobody else has the URL to. Each org's owner then signs into
-- index.html with that passcode and creates their own accountant/player accounts.

create extension if not exists pgcrypto;

-- ============================================================
-- TABLES
-- ============================================================

-- Platform superadmin passcode (you, the seller). Not tied to any one org.
create table if not exists admin_config (
  id boolean primary key default true check (id),
  passcode_hash text
);

-- Failed-auth tracker for rate limiting. Only failures get recorded (see
-- record_auth_attempt below), so normal correct-password use never accumulates.
create table if not exists auth_attempts (
  id bigserial primary key,
  target text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists auth_attempts_target_idx on auth_attempts(target, attempted_at);

-- One row per customer. Each org has its own owner passcode — created by you from
-- superadmin.html — and every other table below is scoped to one of these.
create table if not exists orgs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_name text not null default '',
  contact text not null default '',
  passcode_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Rosters. Each team gets its own slots (lobbies) and can be tagged on transactions.
create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references orgs(id) on delete cascade,
  name text not null,
  tag text default '',
  game text not null default 'BGMI',
  created_at timestamptz not null default now()
);

-- Accountant and player accounts. Org-owner-provisioned, never self-signup.
create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references orgs(id) on delete cascade,
  name text not null,
  email text not null unique,
  phone text default '',
  password_hash text not null,
  role text not null check (role in ('accountant','player')),
  team_id uuid references teams(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists members_team_idx on members(team_id);

-- A purchased lobby/scrim slot, assigned to a team for a given day. This is what the manager
-- buys from a custom-room host and hands to a team to play in.
create table if not exists slots (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references orgs(id) on delete cascade,
  team_id uuid references teams(id) on delete set null,
  slot_date date not null,
  start_time text default '',
  end_time text default '',
  lobby_type text not null default 'scrim',
  cost numeric not null default 0,
  status text not null default 'booked' check (status in ('booked','completed','cancelled')),
  notes text default '',
  created_at timestamptz not null default now()
);
create index if not exists slots_date_idx on slots(slot_date);
create index if not exists slots_team_idx on slots(team_id);

-- Finance ledger. type is income/expense; category is a small fixed list per type (see
-- index.html) so "some circumstances" spending still has a home without a schema change.
create table if not exists transactions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references orgs(id) on delete cascade,
  txn_date date not null default current_date,
  type text not null check (type in ('income','expense')),
  category text not null default 'other',
  amount numeric not null default 0,
  description text default '',
  team_id uuid references teams(id) on delete set null,
  slot_id uuid references slots(id) on delete set null,
  recorded_by text default '',
  created_at timestamptz not null default now()
);
create index if not exists transactions_date_idx on transactions(txn_date);
create index if not exists transactions_team_idx on transactions(team_id);

-- ============================================================
-- ONE-TIME MIGRATION (upgrading an already-live single-tenant install into this multi-tenant
-- shape). A brand-new install has every org_id column already nullable-then-backfilled to
-- nothing, so this whole block is a same-as-before no-op there.
-- ============================================================
alter table orgs add column if not exists owner_name text not null default '';
alter table orgs add column if not exists contact text not null default '';
alter table teams add column if not exists org_id uuid references orgs(id) on delete cascade;
alter table members add column if not exists org_id uuid references orgs(id) on delete cascade;
alter table slots add column if not exists org_id uuid references orgs(id) on delete cascade;
alter table transactions add column if not exists org_id uuid references orgs(id) on delete cascade;

do $$
declare
  v_default_org_id uuid;
  v_admin_hash text;
  v_needs_backfill boolean;
begin
  select exists(
    select 1 from teams where org_id is null
    union all select 1 from members where org_id is null
    union all select 1 from slots where org_id is null
    union all select 1 from transactions where org_id is null
  ) into v_needs_backfill;

  if v_needs_backfill then
    if not exists (select 1 from orgs where name = 'Default Org') then
      select passcode_hash into v_admin_hash from admin_config where id = true;
      insert into orgs (name, passcode_hash)
        values ('Default Org', coalesce(v_admin_hash, crypt(gen_random_uuid()::text, gen_salt('bf'))))
        returning id into v_default_org_id;
      -- The old single admin_config passcode is now spent as the Default Org's owner
      -- passcode — clear it so the real superadmin passcode has to be set fresh and stays
      -- a separate credential (see README: superadmin_set_passcode).
      if v_admin_hash is not null then
        update admin_config set passcode_hash = null where id = true;
      end if;
    else
      select id into v_default_org_id from orgs where name = 'Default Org';
    end if;

    update teams set org_id = v_default_org_id where org_id is null;
    update members set org_id = v_default_org_id where org_id is null;
    update slots set org_id = v_default_org_id where org_id is null;
    update transactions set org_id = v_default_org_id where org_id is null;
  end if;
end $$;

alter table teams alter column org_id set not null;
alter table members alter column org_id set not null;
alter table slots alter column org_id set not null;
alter table transactions alter column org_id set not null;

-- Indexed only now that org_id is guaranteed to exist (added above via ALTER for an
-- already-live install, or as part of CREATE TABLE for a fresh one).
create index if not exists teams_org_idx on teams(org_id);
create index if not exists members_org_idx on members(org_id);
create index if not exists slots_org_idx on slots(org_id);
create index if not exists transactions_org_idx on transactions(org_id);

-- ==SPLIT-POINT== if pasting this script in two parts, run everything above this line first,
-- confirm it succeeds, then run everything from here down as a second query.

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
-- Every table gets RLS enabled with ZERO policies, so there's no direct anon/authenticated
-- read or write at all. The only way in or out is through the SECURITY DEFINER functions
-- below, each of which re-verifies the caller's passcode/credentials itself — a direct API
-- call bypasses nothing.
alter table admin_config enable row level security;
alter table auth_attempts enable row level security;
alter table orgs enable row level security;
alter table teams enable row level security;
alter table members enable row level security;
alter table slots enable row level security;
alter table transactions enable row level security;

-- ============================================================
-- SECURE RPC FUNCTIONS (SECURITY DEFINER = runs with elevated privilege,
-- bypassing the RLS lockout above, but only doing exactly what's coded here)
-- ============================================================

-- Rate limiting ---------------------------------------------------------

create or replace function check_rate_limit(p_target text, p_max_attempts int default 8, p_window_minutes int default 15)
returns boolean
language sql security definer as $$
  select count(*) < p_max_attempts
  from auth_attempts
  where target = p_target and attempted_at > now() - (p_window_minutes || ' minutes')::interval;
$$;

create or replace function record_auth_attempt(p_target text)
returns void
language sql security definer as $$
  delete from auth_attempts where target = p_target and attempted_at < now() - interval '1 day';
  insert into auth_attempts(target) values (p_target);
$$;

-- Superadmin (you, the seller) --------------------------------------------------------

-- Signatures/behavior from the previous single-tenant "owner" auth no longer apply once an
-- org can have its own passcode — drop them so nothing stale lingers.
drop function if exists owner_verify_passcode(text);
drop function if exists owner_set_passcode(text);
drop function if exists owner_passcode_is_set();
drop function if exists caller_role(text, uuid, text);

create or replace function superadmin_passcode_is_set()
returns boolean
language sql security definer as $$
  select exists(select 1 from admin_config where passcode_hash is not null);
$$;

-- NOT callable by anon/authenticated (see revoke below) — only reachable from the Supabase
-- SQL editor (which runs as the postgres superuser and bypasses grants), e.g.:
-- select superadmin_set_passcode('yourpasscode');
create or replace function superadmin_set_passcode(p_passcode text)
returns boolean
language plpgsql security definer as $$
begin
  if exists(select 1 from admin_config where passcode_hash is not null) then
    return false; -- already set, refuse to overwrite silently
  end if;
  insert into admin_config (id, passcode_hash) values (true, crypt(p_passcode, gen_salt('bf')))
  on conflict (id) do update set passcode_hash = excluded.passcode_hash
  where admin_config.passcode_hash is null;
  return true;
end;
$$;
revoke execute on function superadmin_set_passcode(text) from public;

create or replace function superadmin_verify_passcode(p_passcode text)
returns boolean
language plpgsql security definer as $$
declare
  v_ok boolean;
begin
  if p_passcode is null or p_passcode = '' then
    return false;
  end if;
  if not check_rate_limit('superadmin') then
    return false;
  end if;
  select coalesce(
    (select passcode_hash = crypt(p_passcode, passcode_hash) from admin_config where id = true),
    false
  ) into v_ok;
  if not v_ok then
    perform record_auth_attempt('superadmin');
  end if;
  return v_ok;
end;
$$;

create or replace function superadmin_list_orgs(p_super_passcode text)
returns table(id uuid, name text, active boolean, created_at timestamptz, team_count bigint, member_count bigint)
language plpgsql security definer as $$
begin
  if not superadmin_verify_passcode(p_super_passcode) then
    raise exception 'invalid superadmin passcode';
  end if;
  return query
    select o.id, o.name, o.active, o.created_at,
      (select count(*) from teams t where t.org_id = o.id),
      (select count(*) from members m where m.org_id = o.id)
    from orgs o
    order by o.created_at desc;
end;
$$;

create or replace function superadmin_create_org(p_super_passcode text, p_org_name text, p_owner_passcode text)
returns jsonb
language plpgsql security definer as $$
declare
  v_id uuid;
begin
  if not superadmin_verify_passcode(p_super_passcode) then
    return jsonb_build_object('success', false, 'error', 'invalid superadmin passcode');
  end if;
  if p_org_name is null or trim(p_org_name) = '' then
    return jsonb_build_object('success', false, 'error', 'org name required');
  end if;
  if p_owner_passcode is null or length(p_owner_passcode) < 4 then
    return jsonb_build_object('success', false, 'error', 'owner passcode must be at least 4 characters');
  end if;
  insert into orgs (name, passcode_hash) values (trim(p_org_name), crypt(p_owner_passcode, gen_salt('bf')))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function superadmin_reset_org_passcode(p_super_passcode text, p_org_id uuid, p_new_owner_passcode text)
returns boolean
language plpgsql security definer as $$
begin
  if not superadmin_verify_passcode(p_super_passcode) then return false; end if;
  if p_new_owner_passcode is null or length(p_new_owner_passcode) < 4 then return false; end if;
  update orgs set passcode_hash = crypt(p_new_owner_passcode, gen_salt('bf')) where id = p_org_id;
  return found;
end;
$$;

create or replace function superadmin_set_org_active(p_super_passcode text, p_org_id uuid, p_active boolean)
returns boolean
language plpgsql security definer as $$
begin
  if not superadmin_verify_passcode(p_super_passcode) then return false; end if;
  update orgs set active = p_active where id = p_org_id;
  return found;
end;
$$;

-- Org owner auth (per-customer passcode) -------------------------------------------------

-- Rate-limited by a hash of the *attempted passcode itself* (not the org, which isn't known
-- yet at this point) so repeated guesses of the same wrong passcode still get locked out.
create or replace function org_owner_verify_passcode(p_passcode text)
returns uuid
language plpgsql security definer as $$
declare
  v_org_id uuid;
  v_target text;
begin
  if p_passcode is null or p_passcode = '' then
    return null;
  end if;
  v_target := 'orgowner:' || left(md5(p_passcode), 16);
  if not check_rate_limit(v_target) then
    return null;
  end if;
  select id into v_org_id from orgs where active and passcode_hash = crypt(p_passcode, passcode_hash) limit 1;
  if v_org_id is null then
    perform record_auth_attempt(v_target);
  end if;
  return v_org_id;
end;
$$;

-- Org profile (name/owner name/contact the owner fills in on first login, shown in the
-- sidebar instead of the generic "Owner" label) ------------------------------------------

create or replace function owner_get_profile(p_passcode text)
returns table(org_name text, owner_name text, contact text)
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
begin
  if v_org_id is null then
    raise exception 'invalid owner passcode';
  end if;
  return query select o.name, o.owner_name, o.contact from orgs o where o.id = v_org_id;
end;
$$;

create or replace function owner_update_profile(p_passcode text, p_org_name text, p_owner_name text, p_contact text)
returns boolean
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
begin
  if v_org_id is null then return false; end if;
  if p_org_name is null or trim(p_org_name) = '' then return false; end if;
  if p_owner_name is null or trim(p_owner_name) = '' then return false; end if;
  update orgs set name = trim(p_org_name), owner_name = trim(p_owner_name), contact = coalesce(trim(p_contact),'')
  where id = v_org_id;
  return found;
end;
$$;

-- Member auth (accountant / player) -------------------------------------------------------

create or replace function member_login(p_email text, p_password text)
returns jsonb
language plpgsql security definer as $$
declare
  v_email text := lower(trim(p_email));
  v_m members%rowtype;
  v_target text := 'mem:' || v_email;
  v_team_name text;
  v_org_active boolean;
begin
  if not check_rate_limit(v_target) then
    return jsonb_build_object('success', false, 'error', 'too_many_attempts');
  end if;
  select * into v_m from members where lower(email) = v_email;
  if not found then
    perform record_auth_attempt(v_target);
    return jsonb_build_object('success', false, 'error', 'no_account');
  end if;
  if not v_m.active then
    return jsonb_build_object('success', false, 'error', 'account_inactive');
  end if;
  select active into v_org_active from orgs where id = v_m.org_id;
  if not coalesce(v_org_active, false) then
    return jsonb_build_object('success', false, 'error', 'account_inactive');
  end if;
  if v_m.password_hash = crypt(p_password, v_m.password_hash) then
    select name into v_team_name from teams where id = v_m.team_id;
    return jsonb_build_object('success', true, 'member', jsonb_build_object(
      'id', v_m.id, 'name', v_m.name, 'email', v_m.email, 'phone', v_m.phone,
      'role', v_m.role, 'team_id', v_m.team_id, 'team_name', coalesce(v_team_name, '')
    ));
  else
    perform record_auth_attempt(v_target);
    return jsonb_build_object('success', false, 'error', 'wrong_password');
  end if;
end;
$$;

-- Shared helper: every member-scoped function below calls this itself rather than trusting
-- the client's "I'm already logged in" state — so calling the API directly, bypassing the
-- app's UI entirely, verifies nothing for free.
create or replace function verify_member_credentials(p_member_id uuid, p_password text)
returns boolean
language plpgsql security definer as $$
declare
  v_target text := 'mem:' || coalesce(p_member_id::text, 'null');
  v_ok boolean;
begin
  if p_member_id is null or p_password is null then
    return false;
  end if;
  if not check_rate_limit(v_target) then
    return false;
  end if;
  select exists(
    select 1 from members m join orgs o on o.id = m.org_id
    where m.id = p_member_id and m.active and o.active and m.password_hash = crypt(p_password, m.password_hash)
  ) into v_ok;
  if not v_ok then
    perform record_auth_attempt(v_target);
  end if;
  return v_ok;
end;
$$;

-- Resolves whoever is calling to (role, org_id). Every read/write RPC below calls this
-- itself (never trusting the client) to decide what the caller is allowed to see or do.
create or replace function resolve_caller(p_passcode text, p_member_id uuid, p_password text)
returns table(role text, org_id uuid)
language plpgsql security definer as $$
declare
  v_org_id uuid;
  v_role text;
begin
  if p_passcode is not null and p_passcode <> '' then
    v_org_id := org_owner_verify_passcode(p_passcode);
    if v_org_id is not null then
      return query select 'owner'::text, v_org_id;
      return;
    end if;
  end if;
  if p_member_id is not null and p_password is not null and verify_member_credentials(p_member_id, p_password) then
    select m.role, m.org_id into v_role, v_org_id from members m where m.id = p_member_id;
    return query select v_role, v_org_id;
    return;
  end if;
  return query select null::text, null::uuid;
end;
$$;

-- ============================================================
-- Members management (org-owner-only writes, scoped to the caller's org)
-- ============================================================

create or replace function owner_list_members(p_passcode text)
returns table(id uuid, name text, email text, phone text, role text, team_id uuid, team_name text,
              active boolean, created_at timestamptz)
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
begin
  if v_org_id is null then
    raise exception 'invalid owner passcode';
  end if;
  return query
    select m.id, m.name, m.email, m.phone, m.role, m.team_id, coalesce(t.name,''), m.active, m.created_at
    from members m left join teams t on t.id = m.team_id
    where m.org_id = v_org_id
    order by m.created_at desc;
end;
$$;

create or replace function owner_create_member(
  p_passcode text, p_name text, p_email text, p_phone text, p_password text,
  p_role text, p_team_id uuid
) returns jsonb
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
  v_email text := lower(trim(p_email));
  v_id uuid;
begin
  if v_org_id is null then
    return jsonb_build_object('success', false, 'error', 'invalid owner passcode');
  end if;
  if p_role not in ('accountant','player') then
    return jsonb_build_object('success', false, 'error', 'invalid role');
  end if;
  if exists(select 1 from members where lower(email) = v_email) then
    return jsonb_build_object('success', false, 'error', 'An account with this email already exists.');
  end if;
  if p_team_id is not null and not exists(select 1 from teams where id = p_team_id and org_id = v_org_id) then
    return jsonb_build_object('success', false, 'error', 'invalid team');
  end if;
  insert into members (org_id, name, email, phone, password_hash, role, team_id)
    values (v_org_id, trim(p_name), v_email, coalesce(p_phone,''), crypt(p_password, gen_salt('bf')), p_role, p_team_id)
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id, 'email', v_email);
end;
$$;

create or replace function owner_update_member(
  p_passcode text, p_member_id uuid, p_name text, p_phone text, p_role text, p_team_id uuid, p_active boolean
) returns boolean
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
begin
  if v_org_id is null then return false; end if;
  if p_role not in ('accountant','player') then return false; end if;
  if p_team_id is not null and not exists(select 1 from teams where id = p_team_id and org_id = v_org_id) then
    return false;
  end if;
  update members set name = trim(p_name), phone = coalesce(p_phone,''), role = p_role,
    team_id = p_team_id, active = p_active
  where id = p_member_id and org_id = v_org_id;
  return found;
end;
$$;

create or replace function owner_reset_member_password(p_passcode text, p_member_id uuid, p_new_password text)
returns boolean
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
begin
  if v_org_id is null then return false; end if;
  update members set password_hash = crypt(p_new_password, gen_salt('bf')) where id = p_member_id and org_id = v_org_id;
  return found;
end;
$$;

create or replace function owner_delete_member(p_passcode text, p_member_id uuid)
returns boolean
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
begin
  if v_org_id is null then return false; end if;
  delete from members where id = p_member_id and org_id = v_org_id;
  return found;
end;
$$;

-- ============================================================
-- Teams (org-owner-only writes, scoped to the caller's org; readable by any authorized caller)
-- ============================================================

create or replace function list_teams(p_passcode text, p_member_id uuid, p_password text)
returns table(id uuid, name text, tag text, game text, created_at timestamptz)
language plpgsql security definer as $$
declare
  v_org_id uuid;
begin
  select rc.org_id into v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_org_id is null then
    raise exception 'not authorized';
  end if;
  return query select t.id, t.name, t.tag, t.game, t.created_at from teams t where t.org_id = v_org_id order by t.name;
end;
$$;

create or replace function owner_create_team(p_passcode text, p_name text, p_tag text, p_game text)
returns jsonb
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
  v_id uuid;
begin
  if v_org_id is null then
    return jsonb_build_object('success', false, 'error', 'invalid owner passcode');
  end if;
  insert into teams (org_id, name, tag, game)
    values (v_org_id, trim(p_name), coalesce(p_tag,''), coalesce(nullif(trim(p_game),''),'BGMI'))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function owner_update_team(p_passcode text, p_team_id uuid, p_name text, p_tag text, p_game text)
returns boolean
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
begin
  if v_org_id is null then return false; end if;
  update teams set name = trim(p_name), tag = coalesce(p_tag,''), game = coalesce(nullif(trim(p_game),''),'BGMI')
  where id = p_team_id and org_id = v_org_id;
  return found;
end;
$$;

create or replace function owner_delete_team(p_passcode text, p_team_id uuid)
returns boolean
language plpgsql security definer as $$
declare
  v_org_id uuid := org_owner_verify_passcode(p_passcode);
begin
  if v_org_id is null then return false; end if;
  delete from teams where id = p_team_id and org_id = v_org_id;
  return found;
end;
$$;

-- ============================================================
-- Slots / lobbies (owner + accountant can write; any authorized caller in the same org can read)
-- ============================================================

create or replace function list_slots(p_passcode text, p_member_id uuid, p_password text, p_from date default null, p_to date default null)
returns table(id uuid, team_id uuid, team_name text, slot_date date, start_time text, end_time text,
              lobby_type text, cost numeric, status text, notes text, created_at timestamptz)
language plpgsql security definer as $$
declare
  v_org_id uuid;
begin
  select rc.org_id into v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_org_id is null then
    raise exception 'not authorized';
  end if;
  return query
    select s.id, s.team_id, coalesce(t.name,''), s.slot_date, s.start_time, s.end_time,
           s.lobby_type, s.cost, s.status, s.notes, s.created_at
    from slots s left join teams t on t.id = s.team_id
    where s.org_id = v_org_id
      and (p_from is null or s.slot_date >= p_from) and (p_to is null or s.slot_date <= p_to)
    order by s.slot_date desc, s.start_time;
end;
$$;

create or replace function create_slot(
  p_passcode text, p_member_id uuid, p_password text,
  p_team_id uuid, p_slot_date date, p_start_time text, p_end_time text,
  p_lobby_type text, p_cost numeric, p_notes text
) returns jsonb
language plpgsql security definer as $$
declare
  v_role text; v_org_id uuid;
  v_id uuid;
begin
  select rc.role, rc.org_id into v_role, v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_role not in ('owner','accountant') then
    return jsonb_build_object('success', false, 'error', 'not authorized');
  end if;
  if p_team_id is not null and not exists(select 1 from teams where id = p_team_id and org_id = v_org_id) then
    return jsonb_build_object('success', false, 'error', 'invalid team');
  end if;
  insert into slots (org_id, team_id, slot_date, start_time, end_time, lobby_type, cost, notes)
    values (v_org_id, p_team_id, p_slot_date, coalesce(p_start_time,''), coalesce(p_end_time,''),
            coalesce(nullif(trim(p_lobby_type),''),'scrim'), coalesce(p_cost,0), coalesce(p_notes,''))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function update_slot(
  p_passcode text, p_member_id uuid, p_password text,
  p_slot_id uuid, p_team_id uuid, p_slot_date date, p_start_time text, p_end_time text,
  p_lobby_type text, p_cost numeric, p_status text, p_notes text
) returns boolean
language plpgsql security definer as $$
declare
  v_role text; v_org_id uuid;
begin
  select rc.role, rc.org_id into v_role, v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_role not in ('owner','accountant') then return false; end if;
  if p_status not in ('booked','completed','cancelled') then return false; end if;
  if p_team_id is not null and not exists(select 1 from teams where id = p_team_id and org_id = v_org_id) then
    return false;
  end if;
  update slots set team_id = p_team_id, slot_date = p_slot_date, start_time = coalesce(p_start_time,''),
    end_time = coalesce(p_end_time,''), lobby_type = coalesce(nullif(trim(p_lobby_type),''),'scrim'),
    cost = coalesce(p_cost,0), status = p_status, notes = coalesce(p_notes,'')
  where id = p_slot_id and org_id = v_org_id;
  return found;
end;
$$;

create or replace function delete_slot(p_passcode text, p_member_id uuid, p_password text, p_slot_id uuid)
returns boolean
language plpgsql security definer as $$
declare
  v_role text; v_org_id uuid;
begin
  select rc.role, rc.org_id into v_role, v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_role not in ('owner','accountant') then return false; end if;
  delete from slots where id = p_slot_id and org_id = v_org_id;
  return found;
end;
$$;

-- ============================================================
-- Transactions / finance ledger (owner + accountant can write; any authorized caller in the
-- same org can read)
-- ============================================================

create or replace function list_transactions(p_passcode text, p_member_id uuid, p_password text, p_from date default null, p_to date default null)
returns table(id uuid, txn_date date, type text, category text, amount numeric, description text,
              team_id uuid, team_name text, slot_id uuid, recorded_by text, created_at timestamptz)
language plpgsql security definer as $$
declare
  v_org_id uuid;
begin
  select rc.org_id into v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_org_id is null then
    raise exception 'not authorized';
  end if;
  return query
    select tx.id, tx.txn_date, tx.type, tx.category, tx.amount, tx.description,
           tx.team_id, coalesce(t.name,''), tx.slot_id, tx.recorded_by, tx.created_at
    from transactions tx left join teams t on t.id = tx.team_id
    where tx.org_id = v_org_id
      and (p_from is null or tx.txn_date >= p_from) and (p_to is null or tx.txn_date <= p_to)
    order by tx.txn_date desc, tx.created_at desc;
end;
$$;

create or replace function create_transaction(
  p_passcode text, p_member_id uuid, p_password text,
  p_txn_date date, p_type text, p_category text, p_amount numeric, p_description text,
  p_team_id uuid, p_slot_id uuid, p_recorded_by text
) returns jsonb
language plpgsql security definer as $$
declare
  v_role text; v_org_id uuid;
  v_id uuid;
begin
  select rc.role, rc.org_id into v_role, v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_role not in ('owner','accountant') then
    return jsonb_build_object('success', false, 'error', 'not authorized');
  end if;
  if p_type not in ('income','expense') then
    return jsonb_build_object('success', false, 'error', 'invalid type');
  end if;
  if p_team_id is not null and not exists(select 1 from teams where id = p_team_id and org_id = v_org_id) then
    return jsonb_build_object('success', false, 'error', 'invalid team');
  end if;
  insert into transactions (org_id, txn_date, type, category, amount, description, team_id, slot_id, recorded_by)
    values (v_org_id, coalesce(p_txn_date, current_date), p_type, coalesce(nullif(trim(p_category),''),'other'),
            coalesce(p_amount,0), coalesce(p_description,''), p_team_id, p_slot_id, coalesce(p_recorded_by,''))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function update_transaction(
  p_passcode text, p_member_id uuid, p_password text,
  p_transaction_id uuid, p_txn_date date, p_type text, p_category text, p_amount numeric,
  p_description text, p_team_id uuid, p_slot_id uuid
) returns boolean
language plpgsql security definer as $$
declare
  v_role text; v_org_id uuid;
begin
  select rc.role, rc.org_id into v_role, v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_role not in ('owner','accountant') then return false; end if;
  if p_type not in ('income','expense') then return false; end if;
  if p_team_id is not null and not exists(select 1 from teams where id = p_team_id and org_id = v_org_id) then
    return false;
  end if;
  update transactions set txn_date = coalesce(p_txn_date, current_date), type = p_type,
    category = coalesce(nullif(trim(p_category),''),'other'), amount = coalesce(p_amount,0),
    description = coalesce(p_description,''), team_id = p_team_id, slot_id = p_slot_id
  where id = p_transaction_id and org_id = v_org_id;
  return found;
end;
$$;

create or replace function delete_transaction(p_passcode text, p_member_id uuid, p_password text, p_transaction_id uuid)
returns boolean
language plpgsql security definer as $$
declare
  v_role text; v_org_id uuid;
begin
  select rc.role, rc.org_id into v_role, v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_role not in ('owner','accountant') then return false; end if;
  delete from transactions where id = p_transaction_id and org_id = v_org_id;
  return found;
end;
$$;

-- ============================================================
-- Finance summary (readable by any authorized caller in the org, including players)
-- ============================================================

create or replace function get_finance_summary(p_passcode text, p_member_id uuid, p_password text)
returns jsonb
language plpgsql security definer as $$
declare
  v_org_id uuid;
  v_income numeric;
  v_expense numeric;
  v_slot_spend numeric;
  v_upcoming int;
begin
  select rc.org_id into v_org_id from resolve_caller(p_passcode, p_member_id, p_password) rc;
  if v_org_id is null then
    raise exception 'not authorized';
  end if;
  select coalesce(sum(amount),0) into v_income from transactions where org_id = v_org_id and type = 'income';
  select coalesce(sum(amount),0) into v_expense from transactions where org_id = v_org_id and type = 'expense';
  select coalesce(sum(cost),0) into v_slot_spend from slots where org_id = v_org_id and status <> 'cancelled';
  select count(*) into v_upcoming from slots where org_id = v_org_id and slot_date >= current_date and status = 'booked';
  return jsonb_build_object(
    'total_income', v_income, 'total_expense', v_expense, 'balance', v_income - v_expense,
    'slot_spend_total', v_slot_spend, 'upcoming_slots', v_upcoming
  );
end;
$$;

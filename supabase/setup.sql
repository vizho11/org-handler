-- Org Handler — Esports Org Finance & Lobby Console — Supabase setup script
-- Run this once in your Supabase project's SQL Editor (Database -> SQL Editor -> New query).
-- Safe to re-run: uses "if not exists" / "or replace" everywhere.

create extension if not exists pgcrypto;

-- ============================================================
-- TABLES
-- ============================================================

-- Singleton owner passcode (the manager who purchases slots and runs the org).
-- No direct anon access, only via the RPCs below.
create table if not exists admin_config (
  id boolean primary key default true check (id),
  passcode_hash text
);

-- Failed-auth tracker for rate limiting (owner passcode, member login). Only failures get
-- recorded (see record_auth_attempt below), so normal correct-password use never accumulates.
create table if not exists auth_attempts (
  id bigserial primary key,
  target text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists auth_attempts_target_idx on auth_attempts(target, attempted_at);

-- Rosters. Each team gets its own slots (lobbies) and can be tagged on transactions.
create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  tag text default '',
  game text not null default 'BGMI',
  created_at timestamptz not null default now()
);

-- Accountant and player accounts. Owner-provisioned, never self-signup. Owner isn't stored
-- here — it's the single admin_config passcode instead, same as the reference app pattern.
create table if not exists members (
  id uuid primary key default gen_random_uuid(),
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

-- Finance ledger. type is income/expense; category is free text (slot_purchase,
-- sponsorship, prize_money, salary, donation, equipment, travel, misc, ...) so the
-- accountant isn't boxed into a fixed list for "some circumstances" spends.
create table if not exists transactions (
  id uuid primary key default gen_random_uuid(),
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
-- ROW LEVEL SECURITY
-- ============================================================
-- Internal org tool, not a public marketplace — every table gets RLS enabled with ZERO
-- policies, so there's no direct anon/authenticated read or write at all. The only way in
-- or out is through the SECURITY DEFINER functions below, each of which re-verifies the
-- caller's owner passcode or member email+password itself — a direct API call bypasses
-- nothing.
alter table admin_config enable row level security;
alter table auth_attempts enable row level security;
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

-- Owner passcode ----------------------------------------------------------

create or replace function owner_passcode_is_set()
returns boolean
language sql security definer as $$
  select exists(select 1 from admin_config where passcode_hash is not null);
$$;

-- NOT callable by anon/authenticated (see revoke below) — only reachable from the Supabase
-- SQL editor (which runs as the postgres superuser and bypasses grants), e.g.:
-- select owner_set_passcode('yourpasscode');
create or replace function owner_set_passcode(p_passcode text)
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
revoke execute on function owner_set_passcode(text) from public;

create or replace function owner_verify_passcode(p_passcode text)
returns boolean
language plpgsql security definer as $$
declare
  v_ok boolean;
begin
  if p_passcode is null or p_passcode = '' then
    return false;
  end if;
  if not check_rate_limit('owner') then
    return false;
  end if;
  select coalesce(
    (select passcode_hash = crypt(p_passcode, passcode_hash) from admin_config where id = true),
    false
  ) into v_ok;
  if not v_ok then
    perform record_auth_attempt('owner');
  end if;
  return v_ok;
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
    select 1 from members
    where id = p_member_id and active and password_hash = crypt(p_password, password_hash)
  ) into v_ok;
  if not v_ok then
    perform record_auth_attempt(v_target);
  end if;
  return v_ok;
end;
$$;

-- Resolves whoever is calling to a role string ('owner' | 'accountant' | 'player' | null).
-- Every read/write RPC below calls this itself (never trusting the client) to decide what
-- the caller is allowed to do.
create or replace function caller_role(p_passcode text, p_member_id uuid, p_password text)
returns text
language plpgsql security definer as $$
declare
  v_role text;
begin
  if p_passcode is not null and p_passcode <> '' and owner_verify_passcode(p_passcode) then
    return 'owner';
  end if;
  if p_member_id is not null and p_password is not null and verify_member_credentials(p_member_id, p_password) then
    select role into v_role from members where id = p_member_id;
    return v_role;
  end if;
  return null;
end;
$$;

-- ============================================================
-- Members management (owner-only writes)
-- ============================================================

create or replace function owner_list_members(p_passcode text)
returns table(id uuid, name text, email text, phone text, role text, team_id uuid, team_name text,
              active boolean, created_at timestamptz)
language plpgsql security definer as $$
begin
  if not owner_verify_passcode(p_passcode) then
    raise exception 'invalid owner passcode';
  end if;
  return query
    select m.id, m.name, m.email, m.phone, m.role, m.team_id, coalesce(t.name,''), m.active, m.created_at
    from members m left join teams t on t.id = m.team_id
    order by m.created_at desc;
end;
$$;

create or replace function owner_create_member(
  p_passcode text, p_name text, p_email text, p_phone text, p_password text,
  p_role text, p_team_id uuid
) returns jsonb
language plpgsql security definer as $$
declare
  v_email text := lower(trim(p_email));
  v_id uuid;
begin
  if not owner_verify_passcode(p_passcode) then
    return jsonb_build_object('success', false, 'error', 'invalid owner passcode');
  end if;
  if p_role not in ('accountant','player') then
    return jsonb_build_object('success', false, 'error', 'invalid role');
  end if;
  if exists(select 1 from members where lower(email) = v_email) then
    return jsonb_build_object('success', false, 'error', 'An account with this email already exists.');
  end if;
  insert into members (name, email, phone, password_hash, role, team_id)
    values (trim(p_name), v_email, coalesce(p_phone,''), crypt(p_password, gen_salt('bf')), p_role, p_team_id)
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id, 'email', v_email);
end;
$$;

create or replace function owner_update_member(
  p_passcode text, p_member_id uuid, p_name text, p_phone text, p_role text, p_team_id uuid, p_active boolean
) returns boolean
language plpgsql security definer as $$
begin
  if not owner_verify_passcode(p_passcode) then return false; end if;
  if p_role not in ('accountant','player') then return false; end if;
  update members set name = trim(p_name), phone = coalesce(p_phone,''), role = p_role,
    team_id = p_team_id, active = p_active
  where id = p_member_id;
  return found;
end;
$$;

create or replace function owner_reset_member_password(p_passcode text, p_member_id uuid, p_new_password text)
returns boolean
language plpgsql security definer as $$
begin
  if not owner_verify_passcode(p_passcode) then return false; end if;
  update members set password_hash = crypt(p_new_password, gen_salt('bf')) where id = p_member_id;
  return found;
end;
$$;

create or replace function owner_delete_member(p_passcode text, p_member_id uuid)
returns boolean
language plpgsql security definer as $$
begin
  if not owner_verify_passcode(p_passcode) then return false; end if;
  delete from members where id = p_member_id;
  return found;
end;
$$;

-- ============================================================
-- Teams (owner-only writes; readable by any authorized caller)
-- ============================================================

create or replace function list_teams(p_passcode text, p_member_id uuid, p_password text)
returns table(id uuid, name text, tag text, game text, created_at timestamptz)
language plpgsql security definer as $$
begin
  if caller_role(p_passcode, p_member_id, p_password) is null then
    raise exception 'not authorized';
  end if;
  return query select t.id, t.name, t.tag, t.game, t.created_at from teams t order by t.name;
end;
$$;

create or replace function owner_create_team(p_passcode text, p_name text, p_tag text, p_game text)
returns jsonb
language plpgsql security definer as $$
declare
  v_id uuid;
begin
  if not owner_verify_passcode(p_passcode) then
    return jsonb_build_object('success', false, 'error', 'invalid owner passcode');
  end if;
  insert into teams (name, tag, game) values (trim(p_name), coalesce(p_tag,''), coalesce(nullif(trim(p_game),''),'BGMI'))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function owner_update_team(p_passcode text, p_team_id uuid, p_name text, p_tag text, p_game text)
returns boolean
language plpgsql security definer as $$
begin
  if not owner_verify_passcode(p_passcode) then return false; end if;
  update teams set name = trim(p_name), tag = coalesce(p_tag,''), game = coalesce(nullif(trim(p_game),''),'BGMI')
  where id = p_team_id;
  return found;
end;
$$;

create or replace function owner_delete_team(p_passcode text, p_team_id uuid)
returns boolean
language plpgsql security definer as $$
begin
  if not owner_verify_passcode(p_passcode) then return false; end if;
  delete from teams where id = p_team_id;
  return found;
end;
$$;

-- ============================================================
-- Slots / lobbies (owner + accountant can write; any authorized caller can read)
-- ============================================================

create or replace function list_slots(p_passcode text, p_member_id uuid, p_password text, p_from date default null, p_to date default null)
returns table(id uuid, team_id uuid, team_name text, slot_date date, start_time text, end_time text,
              lobby_type text, cost numeric, status text, notes text, created_at timestamptz)
language plpgsql security definer as $$
begin
  if caller_role(p_passcode, p_member_id, p_password) is null then
    raise exception 'not authorized';
  end if;
  return query
    select s.id, s.team_id, coalesce(t.name,''), s.slot_date, s.start_time, s.end_time,
           s.lobby_type, s.cost, s.status, s.notes, s.created_at
    from slots s left join teams t on t.id = s.team_id
    where (p_from is null or s.slot_date >= p_from) and (p_to is null or s.slot_date <= p_to)
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
  v_role text := caller_role(p_passcode, p_member_id, p_password);
  v_id uuid;
begin
  if v_role not in ('owner','accountant') then
    return jsonb_build_object('success', false, 'error', 'not authorized');
  end if;
  insert into slots (team_id, slot_date, start_time, end_time, lobby_type, cost, notes)
    values (p_team_id, p_slot_date, coalesce(p_start_time,''), coalesce(p_end_time,''),
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
  v_role text := caller_role(p_passcode, p_member_id, p_password);
begin
  if v_role not in ('owner','accountant') then return false; end if;
  if p_status not in ('booked','completed','cancelled') then return false; end if;
  update slots set team_id = p_team_id, slot_date = p_slot_date, start_time = coalesce(p_start_time,''),
    end_time = coalesce(p_end_time,''), lobby_type = coalesce(nullif(trim(p_lobby_type),''),'scrim'),
    cost = coalesce(p_cost,0), status = p_status, notes = coalesce(p_notes,'')
  where id = p_slot_id;
  return found;
end;
$$;

create or replace function delete_slot(p_passcode text, p_member_id uuid, p_password text, p_slot_id uuid)
returns boolean
language plpgsql security definer as $$
declare
  v_role text := caller_role(p_passcode, p_member_id, p_password);
begin
  if v_role not in ('owner','accountant') then return false; end if;
  delete from slots where id = p_slot_id;
  return found;
end;
$$;

-- ============================================================
-- Transactions / finance ledger (owner + accountant can write; any authorized caller can read)
-- ============================================================

create or replace function list_transactions(p_passcode text, p_member_id uuid, p_password text, p_from date default null, p_to date default null)
returns table(id uuid, txn_date date, type text, category text, amount numeric, description text,
              team_id uuid, team_name text, slot_id uuid, recorded_by text, created_at timestamptz)
language plpgsql security definer as $$
begin
  if caller_role(p_passcode, p_member_id, p_password) is null then
    raise exception 'not authorized';
  end if;
  return query
    select tx.id, tx.txn_date, tx.type, tx.category, tx.amount, tx.description,
           tx.team_id, coalesce(t.name,''), tx.slot_id, tx.recorded_by, tx.created_at
    from transactions tx left join teams t on t.id = tx.team_id
    where (p_from is null or tx.txn_date >= p_from) and (p_to is null or tx.txn_date <= p_to)
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
  v_role text := caller_role(p_passcode, p_member_id, p_password);
  v_id uuid;
begin
  if v_role not in ('owner','accountant') then
    return jsonb_build_object('success', false, 'error', 'not authorized');
  end if;
  if p_type not in ('income','expense') then
    return jsonb_build_object('success', false, 'error', 'invalid type');
  end if;
  insert into transactions (txn_date, type, category, amount, description, team_id, slot_id, recorded_by)
    values (coalesce(p_txn_date, current_date), p_type, coalesce(nullif(trim(p_category),''),'other'),
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
  v_role text := caller_role(p_passcode, p_member_id, p_password);
begin
  if v_role not in ('owner','accountant') then return false; end if;
  if p_type not in ('income','expense') then return false; end if;
  update transactions set txn_date = coalesce(p_txn_date, current_date), type = p_type,
    category = coalesce(nullif(trim(p_category),''),'other'), amount = coalesce(p_amount,0),
    description = coalesce(p_description,''), team_id = p_team_id, slot_id = p_slot_id
  where id = p_transaction_id;
  return found;
end;
$$;

create or replace function delete_transaction(p_passcode text, p_member_id uuid, p_password text, p_transaction_id uuid)
returns boolean
language plpgsql security definer as $$
declare
  v_role text := caller_role(p_passcode, p_member_id, p_password);
begin
  if v_role not in ('owner','accountant') then return false; end if;
  delete from transactions where id = p_transaction_id;
  return found;
end;
$$;

-- ============================================================
-- Finance summary (readable by any authorized caller, including players)
-- ============================================================

create or replace function get_finance_summary(p_passcode text, p_member_id uuid, p_password text)
returns jsonb
language plpgsql security definer as $$
declare
  v_income numeric;
  v_expense numeric;
  v_slot_spend numeric;
  v_upcoming int;
begin
  if caller_role(p_passcode, p_member_id, p_password) is null then
    raise exception 'not authorized';
  end if;
  select coalesce(sum(amount),0) into v_income from transactions where type = 'income';
  select coalesce(sum(amount),0) into v_expense from transactions where type = 'expense';
  select coalesce(sum(cost),0) into v_slot_spend from slots where status <> 'cancelled';
  select count(*) into v_upcoming from slots where slot_date >= current_date and status = 'booked';
  return jsonb_build_object(
    'total_income', v_income, 'total_expense', v_expense, 'balance', v_income - v_expense,
    'slot_spend_total', v_slot_spend, 'upcoming_slots', v_upcoming
  );
end;
$$;

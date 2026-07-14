# org-handler

Esports org finance & lobby console — sold as one shared product to multiple esports orgs.
Within each org: the owner (manager) purchases scrim/tournament slots and hands out daily
lobbies to teams; an accountant from within the org keeps the books; players get a read-only
view of the slot schedule and team finances.

Two static, no-build-step apps share one Supabase backend:

- **`index.html`** — the product every customer org uses day to day (Owner / Accountant /
  Player logins).
- **`superadmin.html`** — used only by you, the seller. Not linked from `index.html` anywhere
  — create it, share the URL with no one, and use it to create each customer's org and owner
  passcode.

All data (orgs, teams, members, slots, transactions) lives in a real **Supabase** (Postgres)
backend, so it syncs across every device.

Run either locally:

```
python3 -m http.server 8000
```

Then open http://localhost:8000/index.html or http://localhost:8000/superadmin.html.

## One-time backend setup

1. Create a free project at [supabase.com](https://supabase.com).
2. Open **SQL Editor → New query**, paste in the contents of `supabase/setup.sql`, and run
   it. It's idempotent — safe to re-run any time you pull in changes to that file. (If you're
   upgrading an already-live single-tenant install, see **Upgrading an existing install**
   below first.)
3. Set your superadmin passcode (this can only be done from the SQL editor, which runs as the
   Postgres superuser and bypasses the restriction that blocks it everywhere else):
   ```sql
   select superadmin_set_passcode('yourpasscode');
   ```
4. In **Project Settings → API**, copy your **Project URL** and **anon public** key, and
   paste them into the top of the `<script>` block in **both** `index.html` and
   `superadmin.html`:
   ```js
   const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
   const SUPABASE_ANON_KEY = 'YOUR-ANON-KEY';
   ```
5. Open `superadmin.html`, sign in with your superadmin passcode, and click **New Org** to
   create your first customer (or your own demo org). It shows you a generated owner
   passcode once — send that to the org's manager.

The Supabase JS client is vendored as `vendor-supabase-js.js` (same origin, no CDN).
Fonts (Archivo, Manrope, JetBrains Mono) are bundled in `fonts.css`, also with no CDN calls.

## Upgrading an existing (already-live) install

If you already ran an earlier single-tenant version of `supabase/setup.sql` and set an owner
passcode, re-running the current script auto-migrates you: it creates a **"Default Org"**
from your existing teams/members/slots/transactions, reusing your previous passcode as that
org's owner passcode (so nothing you already entered is lost or relabeled), then **clears your
old passcode** so it stops doubling as anything else. After re-running the script:

- If you already had real data (teams/slots/etc.), your old passcode now only unlocks the
  Owner tab for "Default Org" — you must set a **new, separate** superadmin passcode with
  `select superadmin_set_passcode('yourNEWsuperadminpasscode');` before `superadmin.html` will
  let you in.
- If you had zero data yet, your old passcode is untouched and works directly as your
  superadmin passcode — no extra step needed.
- Either way, check which case you're in with
  `select superadmin_verify_passcode('yourpasscode');` in the SQL editor.

## Roles

- **Superadmin** (you) — signs into `superadmin.html` with a passcode that isn't tied to any
  org. Creates orgs, sets/resets each org's owner passcode, and can deactivate an org (locks
  out its owner and every member instantly — e.g. for non-payment).
- **Owner** — a customer's manager. Signs into `index.html`'s Owner tab with the passcode you
  gave them (not an account). Full control within their own org: manages teams, creates/edits
  accountant & player accounts, and can do everything an accountant can.
- **Accountant** — a member account with `role = 'accountant'`. Can create/edit/delete slots
  and transactions, same as the owner, but cannot manage teams or other members' accounts.
- **Player** — a member account with `role = 'player'`. Read-only: sees the slot/lobby
  schedule and the team finance summary (balance, income, expenses, slot spend, ledger), but
  has no add/edit/delete controls anywhere.

Every org's data is isolated by `org_id` — an owner, accountant, or player from one org can
never see another org's teams, slots, members, or transactions.

## Logging in

- **Accountants & players** never self-signup — the org's owner creates each account (Members
  page → Add Member), which shows the initial password **once**; copy it and send it to that
  person directly (it can never be displayed again, only reset from the key icon next to
  their row).
- **Owner** login uses the passcode you (superadmin) generated for their org — there's no
  per-owner account, and no "forgot passcode" flow short of you resetting it from
  `superadmin.html`.
- **Superadmin** has no "forgot passcode" flow short of running
  `update admin_config set passcode_hash = null;` in the SQL editor and re-running
  `superadmin_set_passcode(...)`.

## Security model

Every table (`orgs`, `teams`, `members`, `slots`, `transactions`, plus the internal
`admin_config`/`auth_attempts`) has row-level security enabled with **zero** policies — there
is no direct anon read or write of any kind, even with the anon key. The only way in or out is
through `SECURITY DEFINER` functions in `supabase/setup.sql`, each of which re-verifies the
caller's passcode or member email+password itself (never trusting the client's "I'm logged in"
state), so calling the API directly bypasses nothing:

- Passwords and passcodes are hashed with `pgcrypto` and never returned by any function.
- Repeated wrong-password/passcode guesses get rate-limited and locked out for a few minutes
  (only failures count, so normal use is never throttled). Owner-passcode attempts are
  rate-limited by a hash of the guessed passcode itself, since which org it belongs to isn't
  known until after the check.
- Every data RPC resolves the caller to `(role, org_id)` itself via `resolve_caller` and scopes
  every read/write to that `org_id` — an owner or member cannot reach another org's rows no
  matter what IDs a forged request passes in.
- Players can read every slot and transaction in their own org (so the "team finance summary"
  is genuinely transparent), but every write RPC (`create_slot`, `update_transaction`,
  `owner_create_team`, etc.) re-checks the caller's role server-side and rejects anything a
  player or a forged request tries to do.
- Deactivating an org (`superadmin_set_org_active`) locks out its owner passcode and every
  member's login immediately, without deleting any of their data.

## Notes

- **Slots** are the lobbies the owner purchases from a custom-room host and hands to a team
  for a given day — date, start/end time, lobby type (scrim/tournament/practice/custom), cost,
  and status (booked/completed/cancelled).
- **Transactions** are the finance ledger: `type` is income or expense, `category` is a small
  fixed list per type (sponsorship/prize_money/donation/other for income;
  slot_purchase/salary/equipment/travel/other for expense) chosen so "some circumstances"
  spending still has a home without needing a new category added to the schema.
- **Finance summary** (balance, total income/expense, slot spend, upcoming lobby count) is
  computed server-side by `get_finance_summary`, scoped to the caller's org, and shown to
  every role, including players.
- **Member emails are globally unique** across every org (needed since `member_login` looks
  an email up before it knows which org it belongs to) — two different customer orgs can't
  both register the same person's email.

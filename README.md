# org-handler

Esports org finance & lobby console — the owner (manager) purchases scrim/tournament slots
and hands out daily lobbies to teams; an accountant from within the org keeps the books;
players get a read-only view of the slot schedule and team finances.

`index.html` is the whole app — no build step, no bundler. All data (teams, members, slots,
transactions) lives in a real **Supabase** (Postgres) backend, so it syncs across every device.

Run it locally:

```
python3 -m http.server 8000
```

Then open http://localhost:8000/index.html.

## One-time backend setup

1. Create a free project at [supabase.com](https://supabase.com).
2. Open **SQL Editor → New query**, paste in the contents of `supabase/setup.sql`, and run
   it. It's idempotent — safe to re-run any time you pull in changes to that file.
3. Set the owner passcode (this can only be done from the SQL editor, which runs as the
   Postgres superuser and bypasses the restriction that blocks it everywhere else):
   ```sql
   select owner_set_passcode('yourpasscode');
   ```
4. In **Project Settings → API**, copy your **Project URL** and **anon public** key, and
   paste them into `index.html` near the top of its `<script>` block:
   ```js
   const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
   const SUPABASE_ANON_KEY = 'YOUR-ANON-KEY';
   ```

The Supabase JS client is vendored as `vendor-supabase-js.js` (same origin, no CDN).
Fonts (Archivo, Manrope, JetBrains Mono) are bundled in `fonts.css`, also with no CDN calls.

## Roles

- **Owner** — signs in with the org-wide passcode (not an account). Full control: manages
  teams, creates/edits accountant & player accounts, and can do everything an accountant can.
- **Accountant** — a member account with `role = 'accountant'`. Can create/edit/delete slots
  and transactions, same as the owner, but cannot manage teams or other members' accounts.
- **Player** — a member account with `role = 'player'`. Read-only: sees the slot/lobby
  schedule and the team finance summary (balance, income, expenses, slot spend, ledger), but
  has no add/edit/delete controls anywhere.

## Logging in

- **Accountants & players** never self-signup — the owner creates each account (Members
  page → Add Member), which shows the initial password **once**; copy it and send it to that
  person directly (it can never be displayed again, only reset from the key icon next to
  their row).
- **Owner** login uses the shared passcode set in step 3 above — there's no per-owner account.
  The Owner tab is hidden from the login screen by default (so a customer you sell this to
  never sees it) — visit with `?ohowner=1` in the URL, e.g.
  `https://vizho11.github.io/org-handler/?ohowner=1`, to reveal it. This is obscurity, not real
  access control (anyone reading the source can find the parameter), but it keeps the option
  from ever appearing for regular members.
- There's no "forgot passcode" flow for the owner passcode short of running
  `update admin_config set passcode_hash = null;` in the SQL editor and re-running
  `owner_set_passcode(...)`. Member passwords, on the other hand, can be reset any time from
  the Members page.

## Security model

Every table (`teams`, `members`, `slots`, `transactions`, plus the internal
`admin_config`/`auth_attempts`) has row-level security enabled with **zero** policies — there
is no direct anon read or write of any kind, even with the anon key. The only way in or out is
through `SECURITY DEFINER` functions in `supabase/setup.sql`, each of which re-verifies the
caller's owner passcode or member email+password itself (never trusting the client's "I'm
logged in" state), so calling the API directly bypasses nothing:

- Passwords are hashed with `pgcrypto` and never returned by any function.
- Repeated wrong-password/passcode guesses get rate-limited and locked out for a few minutes
  (only failures count, so normal use is never throttled).
- Players can read every slot and transaction (so the "team finance summary" is genuinely
  transparent), but every write RPC (`create_slot`, `update_transaction`, `owner_create_team`,
  etc.) re-checks the caller's role server-side and rejects anything a player or a forged
  request tries to do.

## Notes

- **Slots** are the lobbies the owner purchases from a custom-room host and hands to a team
  for a given day — date, start/end time, lobby type (scrim/tournament/practice/custom), cost,
  and status (booked/completed/cancelled).
- **Transactions** are the finance ledger: `type` is income or expense, `category` is a small
  fixed list per type (sponsorship/prize_money/donation/other for income;
  slot_purchase/salary/equipment/travel/other for expense) chosen so "some circumstances"
  spending still has a home without needing a new category added to the schema.
- **Finance summary** (balance, total income/expense, slot spend, upcoming lobby count) is
  computed server-side by `get_finance_summary` and shown to every role, including players.

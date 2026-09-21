# Setting up the server side with Supabase

This is the step-by-step for moving Darul-Ilm Challenge's server side from Vercel
Blob to Supabase. Every step is something you do once; the SQL is already written
and tested in `supabase/schema.sql`.

## Should you do this at all?

The site works today. Sets are stored as one JSON document in Vercel Blob, the host
passphrase is checked server-side, and publishing works end to end. So be clear about
what you are buying.

**The real reason to move:** right now the correct answers are sent to every visitor's
browser, because the browser scores the quiz. Anyone can open devtools and read them
before answering. This was also true of the original hardcoded questions, so it is not
a regression — but it is the one thing the current design cannot fix.

Supabase fixes it properly. Questions are read through a view with **no answer column**,
and grading happens inside the database, which returns the answers only once an attempt
is submitted. That is verified — see "What the schema guarantees" below.

You also get, as a side effect:

- Real host accounts (email + password) instead of one shared passphrase.
- Sets and questions as queryable rows instead of one JSON blob.
- Somewhere to record attempts and scores, which is impossible today.

**What it costs you:** another service to manage, a database to keep an eye on, and
reads that hit Supabase rather than a Vercel edge cache. If you only ever wanted
"host publishes, visitors answer", what you have already does that.

---

## Step 1 — Create the project

1. Go to <https://supabase.com/dashboard> and sign in.
2. **New project**. Name it `darul-ilm`.
3. Pick a strong database password and **save it in your password manager** — it is
   shown once and you cannot recover it later.
4. Choose the region closest to your audience. For Rwanda, `eu-central-1` (Frankfurt)
   is usually the best of the available options.
5. Wait for provisioning (about two minutes).

## Step 2 — Create the schema

1. In the left sidebar open **SQL Editor** → **New query**.
2. Paste the entire contents of [`supabase/schema.sql`](../supabase/schema.sql) and **Run**.
3. Open another query, paste [`supabase/hardening.sql`](../supabase/hardening.sql) and **Run**.
   This one is not optional — without it the grading function leaks the answer key.

You should see `Success. No rows returned`. Notices about policies that "do not exist,
skipping" are normal on a first run — the file is written to be safe to re-run.

## Step 3 — Create your host account

The schema does not trust anyone by default; being signed in is not enough, your user
id has to be listed in the `hosts` table.

1. Sidebar → **Authentication** → **Users** → **Add user** → **Create new user**.
2. Enter your email and a password. Tick **Auto Confirm User** so you can sign in
   without an email round-trip.
3. Copy the new user's **UID**.
4. Back in **SQL Editor**, run this with your UID pasted in:

   ```sql
   insert into public.hosts (user_id) values ('PASTE-THE-UID-HERE');
   ```

5. Check it took:

   ```sql
   select * from public.hosts;
   ```

To add another host later, repeat steps 1–4. To revoke one:

```sql
delete from public.hosts where user_id = 'THEIR-UID';
```

## Step 3b — Turn on anonymous sign-ins

**Required.** Grading is one attempt per identity, so every visitor needs an
`auth.uid()`. Anonymous sign-in gives them one invisibly — there is no sign-up form
and the "no sign-up" promise on the landing page still holds.

Sidebar → **Authentication** → **Sign In / Providers** → **Anonymous sign-ins** → enable.

Without it, submitting an attempt fails with *"Sign in before submitting an attempt"*.

## Step 4 — Confirm the storage bucket

`schema.sql` creates a public `hero` bucket for the landing photo. Confirm it:
sidebar → **Storage**. You should see a bucket named **hero** marked public.

If it is missing, re-run just the storage section at the bottom of `schema.sql`.

## Step 5 — Collect the keys

Sidebar → **Project Settings** → **API**. You need:

| Key | Where it is used | Secret? |
|---|---|---|
| **Project URL** | Browser and server | No |
| **anon / public** key | Browser | No — it is safe to ship, RLS is what protects the data |
| **service_role** key | Server only | **Yes.** It bypasses every RLS policy |

> Never put the service_role key in the browser, in `dist/index.html`, or in the repo.
> If it leaks, rotate it immediately from the same page.

## Step 6 — Put them on Vercel

From the project directory:

```bash
vercel env add SUPABASE_URL production
vercel env add SUPABASE_ANON_KEY production
vercel env add SUPABASE_SERVICE_ROLE_KEY production
```

Each command waits for you to paste the value. Repeat with `preview` and `development`
in place of `production` if you want the other environments working too.

Check they landed:

```bash
vercel env ls
```

## Step 7 — Verify before wiring the app up

In the SQL editor, prove the important property — that a visitor cannot read answers:

```sql
set role anon;
select * from public.questions;             -- must fail: permission denied
select * from public.public_questions;      -- must work, and have no answer column
reset role;
```

If the first line returns rows instead of failing, stop and re-run `schema.sql`.

---

## What the schema guarantees

Each of these was run against the live project, not just a local database:

| Attack | Result |
|---|---|
| Visitor reads `questions` | `42501 permission denied` |
| Visitor reads `question_sets` | `42501 permission denied` |
| **Signed-in** non-host reads `questions` | `42501 permission denied` |
| Non-host calls `publish_set` | `403 Not authorised` |
| Non-host calls `host_set_detail` | `403 Not authorised` |
| Non-host calls `set_hero` | `403 Not authorised` |
| Non-host adds themselves to `hosts` | `42501 permission denied` |
| Non-host edits `site_settings` | blocked by RLS, hero unchanged |
| Anon calls `publish_set` | `401 permission denied for function` |
| `grade_attempt` with an empty submission | `28000 Sign in before submitting` |
| Second `grade_attempt` with better answers | replays the first score, does not regrade |
| `grade_attempt` while the round is live | returns `is_right` only — no `correct`, no `explanation` |
| `answer_key()` while the round is open | `23514 That set is still open` |
| Host publishes a valid set | `{"ok": true, "questions": 2}` |
| Host publishes `id = "BAD ID"` | rejected |
| Host publishes `c` outside the options | rejected |

### Why grading is one shot

`grade_attempt` used to regrade on every call, and calling it with `{}` returned every
correct answer and explanation. The anon key that permits the call ships in every
browser, so that was a full answer dump for anyone who looked.

Any grading function that can be called repeatedly leaks the key, so the fix is not to
hide the response but to limit the calls: the first submission is recorded in
`attempts` and every later call replays it. Calling early now burns your one attempt.

`site_settings.reveal_answers` controls when the key appears — `after_close` (the
default, and airtight) or `immediate`. Change it with:

```sql
select public.set_reveal_policy('immediate');
```

### Why hosts write through functions

The base tables are unreachable to `anon` and `authenticated`. Hosts publish through
`publish_set`, `delete_set`, `host_sets`, `host_set_detail`, `set_hero` and
`set_reveal_policy`, each of which checks `is_host()` first.

This matters because anonymous sign-ins make **every visitor** `authenticated`. Granting
that role table privileges would leave the answers protected by RLS alone — one policy
mistake from exposure — and `TRUNCATE` is not filtered by RLS at all.

## How the data maps across

| Today (Vercel Blob) | With Supabase |
|---|---|
| `data/sets.json` → `sets[]` | `question_sets` + `questions` tables |
| `sets[].questions[].c` | `questions.correct_index`, never sent to the browser |
| `hero` field in the JSON | `site_settings.hero_url` + the `hero` bucket |
| `HOST_PASS_HASH` + signed cookie | Supabase Auth + the `hosts` table |
| Phase computed in the browser | `public_sets.phase`, computed in SQL |
| Scoring in the browser | `grade_attempt()`, in the database |

## Things worth knowing

- **The anon key is meant to be public.** It identifies the project, it does not grant
  access. RLS and the grants in `schema.sql` are what protect the data.
- **A set's state is still derived from the clock.** `phase_of(opens_at, closes_at)`
  does in SQL exactly what the browser does today, so nothing has to be switched by
  hand and there is still no cron job.
- **Free tier projects pause after a week of inactivity.** A paused project returns
  errors until you resume it from the dashboard. Worth knowing before a launch.
- **Keep the fallback.** The app should still ship a bundled set so the landing page
  works if Supabase is unreachable.

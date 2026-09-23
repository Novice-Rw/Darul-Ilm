# Darul-Ilm Challenge

An Islamic knowledge testing platform.

**Discover yourself through Islam.** — *Uncover the depth of your faith, one question at a time.*

English · Kinyarwanda · Arabic (RTL) · dark / light · mobile first.
Developed by **Novice**.

---

## What it does

A host publishes a set of questions with an opening and a closing time. While the
set is open, visitors answer it one question at a time against a countdown. When
it closes, the set moves into the repository with its answer key and the landing
page invites visitors to explore past sets until the next one is posted.

Answers are held and marked by the database, never by the browser.

## Repository layout

| Path | What it is |
|---|---|
| `Darul-Ilm Challenge.dc.html` | The design source — **this is the file you edit** |
| `support.js` | Runtime the design source depends on |
| `assets/` | Logo and other static assets |
| `dist/index.html` | Built page that gets deployed — **generated, never edit by hand** |
| `tools/build-dist.py` | Rebuilds `dist/` from the design source |
| `tools/fonts-inline.html` | Inlined web fonts used by the build |
| `supabase/schema.sql` | Tables, views, policies and functions |
| `supabase/hardening.sql` | Grading rules and privilege restrictions |
| `supabase/leaderboard.sql` | Phone collection, rankings and masking |
| `supabase/config.toml` | Auth settings, applied with the Supabase CLI |
| `vercel.json` | Static hosting config and response headers |

## Requirements

- Python 3 (for the build script)
- Node.js, only if you want to serve the build locally
- A [Supabase](https://supabase.com) project
- A host for static files

## Setting up

### 1. Database

Create a Supabase project, then run the two SQL files in order from the
project's SQL editor:

1. `supabase/schema.sql`
2. `supabase/hardening.sql`
3. `supabase/leaderboard.sql`

Run them in that order. The second is not optional — it contains the rules that
decide when answers may be released. The third adds rankings and the handling of
entrants' phone numbers.

### 2. Auth

Two settings matter:

- **Anonymous sign-ins must be on.** Visitors are given an identity
  automatically so an attempt can be recorded against them. There is no sign-up
  form and visitors are never asked to register.
- **Sign-ups must stay enabled.** Turning them off also turns off anonymous
  sign-ins, which stops visitors submitting answers.

Both are set in `supabase/config.toml` and applied with:

```bash
supabase link --project-ref <your-project-ref>
supabase config push
```

### 3. Create a host

Hosts are not self-service. Create the account from the Supabase dashboard
under **Authentication → Users**, then record its user id in the `hosts` table:

```sql
insert into public.hosts (user_id) values ('<the-user-id>');
```

Being signed in is not enough on its own — an account only gains host
abilities once it is listed there. Remove access the same way:

```sql
delete from public.hosts where user_id = '<the-user-id>';
```

### 4. Point the app at your project

The build reads its project URL and public API key from constants near the top
of the logic block in `Darul-Ilm Challenge.dc.html`. Replace them with the
values from your own project, then rebuild.

### 5. Build

```bash
python3 tools/build-dist.py
```

This regenerates the app inside `dist/index.html`. Edits made directly to
`dist/index.html` are lost on the next build.

### 6. Serve locally

```bash
npx serve dist
```

Then open the address it prints. Serving the repository root instead of `dist`
shows a directory listing, because the built page lives in `dist/`.

### 7. Deploy

Deploy `dist/` as static files. `vercel.json` sets the output directory and the
response headers; if you host somewhere else, carry those headers across.

## Working on the app

Edit `Darul-Ilm Challenge.dc.html`, run the build, reload. The build is the only
step between the source and what ships.

Question sets are not part of the codebase. They are created by a host through
the app itself and stored in the database, so publishing a new set needs no
code change and no deploy.

## Publishing a set

Sign in as a host and fill in the form:

- **Set id** — lowercase letters, numbers and hyphens; identifies the set
- **Title** — English is required, Kinyarwanda and Arabic optional
- **Opens / Closes** — the window the set is available
- **Seconds per question** — the countdown shown on each question

Then add questions. Each has text, two or more options with one marked correct,
and an optional explanation shown in the answer key. Empty option boxes are
ignored. Questions can also be pasted in bulk as JSON.

Two durations are easy to confuse: *seconds per question* is the countdown on a
single question, while *opens to closes* is how long the whole set stays
available.

## Entrants, rankings and phone numbers

Entrants are never asked for a name. Before their answers are submitted they are
asked for a phone number, so the host can reach whoever finishes in the top
three.

That number is treated as private:

- The public rankings show it masked — `078•••••22` — never in full, and never
  alongside anything that identifies the person.
- The table holding attempts is unreadable to entrants. An entrant can see their
  own row and nothing else; the masked board is the only public route in.
- Only a host can see real numbers, through `host_leaderboard`, which refuses
  anyone not listed in `hosts`.
- Rankings count each number once, taking its best attempt, so extra anonymous
  identities cannot stuff the board.

Once prizes are handed out, a host can delete the numbers for a set from the
Rankings card. Keeping them longer than they are needed serves nobody.

## Conventions

- `dist/` is generated. Never hand-edit it.
- Keep question papers and other source material out of this repository.
- Never commit credentials, keys or tokens of any kind.
- Entrants' phone numbers are personal data. Do not copy them out of the
  database, and delete them once the prizes are settled.

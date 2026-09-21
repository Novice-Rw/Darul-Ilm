# Darul-Ilm

Islamic knowledge testing platform.
**Discover yourself through Islam.** — *Uncover the depth of your faith, one question at a time.*

English · Kinyarwanda · Arabic (RTL) · dark / light · responsive.
Developed by **Novice**.

## Contents

| Path | What it is |
|---|---|
| `Darul-Ilm Challenge.dc.html` | Design source — **edit this** |
| `tools/build-dist.py` | Rebuilds `dist/index.html` from the design source |
| `tools/fonts-inline.html` | The bundler's inlined @font-face css, used by the build |
| `support.js` | Runtime for the design file |
| `image-slot.js` | Design-time image drop slot |
| `assets/darul-ilm-logo.jpeg` | Logo |
| `dist/index.html` | Built page — deployed, **generated, do not hand-edit** |
| `api/` | Serverless routes: read sets, host auth, publish, hero upload |
| `vercel.json` | Vercel static config |
| `supabase/schema.sql` | Supabase schema — tables, RLS, server-side grading |
| `docs/supabase-setup.md` | Step-by-step Supabase setup |

After editing the design source, run:

```bash
python3 tools/build-dist.py
```

That regenerates the app template inside `dist/index.html`. Editing `dist/index.html`
by hand will be overwritten on the next build.

## Screens

- **Landing** — tagline, language choice (English / Kinyarwanda / Arabic), start.
- **Question flow** — one question per screen, host-set timer, free back/forward, nothing marked as you go.
- **Result** — score ring, green/red grid per question.
- **Answer key** — every question with your answer, the correct answer, a short explanation, and Download PDF.
- **Past question sets** — topic library (Swala live; Twahara, Swaumu, Seerah, Qur'an, Zakat queued).
- **Host console** — hidden; see below.

## The host door (do not publish)

The host portal is not linked from the landing page for visitors, but there is now a
**Host** button in the nav, plus two older ways in: tap the logo five times within ~1.8s,
or open the site with `#host` in the URL.

Access is checked **server-side**. `POST /api/auth` compares the passphrase against the
SHA-256 in the `HOST_PASS_HASH` environment variable and, on success, sets a signed
HttpOnly cookie that lasts 8 hours. Every write route re-checks that cookie, so reaching
the console UI grants nothing by itself — the passphrase never ships to the browser.

To change the passphrase, set a new hash and redeploy:

```bash
printf '%s' 'your new passphrase' | shasum -a 256
vercel env add HOST_PASS_HASH production
```

## How publishing works

A **question set** is one JSON document:

```json
{
  "id": "swala-round-1",
  "title": { "en": "…", "rw": "…", "ar": "…" },
  "opensAt": "2026-09-21T18:00:00Z",
  "closesAt": "2026-09-28T18:00:00Z",
  "secondsPerQuestion": 30,
  "questions": [ { "c": 2, "q": {…}, "o": {…}, "e": {…} } ]
}
```

A set's state is **derived from the clock**, never stored, so it opens and closes on its
own with no cron job and nothing to switch by hand:

| State | Condition | What visitors see |
|---|---|---|
| `scheduled` | `now < opensAt` | Nothing on the landing page yet |
| `live` | `opensAt ≤ now < closesAt` | Title, question count, a countdown, and **Begin** |
| `closed` | `now ≥ closesAt` | "New questions soon" plus a link to the repository |

Closed sets move into the repository automatically, with their answer keys. There is no
separate archive to maintain.

Two different durations, easy to confuse:

- **`secondsPerQuestion`** — the countdown on each individual question.
- **`opensAt` → `closesAt`** — how long the whole set stays available.

All published sets live in one JSON blob, `data/sets.json`, in Vercel Blob. `GET /api/sets`
returns it with `s-maxage=30`, so the edge cache serves repeat visitors and the function
runs at most about twice a minute.

### Environment variables

| Name | What it is |
|---|---|
| `HOST_PASS_HASH` | SHA-256 hex of the host passphrase |
| `HOST_SECRET` | Random string used to sign the session cookie |
| `BLOB_READ_WRITE_TOKEN` | Added automatically when a Blob store is connected |

## Run locally

```bash
# the deployable build (this is what Vercel serves)
npx serve dist        # -> http://localhost:3000
# or just open dist/index.html

# the design source, which needs support.js + image-slot.js from the repo root
npx serve .           # -> http://localhost:3000/Darul-Ilm%20Challenge.dc.html
```

There is no `index.html` at the repo root, so `npx serve .` shows a directory listing
rather than the app. Serve `dist` to see the built site.

## Push to GitHub

```bash
cd Darul-Ilm
git init
git add .
git commit -m "Darul-Ilm: design cut"
git branch -M main
git remote add origin https://github.com/Novice-Rw/Darul-Ilm.git
git push -u origin main
```

## Deploy on Vercel

1. Import `Novice-Rw/Darul-Ilm` — framework preset **Other**, output directory `dist`.
2. Add the domain in Vercel; in Namecheap Advanced DNS add a **CNAME**: host `challenge` → `cname.vercel-dns.com`.
3. Live at `https://challenge.darul-ilm.com`.

## Moving the server side to Supabase

Answers currently reach the browser, because the browser scores the quiz. That is the
one thing this architecture cannot fix. [`docs/supabase-setup.md`](docs/supabase-setup.md)
is the step-by-step for moving to Supabase, where questions are read through a view with
no answer column and grading happens in the database.

## Backend plan (recommended)

- Questions in a hosted store (Vercel Postgres or Upstash KV) so a new set needs **no redeploy**.
- Host auth: passphrase POSTed to an API route → signed HTTP-only cookie checked by Vercel middleware.
  Keep the door itself secret; the passphrase is the real lock.
- Timer is host-set per set and never shown on the landing page.
- Question types to support: multiple choice, checkbox, short answer, paragraph, dropdown, rating,
  linear scale, checkbox grid, multiple-choice grid, date & time.

## Question JSON shape

```json
{
  "topic": "Swala",
  "timer": 30,
  "type": "multiple-choice",
  "q": { "en": "...", "rw": "...", "ar": "..." },
  "o": { "en": ["..."], "rw": ["..."], "ar": ["..."] },
  "c": 2,
  "e": { "en": "...", "rw": "...", "ar": "..." }
}
```

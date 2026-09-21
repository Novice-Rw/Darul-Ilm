# Darul-Ilm

Islamic knowledge testing platform.
**Discover yourself through Islam.** — *Uncover the depth of your faith, one question at a time.*

English · Kinyarwanda · Arabic (RTL) · dark / light · responsive.
Developed by **Novice**.

## Contents

| Path | What it is |
|---|---|
| `Darul-Ilm Challenge.dc.html` | Design source (edit this) |
| `support.js` | Runtime for the design file |
| `image-slot.js` | Background photo drop slot |
| `assets/darul-ilm-logo.jpeg` | Logo |
| `dist/index.html` | Self-contained build — deploy this |
| `vercel.json` | Vercel static config |

## Screens

- **Landing** — tagline, language choice (English / Kinyarwanda / Arabic), start.
- **Question flow** — one question per screen, host-set timer, free back/forward, nothing marked as you go.
- **Result** — score ring, green/red grid per question.
- **Answer key** — every question with your answer, the correct answer, a short explanation, and Download PDF.
- **Past question sets** — topic library (Swala live; Twahara, Swaumu, Seerah, Qur'an, Zakat queued).
- **Host console** — hidden; see below.

## The host door (do not publish)

The host portal is not linked anywhere in the UI. Two ways in:

1. Tap the **DARUL-ILM logo 5 times within ~1.8 seconds**.
2. Open the site with **`#host`** in the URL — e.g. `https://challenge.darul-ilm.com/#host`.

Both land on the passphrase gate. The passphrase is **not stored in this repo** — only its
SHA-256 hash, in `HOST_PASS_SHA256`. To change it:

```bash
printf '%s' 'your new passphrase' | shasum -a 256
```

Paste the hash into `HOST_PASS_SHA256` in **both** `Darul-Ilm Challenge.dc.html` and
`dist/index.html`. Never commit the passphrase itself.

> **This is obfuscation, not security.** The check runs in the browser, so anyone willing to read
> the bundle can bypass the gate entirely. It stops casual access, nothing more. Do not treat
> unpublished questions as confidential until the server-side check below is built.

Inside the console: visual question builder (all ten question types, three language fields per
question, correct-answer marking, explanation), per-set timer, CSV/JSON bulk import, published-set
list, and the **Landing background** slot — drop the mosque photo there; it is blurred and blended
behind the hero automatically.

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

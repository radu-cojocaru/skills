---
name: on-track
description: >
  End-of-day honest check of what landed on main: classify the work, rate how
  well it served distribution, conversion, or learning versus busywork, and
  pick one next bet. Use when the user runs /on-track or directly asks
  "did I move the needle", "on track", "end of day", or "how was today".
disable-model-invocation: true
---

Reconstruct what landed, classify it, rate it, one next bet. Git shows what
was chosen to work on, not whether the market moved. Compass, not a KPI.

Run only on `/on-track` or a direct ask. Do not infer a score from a normal
engineering chat.

## Window

Default: **today**, local timezone, midnight through now.

Overrides from the prompt: `yesterday`, `this week` (Monday 00:00 local through
now), `last N days` / `N days` (rolling), or explicit dates.

One score for the whole window. Feature branches do not count.

## Evidence

```bash
git fetch origin main
```

Then first-parent history of **`origin/main`** in the window. If fetch fails,
say so and use local `main`.

```bash
git log origin/main --first-parent --since='<start>' --until='<end>' \
  --pretty=format:'%h %ad %an %s' --date=iso --stat
```

Read messages, paths, and short stat. Do not line-by-line review. Include
every author; agent commits still count.

Anything the user pastes (conversations, posts, sales, store numbers) is
first-class evidence and can raise the score with no impressive commits.

Do not pull billing, analytics, or store dashboards.

## Blank and rest

Empty `main` and no pasted context → headline `— Blank`, **no number**. Blind
spot is the body. Ask what the day was. Stop. When they reply, re-rate in this
thread with the full letter.

They say it was off / rest → `— Rest`, **no number**. Kind closer, a song, no
scolding. Skip **Tomorrow** unless the 7-day peek is a hygiene streak.

Empty ≠ drift. Drift is busy internal work.

## Rubric

Only these raise the score:

1. **Distribution** — in front of more of the right people
2. **Conversion** — easier or more compelling to pay
3. **Learning** — a real demand signal, not a cleaner codebase

**Hygiene** (breakage, cost bomb, keep-the-lights-on) is allowed and does not
raise the score. Volume of commits never raises the score.

Internal tooling, refactors, agent skills, and infra no stranger could feel
are **Leverage** or **Hygiene**, not a bet.

## Headline

`N/10 — {band}` plus one sentence for what this window actually was.

| Score | Band     | Meaning                                                                                 |
| ----- | -------- | --------------------------------------------------------------------------------------- |
| 1–2   | Drift    | Busy, internal, nobody outside the repo could feel it                                   |
| 3–4   | Hygiene  | Necessary plumbing. Allowed for a _day_. A _week_ of this is a 3–4 with a sharp verdict |
| 5–6   | A bet    | Customer-facing work landed, no signal yet                                              |
| 7–8   | Signal   | Distro, conversion, or a learning loop happened                                         |
| 9–10  | Traction | Rare. Money, a clear demand signal, or many of the right people saw it                  |

## Streak

If the window is **shorter than 7 days**, also read `origin/main` for the last
7 days. Score only this window; the peek is tone.

If 3 or more of those 7 calendar days are predominantly hygiene, leverage, or
drift, sharpen the verdict and the next bet. Blank/rest days do not count.
Do not average the peek into the number.

Skip the peek when the window is already ≥7 days. Then a hygiene-heavy window
**is** the 3–4.

## Letter

Same sections every time. Blunt co-founder. Short.

```markdown
## N/10 — {band}

One sentence.

### What landed

3–7 themes, not a commit dump, no SHAs. Each line:
`Theme — Distro|Conversion|Learning|Bet|Hygiene|Leverage|Drift` plus one clause.

### What counted

Only Distro / Conversion / Learning. If none: "Nothing a stranger could feel."

### What looked like progress

Tempting internal work. One or two lines.

### Blind spot

You can only see `main`. If I talked to users, posted, or sold, say so and
re-rate.
(Omit this section if they already pasted that context.)

### Tomorrow

Exactly one concrete bet, reacting to what git (and pasted context) showed.
A surface, an audience, or a hypothesis — not "work on distribution."
On windows longer than today, title this **Next**.
Hygiene as the bet only when something is on fire.
```

Then two closers, in order:

1. **Earned note** — one concrete thing from _this_ window that was actually
   good. On drift with nothing to praise, praise the looking, not the work.
2. **Song** — `If {today | this week | these N days} were a song, it would be
**Artist — Title**.` plus a YouTube link.

## Song

Match the window's **mood**, not a pun on the diff. Hygiene → workmanlike.
Drift → motion with no destination. A bet → tense, forward. Signal/traction →
something that lifts. Rest → gentle.

Widely known tracks, rotating genres (rock, indie, electronic, hip-hop, pop,
soul). Verify the song exists (search). Never invent a title. Prefer a real
YouTube watch URL; if that's shaky, `https://www.youtube.com/results?search_query=`
plus the artist and title. No novelty joke tracks. No Rickroll unless the day
earned the bit.

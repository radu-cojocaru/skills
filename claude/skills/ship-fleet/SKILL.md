---
name: ship-fleet
description: Dispatch several ready tickets at once, one per non-overlapping app, each on its own /ship-bg run, which merges its own PR when the gates hold. Use when the user asks to ship a batch, ship everything ready, or run the fleet.
disable-model-invocation: true
---

Start several tickets at once, each in its own app, each in its own
background `/ship-bg` run. Each run merges its own PR and runs its own
after-merge steps (`ship-bg/after-merge.md`), so nothing else needs
launching. Report and stop. Do not wait around.

This skill only picks tickets and launches agents. It never edits code, never
claims a label itself (`/ship-bg` claims its own), and never merges.

## 1. See what's already running

```
claude agents --json
gh issue list --search 'label:"agent:working","agent:review","agent:done"' --state open --json number,title,body,labels
```

Ignore `"kind": "interactive"` rows from the first command — those are the
user's own tabs, not agents.

Every issue the second command returns is **in flight**: still being built,
under review, or built and waiting to merge (an open issue only carries
`agent:done` before its PR lands — merging auto-closes it via `Fixes #N`).
Count them. That count is how much of the cap is already spent.

## 2. See what's ready

```
gh issue list --label agent:ready --state open --json number,title,body,createdAt
```

If this is empty, say so and stop. Nothing to dispatch.

## 3. Group every issue — in flight and ready — by the app it touches

The groups are the project's to define. Read the **Ship groups** section of
`CLAUDE.md` first: it names the groups, any directories that count as one
combined group, and anything that is always `wide`. Where it is silent, use
the defaults below.

Read each issue's title and body yourself and place it in exactly one group:

- One group per top-level `apps/*` directory it touches (in a repo without
  `apps/`, per top-level source directory), unless Ship groups combines some.
- **`wide`** — anything touching `packages/*` or other shared code, anything
  touching more than one app group, or anything outside the app directories
  entirely (repo root config, CI workflow files, docs). A `wide` ticket is exclusive: while one is
  in flight, nothing else may start, and a `wide` ticket may not start while
  anything else is in flight.
- If you genuinely cannot tell which app a **ready** ticket touches, leave it
  out. Do not guess at the cost of a bad overlap. Report it as skipped, with
  the reason, so the user can run `/ship-bg <id>` on it by hand.

A group occupied by an **in-flight** issue is **busy**. `wide` in flight makes
every group busy; anything else in flight makes `wide` busy.

## 4. Pick tickets

Cap: **4 in flight at once, fleet and manual runs combined.** Available slots
= 4 minus the in-flight count from step 1. If that is zero or less, say the
fleet is at capacity and stop — do not dispatch anything.

For each group that is **not busy** and has at least one ready ticket in it,
take the oldest ready ticket in that group (lowest `createdAt`). A `wide`
ready ticket only qualifies at all when nothing is in flight (see step 3) —
if anything is running, drop every `wide` candidate from this list and say
why.

Sort the remaining candidates oldest-first, across every group together — not
per group. Walk that list and pick tickets in order, up to the slot count,
with one rule that overrides the slot count: **the moment you pick a `wide`
ticket, stop — pick nothing else this round**, even if slots remain. This is
what keeps a `wide` ticket exclusive against tickets picked in the _same_
round, not just against ones already in flight. If the oldest candidate
overall is `wide`, it is the only ticket this round picks.

If nothing qualifies, say so — which groups were busy, which had no ready
ticket, which tickets were skipped as unclear — and stop.

## 5. Launch one `/ship-bg` per picked ticket

For each picked ticket, build its agent name exactly as `/ship` does:

```
slug=$(gh issue view <issue-id> --json title -q .title \
  | cut -d' ' -f1,2 \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' \
  | cut -c1-24)
name="ship-<issue-id>${slug:+-$slug}"
```

Then launch on `sonnet` (the fleet does not take a model argument — one model
for the whole batch keeps this predictable):

```
claude --bg --name "$name" --model sonnet \
  --permission-mode bypassPermissions --remote-control "$name" \
  "/ship-bg <issue-id>"
```

Same flags as `/ship`, same reasons: `--bg` alone (never `--bg -p`),
`--permission-mode bypassPermissions` or it blocks on the first edit,
`--model` passed explicitly so it never silently inherits this session's
model, `--name`/`--remote-control` matching so the run is reachable and
`/ship-status` reads it clearly.

## Report

One table: issue, group, agent name. Then, plainly:

- Which groups were busy, and with which in-flight issue.
- Which ready tickets were skipped as unclear, and why.

Then stop. Do not poll, do not wait, do not schedule a follow-up check — the
user reads this with `/ship-status` or by asking.

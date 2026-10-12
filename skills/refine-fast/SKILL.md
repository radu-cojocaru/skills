---
name: refine-fast
description: Refine a GitHub issue into a ticket an agent can implement alone, deciding everything reversible without asking. Use when the user wants refinement to move fast.
disable-model-invocation: true
---

Turn a draft issue into a ticket an agent can implement without help. Move
fast. Aim for one round of questions, or none.

A GitHub issue ID is usually given. If not, fetch the first 5 open drafts
(`gh issue list --label draft --state open --limit 5`) and ask which one.

## 1. Read

Read the issue. Read the code it touches. Read any doc in the area.

## 2. Decide

**The default is to decide, not to ask.** Most of refinement is you making
calls and writing them down.

The test is **reversibility**. If a wrong call costs an hour to undo, decide it
yourself. If it costs a rewrite, a bill, or a migration, ask.

**Decide alone, then record it:**

- File layout, module boundaries, naming, internal types.
- Which existing dependency to use. Anything the project already depends on.
- Test seams, test strategy, what to fake.
- Error handling, logging, retries, timeouts.
- Additive schema changes: new tables, new optional columns, new indexes.
- Refactors inside one app.
- Ticket wording, acceptance-criteria phrasing, first-draft copy.
- Anything that is a plain consequence of a decision the user already made.
- Anything verifiable in the codebase or vendor docs. Go verify it.

**Always ask — these are the hard-to-reverse ones:**

- A new service, a new worker, a new app, or a new paid third-party tool.
- Anything that changes spend, quotas, or a vendor bill.
- Anything that stores or sends personal data somewhere new.
- A frozen public contract: a URL, a webhook shape, a stored key layout, or
  anything an external caller has already integrated.
- A destructive migration — dropping or renaming anything holding data.
- What a user of the product sees or does. UX is the user's call.
- Pricing, and what a paid action unlocks.
- Dropping or adding an acceptance criterion.

When you cannot tell which side something is on, ask. A question costs one
exchange. An unasked product decision costs a rewrite.

## After-merge steps

If the ticket needs anything once it is live — a backfill, a check, a config
apply, or any other follow-up — add an `## After merge` section to the ticket:
one line per step, what it does, and who runs it, `agent` or `human`. The
step can use a command the ticket itself will add.

Mark a step `agent` yourself when a backup undoes it. Ask — recommending
`human` — when it moves money, contacts anyone outside the team, raises
spend, or cannot be undone from a backup.

## 3. Prototype, if the UI is not trivial

The user gives UI feedback on something they can look at, not on a paragraph
describing it. So build it before you ask about it.

**Build a prototype when** the ticket adds a new screen or flow, has more than
two visual states, or you would call the UI complex.

**Skip it when** the change is one field on an existing form, a copy change, or
a column in an existing table. Describe those in words.

Build one self-contained HTML file. No build step, no external requests —
the user opens it and it works.

Use the project's own design tokens when the repo has them: colors, type, and
spacing. Otherwise a neutral page is enough.
Show every state on one page — empty, loading, full, error. Use realistic
worst-case data: the longest name, the full list. Never the tidy sample that
flatters the design.

Then get it in front of the user, however this harness can:

- Publish it and send the link, if the harness hosts pages. In Claude Code
  that is an Artifact, and the user can comment on it directly.
- Otherwise write the file and tell the user the exact path to open in a
  browser.

Ask for feedback on the page, not on a description of it. Fold their notes
into the ticket.

## 4. Ask once

Ask everything in **one** batch. Up to 4 questions. Two options each, your
recommendation first and labelled `(Recommended)`, with one line on what each
option costs.

Use the harness's structured question tool if it has one — in Claude Code that
is `AskUserQuestion`. If it has none, ask in plain text with the same shape: a
numbered list, two labelled options per question, so the user can answer all of
them in a single reply.

If nothing crossed the line in step 2, ask nothing and go to step 5.

Do not open a second round unless an answer genuinely forks the design. Never
walk the decision tree one node at a time — that is what made refinement slow.

If the user wants the slow, thorough pass instead, that is `/refine` — it walks
the whole decision tree with `/grill-me`. This skill is the fast lane. Do not
turn it into the slow one.

## 5. Write the ticket

Write the refined description and the implementation plan into the issue body:

```
gh issue edit <id> --body-file <file>
```

The issue is the single place the plan lives. Only if the plan is too large for
a readable issue, save it as a `.md` in the relevant `docs/` folder and link it.

End the body with a **Decisions** table — every call you made alone, one row
each: the decision, and the alternative you rejected. This is how the user
catches a wrong turn cheaply. Link the prototype artifact if there is one.

The description must be detailed enough that an agent can implement the ticket
autonomously, with nobody to ask.

## 6. Hand off

```
gh issue edit <id> --add-label "agent:ready" --remove-label draft
```

Then say, in three lines: what the ticket does, what you decided alone that is
worth a second look, and that it is labeled `agent:ready`.

---
name: implement
description: Implement one named GitHub issue end to end — claim its agent:ready label, branch from origin/main, and open a PR. Only for an issue the user or an orchestrating skill names.
disable-model-invocation: true
---

A GitHub issue ID is usually given when this skill is invoked. If none is given, list open `agent:ready` issues (`gh issue list --label "agent:ready" --state open --limit 20`), keep only standalone ones (no parent and no sub-issues — a related-issue link in the body does not count as a parent), and ask which one to implement.

Read the issue. Implement **this ticket only**.

- If it still has the `draft` label, or it lacks `agent:ready` and the current branch does not already track this issue, stop and point at `/refine`.
- If it is a parent spec with sub-issues, stop.
- If the body lists blockers that are not done, stop.
- If it already has `agent:working` and the current branch does not track this issue, stop — another agent has it.

Claim the ticket **before** editing: remove `agent:ready` and add `agent:working`. If `agent:ready` is already gone, stop.

```
gh issue edit <id> --add-label "agent:working" --remove-label "agent:ready"
```

Follow the ticket's acceptance criteria and testing decisions. Use TDD at the seams named in the ticket.

Fetch `origin`, then open a new branch from `origin/main`.

If you abort after claiming, restore `agent:ready` and remove `agent:working`:

```
gh issue edit <id> --add-label "agent:ready" --remove-label "agent:working"
```

Commit on that branch.

Run the project's checks: lint, tests, and `format:check`.

Open a PR that references the issue (`Fixes #<id>`). Do not merge.

Once the PR is open, remove `agent:working` and add `agent:implemented`:

```
gh issue edit <id> --add-label "agent:implemented" --remove-label "agent:working"
```

Not `agent:done` — the code is written, but nothing has reviewed it yet. A
ticket implemented this way rests on `agent:implemented` until someone reviews
it.

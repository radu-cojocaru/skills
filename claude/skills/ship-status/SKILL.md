---
name: ship-status
description: One table of every running ship agent, claimed ticket and open PR. Use when the user asks for status, or what is running.
disable-model-invocation: true
---

Answer one question: what is in flight right now, and what needs me?

Read-only. Never claim a ticket, launch an agent, or push.

## Gather

Run all three. They are independent, so run them together.

```
claude agents --json
gh issue list --search 'label:"agent:working","agent:review","agent:done"' --state open --json number,title,updatedAt,labels
gh pr list --state open --json number,title,headRefName,statusCheckRollup,reviewDecision,mergeable
```

`agent:done` is in that search too, on purpose. An open ticket with
`agent:done` is either mid-merge (its `/ship-bg` agent is still running the
after-merge steps) or held: a merge gate failed and the PR waits for the
user. See "PRs held for the user" below.

`claude agents --json` lists sessions from every terminal, not just this one —
the daemon owns background sessions, so a closed tab does not hide its agent.
Ignore rows with `"kind": "interactive"`; those are the user's own tabs.

If `gh` fails, still report the agents. Say which part is missing.

## Report

One table, one row per ticket in flight. Join the three sources on the issue
number — it is in the branch name and in the PR title.

| Issue | Agent | PR  | CI  | State |
| ----- | ----- | --- | --- | ----- |

- **Agent** — the short id, or `—` if none is running for that ticket.
- **State** — `working`, `blocked`, `review`, `merging`, `held — <gate>`, or
  `stalled`.

Then, under the table, only the rows that need the user:

- **Blocked agents.** `claude agents --json` gives the state but not the reason.
  Read the reason from `~/.claude/jobs/<id>/state.json` — the `detail` and
  `needs` fields — and print it verbatim. A blocked agent waits forever, so
  this is the most useful line on the page.
- **Stalled agents.** Anything `working` with no update for over an hour.
- **Orphans.** A ticket labelled `agent:working` or `agent:review` with no
  running agent — the agent died. Say so, and say which label needs clearing
  before anyone can re-run it. `agent:working` means no review happened yet —
  the run may have stopped mid-implementation or just before the review.
  `agent:review` means the review started. Either way the label needs clearing
  before a re-run.

  A ticket on `agent:review` may have **no PR**: the review happens on the
  branch and the PR opens after it. Show `—` in the PR column, which the join
  already does.

  The comma in that search is an OR — two `--label` flags would mean AND and
  match nothing, since no ticket carries both.

- **PRs held for the user.** An `agent:done` ticket whose PR is open and
  whose agent is gone: `/ship-bg` refused to merge it. Print the gate it
  named in its PR comment. Never merge from here. While the agent is still
  running, list it as `merging`, not held — a manual merge underneath it
  races the agent's own rebase.
- **Open `human` issues** from after-merge hand-offs:
  `gh issue list --label human --state open`. One line each.

## Rules

The table plus the lines that need the user, nothing else — the user reads it
to find what is stuck. If nothing needs the user, say "nothing needs you" and
stop.

Do not summarise what the agents are building. The user knows. They want to
know what is stuck.

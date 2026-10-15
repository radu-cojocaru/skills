---
name: ship-status
description: One table of every running ship agent, claimed ticket and open PR, across every private repo of the owner. Use when the user asks for status, or what is running.
disable-model-invocation: true
---

Answer one question: what is in flight right now, and what needs me?

Read-only. Never claim a ticket, launch an agent, or push.

Works from any directory, repo or not. It covers every private repo of the
owner, not just the current one. It does not read the factory's state in
`factory/.local/`: GitHub and the daemon are the only sources.

## Gather

Run all three. They are independent, so run them together.

```
claude agents --json --all
owner=$(gh api user -q .login)
gh search issues --owner "$owner" --visibility private --archived=false --state open \
  --label agent:working --label agent:review --label agent:done --label agent:failed \
  --json repository,number,title,updatedAt,labels,url
gh search prs --owner "$owner" --visibility private --archived=false --state open \
  --json repository,number,title,url
```

`gh search` ORs its `--label` flags (unlike `gh issue list`, where two flags
mean AND), so one call returns every ticket on any of the four labels.

Search returns neither the branch name nor CI or merge state (`gh search prs
--json` has no `headRefName`). Look those up per PR, for the few open ones
whose title or number matches a ticket in the table:

```
gh pr view <n> --repo <owner/repo> --json headRefName,statusCheckRollup,reviewDecision,mergeable
```

`agent:done` is in that search too, on purpose. An open ticket with
`agent:done` is either mid-merge (its `/ship-bg` agent is still running the
after-merge steps) or held: a merge gate failed and the PR waits for the
user. See "PRs held for the user" below.

`claude agents --json --all` lists background sessions from every terminal
and every directory, not just this one — the daemon owns background sessions,
so a closed tab does not hide its agent. Ignore rows with
`"kind": "interactive"`; those are the user's own tabs.

**Match a session to a ticket by name and directory, both.** A ticket's
session is one whose `name` is `ship-<id>` or starts with `ship-<id>-`,
**and** whose `cwd` is that repo's clone or a directory inside it (the
`/ship-bg` worktrees live under the clone's `.claude/worktrees/`). The name
alone is not enough: issue numbers repeat across repos, so `ship-42` in one
clone and `ship-42` in another are two different tickets. When several
sessions match, take the newest `startedAt`.

If `gh` fails, still report the agents. Say which part is missing.

## Report

One table, one row per ticket in flight, for **repos with an agent running
only**. A repo with no matching session is left out of the table; its tickets
that need attention still appear under the headings below. Join the sources
on repo plus issue number — the number is in the branch name and in the PR
title.

| Repo | Issue | Agent | PR  | CI  | State |
| ---- | ----- | ----- | --- | --- | ----- |

- **Repo** — the short name (`repo`, not `owner/repo`) unless two owners are
  in play.
- **Agent** — the short id, or `—` if none is running for that ticket.
- **State** — `working`, `blocked`, `review`, `merging`, `held — <gate>`, or
  `stalled`.

Then, under the table, only the rows that need the user, each with its repo:

- **Needs you.** Every `agent:failed` ticket, one line each: repo, issue,
  title, and the reason, which is the first line of the issue's last comment
  (`gh issue view <n> --repo <repo> --json comments -q '.comments[-1].body'`).
  A `/ship-bg` run that aborted after claiming, the factory's stale check, or
  a declined launch set the label; relabelling the ticket `agent:ready` is
  how a human retries it.
- **Blocked agents.** `claude agents --json --all` gives the state but not
  the reason. Read the reason from `~/.claude/jobs/<id>/state.json` — the
  `detail` and `needs` fields — and print it verbatim. A blocked agent waits
  forever, so this is the most useful line on the page.
- **Stalled agents.** Anything `working` with no update for over an hour.
- **Orphans.** A ticket labelled `agent:working` or `agent:review` with no
  matching agent in its repo — the agent died. Say so, and say which label
  needs clearing before anyone can re-run it. `agent:working` means no review
  happened yet — the run may have stopped mid-implementation or just before
  the review. `agent:review` means the review started. Either way the label
  needs clearing before a re-run.

  A ticket on `agent:review` may have **no PR**: the review happens on the
  branch and the PR opens after it. Show `—` in the PR column, which the join
  already does.

- **PRs held for the user.** An `agent:done` ticket whose PR is open and
  whose agent is gone: `/ship-bg` refused to merge it. Print the gate it
  named in its PR comment. Never merge from here. While the agent is still
  running, list it as `merging`, not held — a manual merge underneath it
  races the agent's own rebase.
- **Open `human` issues** from after-merge hand-offs, across the owner's
  private repos:
  `gh search issues --owner "$owner" --visibility private --archived=false --state open --label human --json repository,number,title,url`.
  One line each, with the repo.

## Rules

The table plus the lines that need the user, nothing else — the user reads it
to find what is stuck. If nothing needs the user, say "nothing needs you" and
stop.

Do not summarise what the agents are building. The user knows. They want to
know what is stuck.

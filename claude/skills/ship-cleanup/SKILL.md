---
name: ship-cleanup
description: Remove what finished /ship runs left behind — merged worktrees, their branches, stale refs, and dead background-agent records.
disable-model-invocation: true
---

A finished `/ship` leaves five things behind, and none of them clears itself:

| Left behind                                   | Goes away on its own?       |
| --------------------------------------------- | --------------------------- |
| The background session process                | No — the daemon respawns it |
| `~/.claude/jobs/<id>/`                        | No — the daemon rewrites it |
| The worktree in `.claude/worktrees/` (locked) | No                          |
| The local branch                              | No                          |
| Stale `origin/*` refs                         | No                          |

`ship-cleanup.mjs` beside this file does all of it. Do not run the git commands
by hand — the script carries the safety checks.

## Run it

Dry run first. Always.

```
node .claude/skills/ship-cleanup/ship-cleanup.mjs
```

Read what it says. Then, if the plan is right:

```
node .claude/skills/ship-cleanup/ship-cleanup.mjs --apply
```

`--json` prints the same result as
`{ applied, removed[], skipped[], memory, freed }` if you need to act on it
rather than read it. `--keep-daemon` leaves the daemon up;
see below for why you rarely want that.

## Why it stops the daemon

**Deleting a job record does nothing while the daemon is up.** The daemon holds
the session list in memory — there is no file to prune, `~/.claude/daemon.json`
does not exist — so within seconds it rewrites every record you delete and
respawns the session behind it, each one dragging its whole transcript back
into RAM. Killing the processes frees nothing; they come back within a minute.
Only `claude daemon stop --any` releases the memory.

So `--apply` runs `claude daemon stop --any` **first**, then deletes the
records. Order matters: a record removed while the daemon runs comes straight
back. The daemon restarts on demand at the next `claude agents` or
`claude --bg`, so stopping it costs nothing once the sessions are dead.

It stops the daemon only when **both** are true: at least one job record is
being removed, and nothing live would be lost. If any agent survives the checks
below, the daemon stays up and the run says so — the records it removed may
come back until you stop it yourself.

## An agent's own status lies

A dead agent keeps saying `working` forever. It froze mid-wait, and the daemon
resurrects that frozen moment on every restart — timestamps included, so age
tells you nothing either. A record can read `working — PR launched, awaiting
CI` for a ticket that closed days ago and a PR that was never opened.

So the script does not trust the status. For any record that claims `working`
or `blocked`, it asks GitHub about the ticket in the record's `intent`, falling
back to the PRs in `children`. Ticket closed → the agent is a corpse, and the
record goes. Ticket open, or GitHub cannot answer → treated as live and kept.

Only an explicit reference counts as a ticket: `#N`, `/ship-bg N`, or the
`<command-args>N</command-args>` a slash command records. A bare number in
`intent` is free text the agent wrote — "Bump Node 24 in CI" must not resolve
to issue 24 — and reads as "cannot answer", so the record is kept.

**When judging an agent by hand, do the same:** read the ticket and PR state,
never the agent's own status line.

## What it will not touch

The script removes a worktree only when **all three** are true: its directory
name carries a number, its working tree is clean, and its PR is `MERGED`.
Anything else is listed under `Kept:` with the reason, and `--apply` refuses it
too. So a run during active work is a no-op.

**The number is what separates a `/ship` worktree from a hand-made one.**
`/ship` always names its worktree after the ticket, so a digit is the mark of a
machine-made one; `crawler-render` has none and is never touched, even with a
clean tree and a merged PR. It is a heuristic, not a proof — a hand-made
worktree called `fix-utf8` would still qualify — so the clean-tree and merged
checks remain the real guard. It exists so a worktree you are living in is not
swept up the moment its PR lands.

Two more details worth knowing, because they are why the checks look the way
they do:

- **Merged is asked of GitHub, not git.** A squash merge leaves no ancestry, so
  `git branch --merged` reports a landed branch as unmerged. The script asks
  `gh pr list --head <branch>` instead, and deletes with `-D` for the same
  reason.
- **Only `.claude/worktrees/` is in scope.** Worktrees elsewhere on the machine
  belong to something else and are never listed.

A job record is removed when its id is absent from `claude agents --json`
(the agent is gone), when its state is `done` or `stopped`, or when it claims
to be live but its ticket is closed on GitHub. If that command does not answer,
the script leaves every job record alone, keeps the daemon up, and says so.

- **Only this repo's job records are in scope.** `~/.claude/jobs/` is shared
  by every repo on the machine. The script touches a record only when the
  agent was launched from this repo, by the `cwd` in its `state.json`. Its
  ticket check asks `gh` about this repo, so it can't judge another repo's
  ticket numbers. Run it from each repo to clean that repo's records.
- **A live agent anywhere keeps the daemon up.** Stopping the daemon ends
  every background agent on the machine, so a `working` or `blocked` agent in
  another repo counts as live here too.
- **A resumed run keeps its predecessor's record.** A resume starts a new
  session under the same name, and it can keep using the stopped session's
  `tmp/`. While an agent with that name is live in this repo, the old record
  stays.

## The memory line

Every run ends with three short lines — short so they survive being read on a
phone:

```
Memory: 10.3 GiB of 15.2 GiB available
Swap:   3.0 GiB of 4.0 GiB used
Claude: 1.1 GiB in 6 procs
```

They are there because the leftovers this skill removes are, in practice, a
memory problem — dead sessions holding their whole transcripts in RAM. An
`--apply` run that actually freed something adds `(freed N GiB)` to the first
line.

Read `available`, not `free`: cache is reclaimable, so `free` always looks
worse than the box really is. Swap that is full is the sign to act. The line
comes from `/proc/meminfo`, so it is Linux-only and simply absent elsewhere.

## Report

Say what was removed, repeat every `Kept:` line with its reason — those are
the ones that need the user — and end with the three memory lines as printed. If nothing was found, say "nothing to clean up"
and stop.

Never remove by hand what the script refused. It refused for a reason: either
there is uncommitted work to look at, the PR has not landed, or an agent is
genuinely still going.

If it kept the daemon up because something was live, say so plainly — that is
the one case where the cleanup does not fully stick, and the user may want to
deal with the live agent and run again.

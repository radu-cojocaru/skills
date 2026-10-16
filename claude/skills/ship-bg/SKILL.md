---
name: ship-bg
description: The background half of /ship. Implements a ready issue on a branch, gets the branch reviewed by a fresh agent, applies the findings, opens the PR, merges it once CI is green and the gates hold, then runs the after-merge steps the ticket gives the agent and hands the rest to a human.
disable-model-invocation: true
---

Run the full loop for one ticket, end to end, without waiting for the human.

## Never stop to ask

This rule holds for every step below, not just the first one.

Make every decision yourself and write it on the GitHub issue. The user is away
from keyboard. Never stop to ask a question — a background agent that asks has
nobody listening, and it will sit blocked until someone notices.

If the ticket is already shipped — the issue closed, or its PR merged — there
is nothing left to do. Say so, name the PR, and end the run. Never ask which
ticket to ship instead.

Record each decision as you make it. You report them all at the end.

## 1. Implement, on a branch, without opening a PR

**Pick the ticket.** An issue id should have been given to you. If none is given, stop.

**Read the issue, then check it is yours to take.** Stop and report if any of
these holds:

- It still has the `draft` label, or it lacks `agent:ready` and the current
  branch does not already track this issue.
- It is a parent spec with sub-issues.
- Its body lists blockers that are not done.
- It already has `agent:working` and the current branch does not track this issue.

**Claim it before branching or editing:**

```
gh issue edit <issue-id> --add-label "agent:working" --remove-label "agent:ready"
```

If `agent:ready` is already gone, stop.

**Branch:**

- If the current branch already tracks this issue, keep it and work here.
- If this checkout is already a linked worktree based on latest `origin/main`
  (fetch first) and the working tree is clean, stay and create the issue branch
  here. Do not add another worktree.
- Otherwise fetch `origin/main` and add a new worktree with a new branch from
  that — named after the issue, not from a stale local `main`. Do the work in
  that worktree. Do not create the branch in the current checkout.

If you abort after claiming, mark the ticket failed and say why on the issue:

```
gh issue comment <issue-id> --body "<why the run stopped>"
gh issue edit <issue-id> --add-label "agent:failed" --remove-label "agent:working"
```

Never put `agent:ready` back. The factory relaunches every `agent:ready`
ticket, so a put-back would retry the same failing ticket every 5 minutes. A
human relabels it `agent:ready` once the ticket or the cause is fixed. The
stops above, before the claim, are different: they leave the ticket as it was.

**Implement this ticket only.** Follow its acceptance criteria and testing
decisions.

Do the coding yourself. However large the ticket looks, do not hand it to a
subagent or a fork — the one subagent in this run is the reviewer in step 3,
and it is spawned there for a reason it cannot get anywhere else: an empty
context. A fork here costs a second pass over everything you already know, and
if it dies quietly you wait on it forever.

**Write the after-merge commands** for the ticket's `## After merge` steps,
as `after-merge.md` beside this file describes. Read that file now; steps 3,
5, 7 and 8 depend on it.

**Commit, then run the project's checks:** lint, tests, and `format:check`.

**Push the branch, and stop there:**

```
git push -u origin <branch>
```

Open no PR. Change no label — leave `agent:working` in place; step 3 moves it
on.

Note the **branch name** and the **worktree path**. You need both. There is no
PR number yet, and nothing before step 5 needs one.

## 2. Rebase onto main

In the worktree:

```
git fetch origin && git rebase origin/main
```

Resolve conflicts the way `/fix-pr` describes: read each conflicted file in
full, keep both sides when they do not overlap, prefer this branch's intent
when they do, and remove every conflict marker.

If the rebase cannot be resolved, abort it, mark the ticket `agent:failed`
with a comment as step 1 says, and report. Do not open a PR on an unrebased
branch.

After a rebase, `git push --force-with-lease`. Never `git push --force`.

Rebase here rather than after the review.

## 3. Review on the branch, with a fresh agent

Mark the ticket as under review before you spawn anything:

```
gh issue edit <issue-id> --add-label "agent:review" --remove-label "agent:working"
```

Spawn a subagent **on Opus** (`model: "opus"`).

Pass this as the subagent's whole prompt:

```
Do a code review of the changes on the current branch. There is no PR — do not
look for one.

The diff under review is `git diff origin/main...HEAD`.

Give every finding an importance of P1, P2 or P3, and return them all in your
final message as one markdown table:

| #   | Finding                              |
| --- | ------------------------------------ |
| 1   | **P1 — apps/x/y.ts:42**<br>…         |

Each cell puts the priority and `File:line` on the first line, then the finding
itself on the next line, separated by `<br>`. Two columns, so the table stays
readable when GitHub renders it in a PR comment.

`File:line` is a repo-relative path plus a line number in this branch's version
of the file. That number is the only anchor the reader gets, so it has to be right.

If there is nothing to report, say "No findings" and still state what you
reviewed: the branch, the base commit, and whether you ran the tests.

If an `After-merge commands` section follows this prompt, review it too:
those commands run unattended against production after the merge. A dry run
that writes, a `max_rows` the data does not support, or a wrong `verify` is a
finding like any other.

Touch nothing on GitHub. Do not post a comment, do not edit code, do not push.
Your reply is the whole output.
```

Three rules, and all three matter:

- **Do not summarise your own work for it.** The reviewer must start cold. The
  empty context is the whole point.
- **Do not give it `isolation: "worktree"`.** It must run in the same worktree
  and on the same branch as step 1, so it can run the tests against the real
  code.
- **Pass `model: "opus"` explicitly.**

If there are after-merge commands, append them verbatim after the prompt under
the heading `After-merge commands`. That is the one thing you add: an artifact
for review, not a summary of your work.

If the worktree has no installed dependencies, install them there (the
project's install command is in CLAUDE.md) before spawning the reviewer, or its test runs will fail for the wrong
reason.

Store the table it returns, and the commit it reviewed. Both are input to
steps 4 and 5.

## 4. Apply the findings on the branch

For each finding: fix it, or write down in one sentence why not — the code is
correct, it is out of scope, or the reviewer misread it. Every finding gets one
or the other; none is dropped silently.

Then run the project's checks locally: lint, tests, and `format:check`.

Commit and push.

## 5. Open the PR, and post the review record on it

Write the PR body to a file first. It must contain `Fixes #<issue-id>` for the
issue to close on merge, and a file keeps a long body out of shell quoting.
If the ticket has after-merge steps, end the body with an `## After merge`
section: each step, who runs it, and for `agent` steps the commands.

```
gh pr create --title "<the ticket's title>" --body-file <body-file>
```

Do **not** use `--fill`. It lifts the title from a commit message only when the
branch holds exactly one commit; step 4 almost always adds a second, and from
two commits up gh falls back to humanising the branch name — every PR would
land titled `Worktree issue 592`. `--body-file` already replaces the autofilled
body, so `--fill` would contribute nothing but that wrong title.

`gh pr create` prints the PR's URL. **Take the number out of it and keep it.**
Every command below needs it, and nothing before this step had one.

Then post the review record straight away, before you go near CI:

```
gh pr comment <pr> --body-file <comment-file>
```

One comment, always — even when the reviewer found nothing. An empty PR looks
exactly like a skipped review, and this comment is the proof a review happened.

```
## Review (Opus, on the branch before the PR opened)

Reviewed <sha> against `origin/main`.

| #   | Finding                       | Handled                     |
| --- | ----------------------------- | --------------------------- |
| 1   | **P1 — apps/x/y.ts:42**<br>…  | Fixed in <sha> — <one line> |
| 2   | **P3 — apps/x/z.ts:7**<br>…   | Rejected — <one line>       |
```

Name the commit the review ran against, and **re-check every line number
against the branch tip before posting**. Step 4 edited the same files the
reviewer read, so a number captured before the fixes can now point at unrelated
code. That line is the only anchor a reader gets; a stale one is worse than
none.

With no findings, the comment says "No findings" plus what was reviewed —
branch, base commit, whether the tests ran.

## 6. Watch CI, and fix it once if it is red

```
gh pr checks <pr> --watch
```

Two normal outcomes look like failures and are not:

- **"no checks reported", exit 1, immediately.** GitHub needs a few seconds to
  register the runs, and this watch starts moments after the PR opens, with
  nothing in between to absorb that wait. Give it about a minute and run the
  command again.
- **"no checks reported" a second time.** Then no workflow matched this branch
  at all. The repo chose not to run CI on these paths, so the CI gate holds.
  Move on.

Give it up to 30 minutes. A slow pipeline delays the merge; it never
excuses one.

If any check ends `FAILURE` or `ERROR`, invoke `/fix-pr <pr>` **once** via the
Skill tool. It owns conflicts and failing checks; there are no review threads
for it to find. Then watch CI once more. Do not invoke `/fix-pr` a second
time: red after one fix means a human merges or not.

One review round only. Do not review again after fixing.

## 7. Merge, if every gate holds

Apply "The merge gates" in `after-merge.md`: label, review, CI, then the
pre-merge backup if there is a migration, then merge.

Before merging, label the ticket so a crash from here on reads as what it is:

```
gh issue edit <issue-id> --add-label "agent:done" --remove-label "agent:review"
```

If a gate fails, do not merge. Comment on the PR which gate failed and why,
hand every after-merge step to a human as `after-merge.md` says, and go to
the report.
The PR stays open for the user to merge by hand. This is a normal outcome, not
a failed run.

## 8. After merge: confirm the deploy, run the `agent` steps, hand off the rest

Follow `after-merge.md` from "Confirm the deploy" to the end, running the
commands the reviewer saw. With no steps, still confirm the deploy and post
the `## After merge` comment: the merge commit, and whether it is live.

## Report

End with the issue, the PR link, whether it merged (or which gate held it),
each after-merge step's outcome, the `human` issue if one was opened, and
every decision you made on your own.

List one line per decision: what you chose, and why you chose it over the
alternative. Include decisions from every step — implementing, reviewing, and
fixing. Say plainly which ones you are least sure about.

Also post this report as a comment on the PR:

```
gh pr comment <pr> --body-file <report-file>
```

This list is the only part the user reads closely. It is where they catch a
wrong turn. Do not summarise the code, and do not narrate progress.

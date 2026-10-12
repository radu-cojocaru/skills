---
name: fix-pr
description: Address review comments, failing checks and merge conflicts on one named GitHub PR, pushing to its branch. Only for a PR the user or an orchestrating skill names.
---

If a number was given, assume it's the GitHub PR. Otherwise use the PR for the current branch (`gh pr view`). If there is no PR, stop.

Do not merge.

## Setup

```
gh pr view <id> --json number,url,title,state,headRefName,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
```

If the PR is MERGED or CLOSED, stop.

Work on the PR's head branch:

- If the current branch already is that head, stay here.
- Otherwise `gh pr checkout <id>`. If that branch is already checked out in another worktree, add a new worktree for it and work there.

Fetch `origin` before rebasing or diagnosing conflicts.

## Order of work

1. **Merge conflicts** — if `mergeable` is `CONFLICTING` or `mergeStateStatus` is `DIRTY`.
2. **Failing checks** — any check with conclusion `FAILURE` or `ERROR`.
3. **Review comments** — unresolved inline threads and changes-requested review bodies.

Conflicts first: they often cause the CI failures.

## Merge conflicts

```
git rebase origin/<baseRefName>
```

During rebase, `HEAD` (above `=======`) is the base; the bottom section is this PR. Read each conflicted file in full, keep both sides when they do not overlap, prefer this PR's intent when they do, and remove every conflict marker. Then `git add` the resolved files and `git rebase --continue`.

If the rebase cannot be resolved, abort and report. After a successful rebase, push with `git push --force-with-lease`. Never `git push --force`.

## Failing checks

```
gh pr checks <id>
gh run view <run_id> --log-failed
```

Diagnose from the logs, fix the code, and commit. Re-run the project's checks locally before pushing: lint, tests, and `format:check`. Do **not** run `pnpm format` — it rewrites the whole repo.

Skip cancelled, timed-out, or still-pending checks. Do not wait on pending CI if review comments or known failures are already actionable.

## Review comments

Fetch unresolved review threads and any `CHANGES_REQUESTED` review body. Process every unresolved thread:

- If the comment is a reasonable code change, make it now. Push first, then reply on the thread with the commit SHA and what changed.
- If the current code is correct, the suggestion is out of scope, or it is a question, reply with a substantive technical explanation. Do not acknowledge-and-defer.

Do not post a summary comment on the PR.

## Finish

Commit remaining fixes on the PR branch and push. Confirm conflicts are gone and the local checks you ran are green. Leave merging to a human.

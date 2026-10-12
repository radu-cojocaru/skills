---
name: cleanup-branches
description: >
  Delete local git branches whose PRs were squash-merged into main. Use when
  the user runs /cleanup-branches or asks to prune, delete, or clean up
  local branches that already landed.
disable-model-invocation: true
---

A squash merge leaves no ancestry, so `git branch --merged` reports a landed
branch as unmerged. Ask GitHub whether the branch's PR is MERGED, then delete
with `-D`.

## Run

1. `git fetch origin --prune`
2. List local branches (`git for-each-ref --format='%(refname:short)' refs/heads/`). Skip `main`. Skip any branch checked out in another worktree (`git worktree list`).
3. For each remaining branch, ask GitHub:

```
gh pr list --head <branch> --state merged --limit 1 --json number,title,url,headRefOid,mergedAt
```

A hit means the work landed. That branch is a candidate, unless local
`HEAD` is not `headRefOid` — then the branch moved after the merge; keep it.

4. Show three lists: **delete** (branch, PR number, title), **keep** (open PR, no PR, closed-unmerged, extra local commits, checked out elsewhere), and **skip** (`main`). Then delete each candidate:

```
git branch -D <branch>
```

If the current branch is a candidate, switch to `main` first.

Do not delete a branch with an open PR, with no PR, or with only a closed (unmerged) PR. Do not remove worktrees;

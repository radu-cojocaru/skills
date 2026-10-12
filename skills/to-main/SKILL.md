---
name: to-main
description: Commit these changes and push directly to main
disable-model-invocation: true
---

Commit the current changes and push them to `origin/main`. Do not open a PR.

## Land

1. `git status` and `git fetch origin`.
2. If the working tree is dirty, stage the files that belong to this work and commit. Write a message that describes the change.
3. Get the commit(s) onto local `main`:
   - Already on `main`: stay.
   - Otherwise switch to `main` (use the worktree that already has it if one exists) and cherry-pick or rebase this work onto it.
4. Rebase onto `origin/main` if behind.
5. `git push origin main`.

Never force-push `main`. If rebase conflicts cannot be resolved, abort and report. If there is nothing to commit and `main` is already in sync with `origin/main`, say so and stop.

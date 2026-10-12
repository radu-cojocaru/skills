---
name: review-pr
description: Do a code review for the changes on the current branch or a given PR.
argument-hint: "[pr-number]"
disable-model-invocation: true
---

If a number was given, assume it's the id of a GitHub PR. Do a code review for that PR and post inline comments for any findings. Don't post a summary comment on the PR - the inline ones are enough.

If no number was given, do a code review for the changes on the current branch.

For each finding, include its importance as P1, P2 or P3.

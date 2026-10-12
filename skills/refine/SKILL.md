---
name: refine
description: Refine a GitHub issue. This skill should be triggered when the user wants to refine a GitHub issue.
disable-model-invocation: true
---

A GitHub issue ID is usually given when this skill is invoked. If no ID is given, fetch the first 5 open issues with the "draft" label (`gh issue list --label draft --state open --limit 5`) and ask the user which one they want to refine.

Read the issue and look at the codebase to form an understanding of the task. Then use the `/grill-me` skill to refine the ticket and prepare an implementation plan.

Write the refined description and the implementation plan back into the issue body with `gh issue edit <id> --body-file <file>`. The issue is the single place the plan lives. Only if the plan is too large for a readable issue, save it as a `.md` file in the relevant `docs/` folder and link to it from the issue.

If the ticket needs anything once it is live — a backfill, a check, a config
apply, or any other follow-up — add an `## After merge` section to the ticket:
one line per step, what it does, and who runs it, `agent` or `human`. The
step can use a command the ticket itself will add.

Settle who runs each step while grilling. Recommend `human` for any step that
moves money, contacts anyone outside the team, raises spend, or cannot be
undone from a backup.

The issue description must be detailed enough that an AI agent can implement the ticket autonomously.

Once we are done, add the "agent:ready" label and remove the "draft" label:
`gh issue edit <id> --add-label "agent:ready" --remove-label draft`

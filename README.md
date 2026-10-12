# skills

Agent skills, shared across projects. Each skill is a `<name>/SKILL.md` folder, which is what `npx skills` discovers. The folder says which agents a skill is for:

- `skills/` — generic, for every agent.
- `claude/skills/` — Claude Code only; they rely on `claude --bg`, `claude agents` and `~/.claude`.

A root install finds only `skills/`, so the Claude-only ones go in with a second command pointed at their folder:

```bash
npx skills add radu-cojocaru/skills -g -a claude-code -a codex -a grok -y
npx skills add https://github.com/radu-cojocaru/skills/tree/main/claude -g -a claude-code -y
```

`-g` puts them in the home directory, so every project on that machine sees them. Drop `-g` to install into the current repo instead.

Update a machine that already has them:

```bash
npx skills update -g -y
```

## Skills

- `audit-markdowns` — check project markdown against the code
- `cleanup-branches` — delete local branches whose PRs were squash-merged
- `draft` — file a GitHub issue labeled `draft`
- `fix-pr` — address review comments, failing checks, and conflicts on one PR
- `grill-me` — stress-test a plan one decision frontier at a time, from [mattpocock/skills](https://github.com/mattpocock/skills)
- `herdr` — control the Herdr terminal multiplexer, from [herdr.dev](https://herdr.dev/)
- `implement` — implement one `agent:ready` GitHub issue and open a PR
- `on-track` — end-of-day check of what landed on `main`
- `refine` — refine a draft issue with `/grill-me`, then mark it `agent:ready`
- `refine-fast` — refine a draft issue, deciding reversible calls without asking
- `review-pr` — review the current branch or a pull request
- `to-main` — commit the current work and push it to `main`

## Claude Code skills

All five are user-invoked only (`disable-model-invocation`). They read the project's `CLAUDE.md` for its **Shipping** section (backups, live and healthy checks after a merge) and **Ship groups** section (which directories may ship in parallel).

- `ship` — launch a background agent that ships one ready issue
- `ship-bg` — the background loop: implement, review, fix, open the PR, merge when the gates hold, run the after-merge steps
- `ship-fleet` — dispatch several ready issues at once, one per non-overlapping group
- `ship-status` — one table of running ship agents, claimed tickets and open PRs
- `ship-cleanup` — remove the worktrees, branches, refs and job records finished runs leave behind

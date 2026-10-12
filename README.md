# skills

Generic agent skills, shared across projects. Each skill is a `skills/<name>/SKILL.md` folder, which is what `npx skills` discovers.

Install every skill for the agents on this machine:

```bash
npx skills add radu-cojocaru/skills -g -a claude-code -a codex -a grok -y
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
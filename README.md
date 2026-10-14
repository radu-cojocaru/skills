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

## Workflow

How a piece of work goes from an idea to `main`. Every step is a GitHub issue changing labels: `draft` → `agent:ready` → `agent:working` → `agent:done` → closed by the merged PR.

```
/draft  →  /refine-fast  (or /refine)  →  /ship  (or /ship-fleet)
 draft        agent:ready                  merged, deployed, checked
```

### 1. Draft — capture it

`/draft <text>` files the issue. Most drafts come at the end of a conversation that dug into something (a bug report, a metric, a log), so the text can lean on it: `/draft a ticket for the code changes needed` or `/draft it` turns what was just found into the issue. A one-line idea works too: `/draft remove the daily pushover notification`. The skill shows the title and body before posting, and suggests one or two things worth adding.

A draft is a note, not a spec. Nothing picks it up until it is refined.

### 2. Refine — make it implementable

Start a fresh session (`/clear`) on a strong model, then pick one:

- **`/refine-fast <id>`** — the default. The agent reads the code, decides everything reversible on its own, and asks at most one round of questions: the ones that cost a rewrite, a bill or a migration to undo, plus anything a user of the product sees.
- **`/refine <id>`** — when the ticket is mostly product decisions: pricing, what a paid action unlocks, privacy, a new service or vendor, a public contract. It grills every decision with `/grill-me`.

Steer it in the arguments instead of waiting to be asked:

```
/refine-fast 959 - store the price paid, but leave it out of the email. no backfill
/refine 948 I'm inclined to keep them public for about a day
```

Either way the plan ends up in the issue body, including an `## After merge` section that says who runs each post-deploy step, `agent` or `human`. Anything that moves money, contacts someone outside the team, raises spend or cannot be undone from a backup is `human`. The issue then gets `agent:ready`.

### 3. Ship — implement, review, merge

`/ship <id> [sonnet|opus|fable]` launches a background agent and returns straight away. Sonnet is the default. Use `opus` for anything spanning several apps, touching money, or hard to get right, and `fable` for the hardest ones. The agent implements on its own worktree, gets a fresh Opus review, fixes the findings, opens the PR, merges once CI is green and the gates hold, then runs the `agent` after-merge steps. Any `human` steps land in a hand-off issue.

`/ship-fleet` does the same for every `agent:ready` issue at once, one per non-overlapping ship group, at most four in flight. A note in the arguments overrides the grouping: `/ship-fleet the 2 ready tickets are both dashboard but touch different areas, start them in parallel`.

### Running it day to day

- **Two tabs.** One long-lived tab only ships and checks status. Refining happens in a fresh tab per ticket. Once a ticket is `agent:ready`, `/ship` it from the ship tab and refine the next one while it builds.
- **`/ship-status`** shows what is running, what is waiting on a merge, and what needs you. Follow-up asks go in its arguments: `/ship-status and pull main`.
- **Hold a merge** by adding the `no-automerge` label to the issue or PR. The agent leaves the PR open and says why.
- **When a run stops short** (red CI after its one fix, a review comment it rejected), finish it with `/fix-pr <pr>`.
- **`/ship-cleanup`** removes the worktrees, branches and job records finished runs leave behind.

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

All but `ship-fleet` are user-invoked only (`disable-model-invocation`). They read the project's `CLAUDE.md` for its **Shipping** section (backups, live and healthy checks after a merge) and **Ship groups** section (which directories may ship in parallel).

- `ship` — launch a background agent that ships one ready issue
- `ship-bg` — the background loop: implement, review, fix, open the PR, merge when the gates hold, run the after-merge steps
- `ship-fleet` — dispatch several ready issues at once, one per non-overlapping group
- `ship-status` — one table of running ship agents, claimed tickets and open PRs
- `ship-cleanup` — remove the worktrees, branches, refs and job records finished runs leave behind

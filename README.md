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

How a piece of work goes from an idea to `main`. Every step is a GitHub issue changing labels: `draft` → `agent:ready` → `agent:working` → `agent:done` → closed by the merged PR. A run that aborts after claiming its ticket leaves it on `agent:failed` with a comment saying why; relabel it `agent:ready` to retry. `/implement` uses `agent:implemented` instead of `agent:done`, as before.

Two optional labels pick the model: `model:opus` and `model:fable`. The factory reads them when it launches a ticket; without one it uses its default model. `/ship` ignores them and takes the model as an argument.

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

## Factory

A lightweight software factory for every private repo on the account. Every 5 minutes, cron on the devbox looks for `agent:ready` tickets and, for each repo with nothing in flight, launches one `/ship-bg` run on its oldest ready ticket. `/ship-bg` does the rest: build, review, PR, CI, merge, after-merge steps. A dashboard page on the tailnet shows what the factory is doing and has done. It is built for low volume: one ticket in flight per repo, no global cap, with the 5-hour and weekly usage limits as the only throttle.

The code is in `factory/`. It has no `SKILL.md`, so `npx skills` ignores it.

### Install

```bash
factory/install.sh
```

It creates `~/skills-factory`, a detached worktree of this repo on `origin/main`, plus `factory/.local/` and `config.env` inside it, then prints the two crontab lines and the one-time sudo steps for the dashboard. It is idempotent and never edits the crontab or runs sudo: you add the lines yourself. Cron updates the worktree before every tick, so a merged change to the factory takes effect on the next tick.

Then, once per repo:

```bash
~/skills-factory/factory/setup-repo.sh <owner/repo>
```

It clones the repo to `$REPOS_DIR/<repo>` if needed, creates the labels the ship skills need, warns when the repo's `CLAUDE.md` has no **Shipping** or **Ship groups** section, and checks the clone is trusted by Claude Code. A fresh clone is not; the script prints the `claude` command to run once to accept the trust prompt. It writes `~/.claude.json` never. The tick only launches in repos the script has marked set up.

`factory/ship-tick.sh --dry-run` runs every check the tick makes, prints per repo what it would launch and the usage gate's state, and launches and records nothing.

Run the checks with `factory/test.sh`.

### Config and state

`~/skills-factory/factory/.local/config.env` (mode 600), plain `KEY=value`. Every key is optional. `config.example.env` documents them:

| Key | Default | Meaning |
| - | - | - |
| `OWNER` | the logged-in `gh` user | whose private repos to scan |
| `SESSION_MAX_PCT` | `70` | skip launches at or above this 5-hour usage |
| `WEEKLY_MAX_PCT` | `90` | skip launches at or above this weekly usage |
| `DEFAULT_MODEL` | `sonnet` | model when the ticket has no `model:*` label |
| `REPOS_DIR` | `$HOME` | where repo clones live (`$REPOS_DIR/<repo>`) |
| `EXCLUDE_REPOS` | empty | space-separated repo names to skip |
| `WWW_DIR` | `/srv/ship-factory/www` | where the dashboard page is written |
| `PUSHOVER_TOKEN`, `PUSHOVER_USER` | empty | alerts; without them, log only |
| `STALE_MINUTES` | `60` | a `working` session whose transcript has not changed for this long counts as dead |
| `NODE_BIN_DIR` | fnm's `default` alias | prepended to `PATH` so cron finds `node` |

State lives in `~/skills-factory/factory/.local/state/`: the lock, setup markers, launch records, the usage gate's reset time, the event log and the last-tick heartbeat.

Two warnings:

- `git clean -x` in `~/skills-factory`, or removing and re-adding the worktree, wipes `factory/.local/`, config and state alike. Checkouts leave it alone.
- The factory updates itself from `origin/main`, but the skills it runs come from `~/.claude/skills` and change only with `npx skills update -g -y`. A change that touches both the factory and a skill needs one manual update after merging.

### How it works

Every 5 minutes the tick takes a lock, then:

1. **Records.** One search across the owner's private repos for open tickets on `agent:working`, `agent:review`, `agent:done` or `agent:failed`, plus each repo's open PRs. It compares them with the last snapshot and appends one event per change (claimed, review, PR opened, held, merged, closed, failed) to the event log. This is the dashboard's only data source; `/ship-bg` knows nothing about it.
2. **Checks the runs.** A ticket on `agent:working` or `agent:review` whose session is not live (not `working` or `blocked`, or its transcript untouched for `STALE_MINUTES`) is resumed once with `claude --bg --resume`. Stale again after that, it is relabelled `agent:failed` with a comment. A ticket with no matching session at all is flagged, never relabelled. A launch whose `/ship-bg` ended without claiming its ticket is relabelled `agent:failed` too, so the factory does not relaunch it every tick.
3. **Finds work.** Ready tickets grouped by repo. A repo launches only when `setup-repo.sh` has marked it set up, nothing is in flight there (asked of the repo directly, since search trails label changes), and no launch from the last 10 minutes is still starting.
4. **Checks usage.** `claude -p /usage` costs nothing and reports the 5-hour and weekly limits. At or above `SESSION_MAX_PCT` or `WEEKLY_MAX_PCT` the gate closes until the reset time and `/usage` is not called again before then. A per-model weekly limit skips only that model's tickets.
5. **Launches** the oldest ready ticket in each free repo from its clone, with the same flags `/ship` uses, on the model the `model:*` label names or `DEFAULT_MODEL`.
6. **Renders the dashboard** and writes the last-tick heartbeat.

Idle ticks, with nothing ready and nothing changed, exit in about a second without starting Claude. Pushover alerts go out once each for a failed ticket, a held PR, a ticket with no agent, a repo that needs setup, and a tick that fails. A ticket relabelled `agent:ready` and run again can alert once more.

### Day to day

- **Pause:** comment out the two crontab lines. Running agents are not affected.
- **Logs:** `journalctl -t ship-tick`.
- **Cleanup:** the daily crontab line runs `ship-tick.sh --cleanup`. It waits for the tick's lock, runs `ship-cleanup.mjs --apply` in every set-up repo with nothing in flight and no live session, drops events older than 90 days and the records of closed tickets, and re-renders the dashboard. Before any repo deletes anything, it stops the Claude daemon once, but only when some repo will remove a job record and no agent anywhere is live. Job records deleted while the daemon runs come back, and stopping it ends every background agent. `--cleanup --dry-run` shows what it would do.
- **Retry a failed ticket:** fix the cause, then relabel it `agent:ready`.

### Dashboard

`https://devbox.tail28d8ef.ts.net:9443`, on the tailnet only. One static page, re-rendered at the end of every tick and reloading itself every 60 seconds: what is running now, what needs you (failed tickets, held PRs, tickets with no agent, repos that need setup), and the last 50 runs. The tick writes it to `WWW_DIR` (`/srv/ship-factory/www`), outside the home directory because Caddy runs as its own user. Only the rendered page leaves the home directory.

The devbox's Caddy already binds to the tailnet address with certificates from Tailscale, so the dashboard is one more site block, `factory/ship-factory.caddy`, on port 9443. The host's main Caddyfile belongs to another project and needs one line, `import /etc/caddy/conf.d/*.caddy`. `install.sh` prints these one-time sudo steps rather than running them:

```bash
sudo mkdir -p /srv/ship-factory/www && sudo chown $USER /srv/ship-factory/www && sudo chmod 755 /srv/ship-factory/www
sudo mkdir -p /etc/caddy/conf.d && sudo cp ~/skills-factory/factory/ship-factory.caddy /etc/caddy/conf.d/
# add to /etc/caddy/Caddyfile:  import /etc/caddy/conf.d/*.caddy
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

Without the directory the tick logs that the page was not rendered and carries on.

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

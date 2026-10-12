---
name: audit-markdowns
description: Audit project markdown against the codebase and optionally apply the verdicts.
disable-model-invocation: true
---

Audit every markdown file in this repo. Report what is still true. Apply edits only when the user asks.

## Inventory

Find files with something like:

```bash
find . -name '*.md' \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -not -path '*/dist/*' \
  -not -path '*/out/*' \
  -not -path '*/playwright-report/*' \
  -not -path '*/test-results/*' \
  | sort
```

Exclude generated dumps (`playwright-report/`, `test-results/`).

Include root `docs/`, app-local docs, READMEs, `AGENTS.md` / `CLAUDE.md`, runbooks, spikes, and agent skills. For process skills, only flag outdated **project** facts (stack, paths, commands), not the process itself.

If `CLAUDE.md` is a symlink to `AGENTS.md`, edit one file.

## Verify

Do not trust a markdown claim because it is well written. Check it against the code that would have to be true for it:

- `package.json` scripts, deps, package names
- `wrangler.jsonc`, `next.config.ts`, `docker-compose.yml`, GitHub workflows
- schema / migrations / exported symbols / HTTP routes
- Admin nav and operator controls (does the UI actually expose that button?)
- Deploy scripts (what containers rebuild? do migrations run at boot?)

Cross-check the same fact across files. Contradictions (README vs `AGENTS.md` vs RUNBOOK vs code) are findings.

## Rate each file

Use exactly these verdicts:

| Verdict                   | Meaning                                           |
| ------------------------- | ------------------------------------------------- |
| VALID                     | Matches the code. Leave it.                       |
| MOSTLY VALID              | A few wrong sentences.                            |
| PARTIALLY STALE           | Mix of current and retired facts.                 |
| STALE                     | Would mislead if followed.                        |
| HISTORICAL (still useful) | Accurate as a record; keep with a banner.         |
| HISTORICAL (misleading)   | Banner is not enough; the body is a dead runbook. |

Call out **highest-risk** files first: operator docs that would send someone down a retired path (wrong migrate command, retired deploy stack, “not built yet” for shipped code).

Also list:

- Missing READMEs for first-class apps/packages
- Omissions in `AGENTS.md` (apps, workers, entry points)

## Report, then stop

Lead with the highest-risk table, then a per-file table. Quote the stale sentence and the code that disproves it. Do not edit until asked.

## Apply (only if asked)

- Living docs: rewrite to current truth. Product claims must match landing-page / schema / env, not a wishlist.
- `HISTORICAL (still useful)`: add a banner that points at the current runbook; keep the body.
- `HISTORICAL (misleading)`: replace the body with a short pointer, or rewrite the operator flow. Do not leave a superseded banner above a full retired procedure.
- Ask before deleting planning leftovers (wishlists, vendor comparisons, scratch notes) mixed into a README.
- Do not delete historical records unless the user says to.
- Do not invent packages, scripts, or features to make a sentence true.

After applying, the report's stale sentences should be gone from living docs.

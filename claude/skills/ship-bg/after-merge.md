# After merge: the gates and the steps

Read the **Shipping** section of `CLAUDE.md` first. If there is none, merge as
usual and hand every after-merge step to a human.

## Who runs what

The ticket's `## After merge` section says, step by step, whether the agent
or a human runs it. That was decided in refinement; do not reopen it.

- An `agent` step runs as below.
- A `human` step goes into the hand-off issue.
- A step the ticket does not list — one you found while implementing — is
  `human`. Refinement never agreed to it.
- A ticket with no `## After merge` section has no steps.

## The commands

Once the code is written, put the exact command for every `agent` step in the
PR body under `## After merge`. They can call scripts this PR adds. For a step
that writes, give:

- `dry_run`: writes nothing, prints how many rows the apply would change. For
  hand-written SQL, a `select count(*)` with the same `WHERE`; for a config
  script, its `--dry-run`.
- `apply`: the write, in one transaction where it can be.
- `max_rows`: the most the dry run may report, justified from a read-only
  query of the real data.
- `verify` and `expect`: a read-only check and its output once done.

The reviewer reviews these commands with the rest of the diff.

## The merge gates

Merge when all of these hold. Otherwise leave the PR open, comment which gate
failed, and hand every step to a human.

- **No `no-automerge` label** on the issue or the PR.
- **No P1 finding marked "Rejected".**
- **CI green on the commit that lands.** Rebase onto `origin/main` right
  before merging; if that moved the branch, push and watch CI again. "No
  checks reported" twice, a minute apart, passes: which paths run CI is the
  repo's decision, made in its workflow triggers, and branch protection still
  blocks the merge if it requires a check. Pending after 30 minutes fails.

**Pre-merge backup.** A migration runs the moment the deploy boots, so back up
first: the whole database where Shipping says to, otherwise the tables a
destructive migration (drop, delete, rewrite) touches. A failed backup fails
the gate.

Merge with `gh pr merge <pr> --squash --delete-branch`. If it fails, comment
what `gh` said and stop. Never retry blind.

## Confirm the deploy

Steps run against the new code or not at all. For each target a step uses:

1. Find the deploy run for the merge commit: `gh run list --workflow <file>
--commit <sha>`; retry for two minutes if empty. `gh run watch <id>
--exit-status`, 20-minute ceiling.
2. A cancelled or missing run passes only if step 3 does — a later push may
   have deployed this commit.
3. The host is live and healthy on the merge commit, as Shipping says.

A target that did not confirm turns its steps `human`.

## Run the steps

One at a time, in order. Stop at the first step that does not go as planned;
it and every step after it become `human`.

For a step that writes:

1. **Back up**, as Shipping says for that target. Check the copy is readable
   and there is room for it; keep the newest five; note the path and UTC time.
2. **Dry run.** Zero means nothing to do — go to verify. Over `max_rows`, or
   a config diff that is not exactly the ticket's change, is a stop.
3. **Apply** once, 30-minute timeout. Non-zero exit is a stop; never re-run
   it. Its count must match the dry run's within 5%.
4. **Verify.** The dry run again should show nothing left; `verify` must
   print `expect`; the target must still be healthy.

A read-only step is just its `verify`.

**Never restore a backup yourself** — it loses every write since. Put the
backup path and restore commands in the hand-off.

**Never print secrets.** Read a key inside the command that uses it.

## Hand off and record

Every `human` step, and everything a stop skipped, goes in **one** issue
labelled `human`, titled `Manual step for #<issue-id>: <summary>`: what
merged, each step and why it is a human's, and after a stop what ran, its
output and the backup path. Link it from the PR.

Post one `## After merge` comment on the PR whatever happened: the merge
commit, each step's outcome, the counts, backup paths, and the last 20 lines
of each command's output.

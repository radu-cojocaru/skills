---
name: ship
description: "Ship a ready issue: launch a background agent that implements it, gets the branch reviewed by a fresh agent, applies the findings, then opens the PR. Optionally takes a model alias to run on."
argument-hint: <issue-id> [sonnet|opus|fable]
disable-model-invocation: true
---

Ship one ticket: launch a background agent that runs the whole loop —
implement, review the branch, fix, open the PR, watch CI, merge when the
gates in `ship-bg/after-merge.md` hold, run the after-merge steps the ticket gives the agent — and
report its id.

The loop itself lives in `/ship-bg`. This skill only starts it, and that is
all it does. It is a separate session because the loop takes far too long to
run inside a conversation the user is waiting on.

## Read the arguments

`/ship <issue-id> [model]` — the model is optional and defaults to `sonnet`.

Both orders work, because the two are never confusable: the **all-digits**
token is the issue id, the other is the model.

```
/ship 480              → issue 480 on sonnet
/ship 480 opus         → issue 480 on opus
/ship fable 480        → issue 480 on fable
```

The model must be one of `sonnet`, `opus` or `fable` — the CLI's own
aliases, each resolving to the latest model in that class. **If a second
argument is given and it is not one of those three, stop and say so.** Do not
guess and do not fall back to the default silently: launching a long
background run on the wrong model is far worse than one more exchange, and an
unrecognised `--model` value makes the CLI fail in a way that reads like a
harness bug rather than a typo.

Only the run model changes. `/ship-bg` spawns its review subagent with an
explicit `model: "opus"`, so the review is always on Opus whatever is chosen
here.

## Launch it

First build the agent name from the issue id plus the first two words of its
title, so a list of running agents reads as tickets rather than numbers:

```
slug=$(gh issue view <issue-id> --json title -q .title \
  | cut -d' ' -f1,2 \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' \
  | cut -c1-24)
name="ship-<issue-id>${slug:+-$slug}"
```

`#330 Switch on-demand scans to monthly scans` becomes
`ship-330-switch-on-demand`; `#346 Schedule monthly scans for subdomains…`
becomes `ship-346-schedule-monthly`.

The `${slug:+-$slug}` is the fallback that matters: if `gh` fails or the title
is empty, `slug` is empty and the name degrades to plain `ship-<issue-id>`
rather than a trailing hyphen. Never block the launch on a cosmetic name.

`cut -c1-24` caps the slug — a title opening with two long words would
otherwise produce a name too unwieldy to type into `claude attach`.

**Never write a positional shell reference — a dollar sign followed by a digit
— anywhere in this file.** The harness substitutes slash-command positional
arguments into the skill body before it reaches the model. The first two words
of the title used to be taken with `awk` and two such references; the moment
this skill grew a second argument, that line arrived with the model alias
pasted into it and would have produced a broken name or a shell error.
`cut -d' ' -f1,2` does the same job with no dollar sign in it. Named shell
variables (`$slug`, `$name`) are safe — only the numbered ones are rewritten.

The model deliberately does **not** go in the name. Names read as tickets, and
`claude agents` already reports the model separately.

Then launch, substituting the chosen model for `<model>`:

```
claude --bg --name "$name" --model <model> \
  --permission-mode bypassPermissions --remote-control "$name" \
  "/ship-bg <issue-id>"
```

Every flag there is load-bearing:

- `--bg` and not `--bg -p`. Those two conflict, and the job would be
  unattachable.
- `--permission-mode bypassPermissions`, or the run stops at its first file
  edit waiting for an approval nobody will give. A blocked background agent
  waits forever.
- `--model <model>`, **always passed, even for the default**. The session model
  wins over the skill's frontmatter, so without the flag the whole run
  inherits whatever model launched _this_ conversation — which is how a
  `/ship` typed from an Opus session used to become an Opus run by accident.
  Passing it explicitly is what makes the default a decision rather than a
  side effect.
- `--name "$name"`, so `claude agents` and `/ship-status` show which ticket the
  agent is on — and now which ticket that is, without cross-referencing a
  number against GitHub.
- `--remote-control "$name"`, so the run is reachable from the user's phone or
  another machine, under the same name. Give it the same string as `--name` —
  two names for one agent is worse than none.

The name is cosmetic only. `/ship-cleanup` matches worktrees and branches, not
agent names, so it keeps working whatever this resolves to.

Then stop. Report the id **and the model it is running on**, and let the run
go — do not poll it, and do not schedule a check. The user will ask when they
want to know.

# claude-mods

Mods for Claude Code: plugins of function hooks that change its interface. Each mod is a folder here.

| Mod | What it does |
| --- | --- |
| [skill-view](skill-view) | A pane listing the skills Claude invoked on its own, grouped by turn, updated live |

## Install

The repository root holds the plugin marketplace. From a terminal session:

```
/plugin install skill-view --marketplace radu-cojocaru/skills
```

From a shell: `claude plugin install skill-view --marketplace radu-cojocaru/skills`.

To try a mod for one session without installing: `claude --plugin-dir /path/to/skills/claude-mods/skill-view`.

## skill-view

Opens a pane when the session starts; `/skill-view` reopens it. Each row is a skill Claude called through its Skill tool, under the turn it happened in: `…` running, `✓` done, `✗` failed or denied. Calls from subagents are marked. Skills you type yourself as `/name` are not listed, since you invoked those.

Requires a Claude Code build with mods (the `claude-code` hooks API). Check or test it with `claude plugin validate skill-view` and `claude plugin test skill-view`.

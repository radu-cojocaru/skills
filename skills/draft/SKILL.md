---
name: draft
description: Capture given text as a GitHub issue labeled draft, generating a title from the text. Use when the user runs /draft or asks to file a draft issue.
---

Take the given text and file it as a GitHub issue with the `draft` label. Do not add `agent:ready`.

If no text was given, ask for it and stop.

Suggest 1–2 additional things that could be included in the draft.

Generate a short, specific title from the text. Do not prefix it with "Draft". Do not use the full text as the title.

Show the user the title & body of the issue before posting it.

Once user confirms, create the issue and reply with the issue URL.

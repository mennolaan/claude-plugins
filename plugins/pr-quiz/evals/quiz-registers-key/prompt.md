---
description: The quiz skill reads the diff and registers a valid 10-question key. Asking is not possible in a non-interactive run, so the case stops there.
max_turns: 25
timeout_seconds: 600
allowed_tools: [Bash, Read, Glob, Grep, Skill]
---

Quiz me on the changes in this branch before I open a pull request.

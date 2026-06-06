---
name: sqlite-setup
description: Set up SQLite as the waggle provider. Trigger phrases - "setup sqlite", "configure sqlite for waggle".
user-invocable: true
---

# SQLite Provider Setup

This skill sets up SQLite as the data provider for waggle.

See `references/setup-guide.md` for detailed setup steps.

## Output Discipline

This skill runs as a multi-step pipeline, but the user only needs its outcomes. Do not
narrate step transitions ("Now I'll...", "X done, next Y") and do not relay protocol
internals — provider detection, config/schema checks, cache state, validation plumbing,
view-server pushes. Surfacing them buries what actually matters.

Emit user-facing text only when it changes something for the user:

- a prompt or confirmation that needs their input
- an error or a warning
- an intermediate result that changes the outcome (e.g., a non-PASS quality verdict and
  the gaps behind it — it explains why a task lands at a different status than expected)
- the final result summary

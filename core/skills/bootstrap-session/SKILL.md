---
name: bootstrap-session
description: >
  Shared session bootstrap — detects provider, resolves identity, and
  populates headless_config. Called by all user-invocable skills at startup.
user-invocable: false
---

# Waggle — Session Bootstrap

One-time session setup that all user-invocable skills run before their main logic.
**Skip entirely if `active_provider` and `current_user` are already set in this conversation.**

**Silent operation:** This skill runs as an internal step of an invoking skill. Return
results to the invoking flow without user-facing narration — the caller owns all user
communication. Only errors, warnings, and prompts required to proceed may surface directly.

## Step 1: Provider Detection

Invoke the `detecting-provider` skill.

This produces:
- `active_provider` — the detected provider name (notion, sqlite, turso)
- `execution_environment` — cli, claude-desktop, or cowork
- `headless_config` — database IDs and constants from the provider

## Step 2: Identity Resolution

Invoke the `resolving-identity` skill.

This produces:
- `current_user` — `{ id, name, email }` of the authenticated user
- `current_team` — the user's active team (if teams are configured)

Note: `org_members` is resolved on demand (not by default). Skills that need member lookup should explicitly invoke the `looking-up-members` skill when they need it.

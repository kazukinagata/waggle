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

## Step 1: Provider Detection

Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions.

This produces:
- `active_provider` — the detected provider name (notion, sqlite, turso)
- `execution_environment` — cli, claude-desktop, or cowork
- `headless_config` — database IDs and constants from the provider

## Step 2: Identity Resolution

Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` and follow its instructions.

This produces:
- `current_user` — `{ id, name, email }` of the authenticated user
- `current_team` — the user's active team (if teams are configured)

Note: `org_members` is resolved on demand (not by default). Skills that need member lookup should explicitly request it via resolving-identity Step 2 or by loading `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md`.

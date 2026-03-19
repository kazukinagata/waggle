---
name: resolving-identity
description: Internal shared skill to resolve current user identity and org members. Not intended for direct user invocation.
user-invocable: false
---

# Waggle — Identity Resolve

Resolve the current user's identity from the active provider.
**Skip if `current_user` is already set in this conversation.**

## Prerequisites

`active_provider` must already be determined (caller must run detecting-provider first).
If `active_provider` is not set, stop and return an error to the caller.

## Step 1: Resolve Current User

If `current_user` is already set in this session, skip to Step 2.

Load `${CLAUDE_PLUGIN_ROOT}/skills/providers/{active_provider}/SKILL.md` and follow the
**Identity: Resolve Current User** section.

Result: set session variable `current_user: { id, name, email }`.

- If the provider does not support user identity, set `current_user: { id: "local", name: $USER env var or "local", email: null }`.
- Always produce a `current_user` value — never fail the caller due to identity resolution.

## Step 1b: Resolve Team Membership

**Skip if `current_user.teams` is already set in this session.**

If `teamsDatabaseId` exists in `headless_config`:

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/providers/{active_provider}/SKILL.md` and follow the
   **Identity: Resolve Team Membership** section.
2. Result: set `current_user.teams: [{ id, name, members: [{ id, name }] }]` and `current_team`.
   - 1 team → automatically set `current_team`.
   - 2+ teams → AskUserQuestion to select.
   - 0 teams → `current_team: null`.

If `teamsDatabaseId` is not in config, skip this step (`current_team: null`).

## Step 2: Resolve Org Members (on demand)

Only execute if the caller explicitly requests member lookup (i.e., `org_members` is needed).
**Skip if `org_members` is already set in this session.**

Load `${CLAUDE_PLUGIN_ROOT}/skills/providers/{active_provider}/SKILL.md` and follow the
**Identity: List Org Members** section.

Result: set session variable `org_members: OrgMember[]` where each member has `{ id, name, email }`.

- If the provider does not support member listing, set `org_members: []`.

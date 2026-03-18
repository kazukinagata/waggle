---
name: looking-up-members
description: Internal shared skill to resolve member names or email addresses to provider user IDs. Not intended for direct user invocation.
user-invocable: false
---

# Agentic Tasks — Member Lookup

Resolve a member name or email to a provider user ID.
Uses the `org_members` cache populated by `resolving-identity`.

## Prerequisites

- `active_provider` must already be determined.
- `org_members` must already be populated (caller must trigger resolving-identity Step 2 first).

## Resolution Algorithm

Given a query string (name or email fragment):

1. **Exact email match**: compare query (case-insensitive) against `org_members[*].email`. Return immediately if exactly one match.
2. **Exact name match**: compare query (case-insensitive) against `org_members[*].name`. Return immediately if exactly one match.
3. **Partial name match**: check if any `name` contains the query string (case-insensitive). Collect all matches.
4. **Return results**:
   - 0 matches → return empty array `[]`. Do not error — let the caller handle the missing case.
   - 1 match → return `[{ id, name, email }]`.
   - 2–5 matches → return the array. Caller should present candidates and ask the user to confirm.
   - 6+ matches → return the first 5 with a note that the query is too broad. Caller should ask for a more specific name.

## TeamsDB Fallback

If `org_members` is empty (provider does not support member listing), fall back to TeamsDB:

1. If `teamsDatabaseId` is not in `headless_config`, return empty array `[]` (no fallback available).
2. Fetch the Teams database using `teamsDatabaseId` from config.
3. Collect all unique persons from the `Members` (people-type) field across all teams.
4. Use this as the search corpus. Cache result in `org_members` for the session.
5. Apply the same Resolution Algorithm above.

## Caller Responsibility

The caller (delegating-tasks, ingesting-messages, managing-tasks) must:
- Run detecting-provider + resolving-identity (org_members) before calling this skill.
- Handle the returned candidates with AskUserQuestion if multiple matches exist.
- Not call this skill for the current user — use `current_user.id` directly from resolving-identity.

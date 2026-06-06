---
name: troubleshooting
description: >
  Diagnoses common Waggle issues: schema mismatches, missing fields,
  stale views, broken ingestion, and version incompatibilities.
  Use when something isn't working as expected — errors, missing data,
  unexpected behavior, or after upgrading Waggle.
  Triggers on: "troubleshoot", "debug", "not working", "error",
  "something is wrong", "broken", "help me fix".
user-invocable: true
---

# Waggle — Troubleshooting

Diagnoses common issues and guides the user through resolution.

## Output Discipline

This skill runs as a multi-step pipeline, but the user only needs its outcomes. Do not
narrate step transitions ("Now I'll...", "X done, next Y") and do not relay protocol
internals — provider detection, config/schema checks, cache state, validation plumbing,
view-server pushes. Surfacing them buries what actually matters.

Emit user-facing text only when it changes something for the user:

- a prompt or confirmation that needs their input
- an error or a warning
- an intermediate result that changes the recommended resolution path
- the final result summary

Diagnostic findings (provider, schema, config state) are this skill's outcome — report
them in the diagnosis, not as step-by-step narration while checking.

## Step 1: Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider and current user.
Skip if `active_provider` and `current_user` are already set in this conversation.

## Step 2: Changelog Reference

Before diagnosing, check the changelog for recent breaking changes or known issues:

Read `${CLAUDE_PLUGIN_ROOT}/CHANGELOG.md` and identify:
- Breaking changes in the current version that may require migration
- New fields or renamed fields that may not exist in the user's database yet

Present a brief version summary:
```
Current Waggle version: {version from .claude-plugin/plugin.json}
Latest changelog entry: v{version} — {date}
```

## Step 3: Schema Validation

Fetch the user's Tasks database schema using `notion-fetch` with `tasksDatabaseId` and compare against the expected schema in the active provider's SKILL.md.

Check for:
1. **Missing Core fields** — fields that should exist but don't
2. **Missing Extended fields** — optional fields that skills expect
3. **Renamed fields** — e.g., `Assignees` (old) vs `Assignee` (new)
4. **Status enum mismatches** — missing options (e.g., Cancelled)
5. **Executor enum mismatches** — unexpected or missing options

For each mismatch, propose the appropriate auto-repair DDL or manual fix.

## Step 4: Common Issues Checklist

Run through these checks based on the user's reported symptom:

### Views not updating
1. Check view server is running: `curl -s http://localhost:3456/api/health`
2. If running, the issue is likely stale cached data — push fresh data via the provider's "Pushing Data to View Server" flow
3. If not running, start it via the `viewing-tasks` skill

### Ingesting not picking up messages
1. Verify messaging MCP tools are available (Slack/Teams/Discord)
2. Check Intake Log for duplicate entries
3. Check Active Threads DB for stale threads (Status=active but Last Checked > 7 days ago)
4. Verify lookback period is sufficient for the user's use case

### Tasks not appearing for assignee
1. Verify `Assignee` field is set (not empty) on the task
2. Check if the field name matches the provider's expected name (`Assignee` vs `Assignees`)
3. Verify the user ID in `Assignee` matches `current_user.id`

### Validation errors on status transition
1. Invoke the `validating-fields` skill with the task data and target status to get the full list of errors and warnings
2. Check which fields are missing or invalid
3. Guide the user to fill in required fields before retrying

### Post-upgrade issues
1. Read `${CLAUDE_PLUGIN_ROOT}/CHANGELOG.md` for the version the user upgraded to
2. Check if migration steps were completed (e.g., column renames)
3. Verify schema matches the new version's expectations

## Step 5: Resolution

For each identified issue:
1. Explain what's wrong and why
2. Propose a fix (auto-repair DDL, manual Notion edit, or config change)
3. Execute the fix with user confirmation
4. Verify the fix resolved the issue

## Step 6: Summary

Report:
```
[Troubleshooting Complete]
Issues found: N
  - {issue 1}: {status: fixed / needs manual action / not resolved}
  - {issue 2}: ...
Changelog reference: CHANGELOG.md (v{version})
```

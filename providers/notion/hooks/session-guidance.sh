#!/usr/bin/env bash
# session-guidance.sh — SessionStart hook that injects standing Waggle task-protocol
# guidance into the session as additionalContext.
#
# Invoked by providers/notion/hooks/hooks.json on SessionStart (startup|compact|resume).
# Reads the hook payload on stdin and emits a SessionStart decision on stdout:
#   {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: "..."}}
#
# The matcher includes `compact` so the guidance is re-injected after context
# compaction (where the original system reminder would otherwise be lost).
#
# This replaced the former PreToolUse hard-deny guard (check-task-write.sh). The guard
# could not tell a Waggle Task page from an unrelated Notion DB without a fetch, so it
# false-positive-denied unrelated writes. Guidance is advisory and never blocks a write,
# so it carries zero false-positive cost.
#
# Fail-open by design: any unexpected error emits `{}` (no context) and exits 0.

set -euo pipefail
fail(){ echo "{}"; exit 0; }
trap fail ERR

# The configured Waggle Tasks data source id, when available (env-injected on CLI/Desktop;
# typically absent on Cowork, where config lives in the system prompt). Named for clarity
# in the guidance text only — its absence does not change behavior.
# Strip to id-safe characters: shell does not re-evaluate metacharacters inside a variable's
# value, but stripping anything outside [A-Za-z0-9_-] is cheap defense-in-depth and keeps the
# guidance text clean if the env var is ever misconfigured.
DSID="${WAGGLE_NOTION_TASKS_DB_ID:-}"
DSID="${DSID//[^a-zA-Z0-9_-]/}"
if [ -n "$DSID" ]; then
  LOCATOR="the Waggle Tasks Notion database (data source id: $DSID)"
else
  LOCATOR="the Waggle Tasks Notion database"
fi

GUIDANCE="Waggle task protocol active. Waggle Task pages live in ${LOCATOR}. Do NOT create or modify Waggle Task pages by calling Notion MCP write tools directly (notion-create-pages / notion-update-page / notion-update-relation). Route every task create / update / status change / delegation / execution through the Waggle skills (managing-tasks, planning-tasks, executing-tasks, delegating-tasks, ingesting-messages, running-daily-tasks). Direct MCP writes bypass the AC/EP rubric, executor-field invariants, Acknowledged At auto-set, subtask cascading, and the Quality-Verdict gate. Reading via notion-fetch / notion-search is fine."

jq -n --arg e SessionStart --arg c "$GUIDANCE" \
  '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'

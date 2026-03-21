#!/usr/bin/env bash
# Query waggle SQLite database and output JSON.
#
# Usage: query-tasks.sh <db_path> [where_clause] [order_clause] [limit]
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Arguments:
#   db_path       — Path to SQLite database file
#   where_clause  — (optional) SQL WHERE clause without "WHERE" keyword
#   order_clause  — (optional) SQL ORDER BY clause without "ORDER BY" keyword
#   limit         — (optional) Max number of rows
#
# Output:
#   JSON object: {"results": [...tasks with blocked_by arrays...]}
#
# Examples:
#   query-tasks.sh ~/.waggle/tasks.db
#   query-tasks.sh ~/.waggle/tasks.db "status = 'Ready'"
#   query-tasks.sh ~/.waggle/tasks.db "status = 'Ready' AND executor = 'cli'" "priority ASC"

set -euo pipefail

DB_PATH="${1:?Usage: query-tasks.sh <db_path> [where_clause] [order_clause] [limit]}"
WHERE_CLAUSE="${2:-}"
ORDER_CLAUSE="${3:-}"
LIMIT="${4:-}"

if [ ! -f "$DB_PATH" ]; then
  echo "Error: Database file not found: $DB_PATH" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

# Build SQL query
SQL="SELECT t.*, GROUP_CONCAT(td.blocked_by_id) as blocked_by_ids FROM tasks t LEFT JOIN task_dependencies td ON t.id = td.task_id"

if [ -n "$WHERE_CLAUSE" ]; then
  SQL="$SQL WHERE $WHERE_CLAUSE"
fi

SQL="$SQL GROUP BY t.id"

if [ -n "$ORDER_CLAUSE" ]; then
  SQL="$SQL ORDER BY $ORDER_CLAUSE"
fi

if [ -n "$LIMIT" ]; then
  SQL="$SQL LIMIT $LIMIT"
fi

# Execute and output JSON
RAW=$(sqlite3 -json "$DB_PATH" "$SQL")
if [ -z "$RAW" ]; then
  echo '{"results": []}'
  exit 0
fi
echo "$RAW" | jq '{
  results: [.[] | {
    id: .id,
    title: .title,
    description: .description,
    acceptance_criteria: .acceptance_criteria,
    status: .status,
    priority: .priority,
    executor: .executor,
    requires_review: (.requires_review == 1),
    execution_plan: .execution_plan,
    working_directory: .working_directory,
    session_reference: .session_reference,
    dispatched_at: .dispatched_at,
    agent_output: .agent_output,
    error_message: .error_message,
    context: .context,
    artifacts: .artifacts,
    repository: .repository,
    due_date: .due_date,
    tags: (.tags | if . == null or . == "" then [] else (try fromjson catch []) end),
    parent_task_id: .parent_task_id,
    project: .project,
    team: .team,
    assignees: (.assignees | if . == null or . == "" then [] else (try fromjson catch []) end),
    complexity_score: .complexity_score,
    backlog_order: .backlog_order,
    sprint_id: .sprint_id,
    branch: .branch,
    source_message_id: .source_message_id,
    blocked_by: (.blocked_by_ids | if . == null or . == "" then [] else split(",") end),
    created_at: .created_at,
    updated_at: .updated_at
  }]
}'

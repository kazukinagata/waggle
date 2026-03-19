#!/usr/bin/env bash
# Query waggle tasks from Turso database and output JSON.
#
# Usage: query-tasks.sh [where_clause] [order_clause] [limit]
#
# Environment:
#   TURSO_URL        (required)
#   TURSO_AUTH_TOKEN (required)

set -euo pipefail

WHERE_CLAUSE="${1:-}"
ORDER_CLAUSE="${2:-}"
LIMIT="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Execute via Turso API
RESPONSE=$("$SCRIPT_DIR/turso-exec.sh" "$SQL")

# Parse Turso pipeline response into waggle JSON format
# Turso returns: {"results": [{"response": {"type": "execute", "result": {"cols": [...], "rows": [...]}}}]}
echo "$RESPONSE" | jq '
  .results[0].response.result as $r |
  ($r.cols | map(.name)) as $cols |
  {results: [
    $r.rows[] | . as $row |
    [range($cols | length)] | map({($cols[.]): $row[.].value}) | add |
    {
      id: .id,
      title: .title,
      description: .description,
      acceptance_criteria: .acceptance_criteria,
      status: .status,
      priority: .priority,
      executor: .executor,
      requires_review: (if .requires_review == 1 or .requires_review == "1" then true else false end),
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
    }
  ]}
'

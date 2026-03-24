#!/usr/bin/env bash
# Analyze Notion task data and produce a JSON health report.
#
# Usage: analyze-tasks.sh <mode> <target_user_id> <target_user_name> <tasks_json> <blocked_json>
#
# Arguments:
#   mode             — "user" (filter by assignee) or "all" (no filter)
#   target_user_id   — UUID of the target user (ignored when mode=all)
#   target_user_name — Display name for the report header
#   tasks_json       — Path to JSON file with target tasks {"results": [...]}
#   blocked_json     — Path to JSON file with all Blocked tasks {"results": [...]}
#
# Output:
#   JSON object with sections: target, generated_at, age, quality, blocked, executor_ratio

set -euo pipefail

MODE="${1:?Usage: analyze-tasks.sh <mode> <target_user_id> <target_user_name> <tasks_json> <blocked_json>}"
TARGET_ID="${2:-}"
TARGET_NAME="${3:?target_user_name required}"
TASKS_FILE="${4:?tasks_json path required}"
BLOCKED_FILE="${5:?blocked_json path required}"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

for f in "$TASKS_FILE" "$BLOCKED_FILE"; do
  if [ ! -f "$f" ]; then
    echo "Error: File not found: $f" >&2
    exit 1
  fi
done

# Merge task data and blocked data, then run full analysis in a single jq call.
jq -n \
  --arg mode "$MODE" \
  --arg target_id "$TARGET_ID" \
  --arg target_name "$TARGET_NAME" \
  --slurpfile tasks "$TASKS_FILE" \
  --slurpfile blocked "$BLOCKED_FILE" \
'
# Helper: extract flat task record from a Notion page object
def extract_task:
  {
    id: .id,
    title: (.properties.Title.title[0].plain_text // "Untitled"),
    status: (.properties.Status.select.name // "N/A"),
    priority: (.properties.Priority.select.name // "N/A"),
    executor: (.properties.Executor.select.name // "N/A"),
    created: .created_time,
    assignees: [.properties.Assignees.people[]? | .name // .id],
    has_description: ((.properties.Description.rich_text | length) > 0),
    has_ac: ((.properties["Acceptance Criteria"].rich_text | length) > 0),
    has_plan: ((.properties["Execution Plan"].rich_text | length) > 0),
    has_agent_output: ((.properties["Agent Output"].rich_text | length) > 0),
    has_assignees: ((.properties.Assignees.people | length) > 0),
    has_executor: ((.properties.Executor.select.name // null) != null)
  };

# Helper: compute age in days from ISO timestamp (handles .000Z milliseconds)
def age_days:
  (now - (. | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 86400 | floor;

# Extract all tasks
($tasks[0].results | map(extract_task)) as $all_tasks |

# Extract blocked tasks (deduplicated with $all_tasks)
($blocked[0].results | map(extract_task)) as $blocked_raw |
([$all_tasks[], $blocked_raw[]] | unique_by(.id) | map(select(.status == "Blocked"))) as $all_blocked |

# Add age_days to each task
($all_tasks | map(. + { age_days: (.created | age_days) })) as $tasks_aged |
($all_blocked | map(. + { age_days: (.created | age_days) })) as $blocked_aged |

# === Dimension 1: Task Age ===
($tasks_aged
  | map(select(.status != "N/A"))
  | group_by(.status)
  | map({
      status: .[0].status,
      count: length,
      avg_days: ((map(.age_days) | add) / length | . * 10 | floor / 10),
      min_days: (map(.age_days) | min),
      max_days: (map(.age_days) | max)
    })
  | sort_by(.status)
) as $age_by_status |

($tasks_aged
  | map(select(.status != "Done"))
  | sort_by(-.age_days)
  | .[:10]
  | map({title: .title, status: .status, priority: .priority, age_days: .age_days})
) as $top_stagnating |

# === Dimension 2: Task Quality ===
# Required fields per status:
#   Ready: Description, Acceptance Criteria, Execution Plan, Assignees
#   In Progress: Description, Acceptance Criteria, Execution Plan, Assignees, Executor
#   Backlog: Description, Assignees (recommended)
#   Done: Agent Output (for AI-executed tasks)
def pct($field; $total):
  if $total == 0 then null
  else (($field * 1000 / $total | floor) / 10) end;

($tasks_aged
  | group_by(.status)
  | map(
      .[0].status as $st | length as $n |
      {
        status: $st,
        count: $n,
        description_pct: pct(map(select(.has_description)) | length; $n),
        ac_pct: pct(map(select(.has_ac)) | length; $n),
        plan_pct: pct(map(select(.has_plan)) | length; $n),
        assignees_pct: pct(map(select(.has_assignees)) | length; $n),
        executor_pct: pct(map(select(.has_executor)) | length; $n)
      }
    )
  | sort_by(.status)
) as $quality_by_status |

# Tasks missing required fields based on their status
($tasks_aged
  | map(select(.status != "Done"))
  | map(
      . as $t |
      (
        if $t.status == "Ready" or $t.status == "In Progress" then
          (
            (if $t.has_description | not then ["Description"] else [] end) +
            (if $t.has_ac | not then ["Acceptance Criteria"] else [] end) +
            (if $t.has_plan | not then ["Execution Plan"] else [] end) +
            (if $t.has_assignees | not then ["Assignees"] else [] end) +
            (if ($t.status == "In Progress") and ($t.has_executor | not) then ["Executor"] else [] end)
          )
        elif $t.status == "Backlog" then
          (if $t.has_description | not then ["Description"] else [] end)
        else [] end
      ) as $missing |
      if ($missing | length) > 0 then
        { title: $t.title, status: $t.status, missing: $missing }
      else empty end
    )
) as $missing_fields |

# === Dimension 3: Blocked Tasks ===
($blocked_aged
  | sort_by(-.age_days)
  | map({
      title: .title,
      assignees: (.assignees | join(", ")),
      priority: .priority,
      age_days: .age_days
    })
) as $blocked_list |

# === Dimension 4: Executor Ratio ===
def executor_counts:
  {
    human: map(select(.executor == "human")) | length,
    cli: map(select(.executor == "cli")) | length,
    "claude-desktop": map(select(.executor == "claude-desktop")) | length,
    cowork: map(select(.executor == "cowork")) | length,
    unset: map(select(.executor == "N/A")) | length
  };

{
  target: { mode: $mode, id: $target_id, name: $target_name },
  generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
  total_tasks: ($tasks_aged | length),
  age: {
    by_status: $age_by_status,
    top_stagnating: $top_stagnating
  },
  quality: {
    by_status: $quality_by_status,
    missing_fields: $missing_fields
  },
  blocked: $blocked_list,
  executor_ratio: {
    all: ($tasks_aged | executor_counts),
    done: ($tasks_aged | map(select(.status == "Done")) | executor_counts),
    non_done: ($tasks_aged | map(select(.status != "Done")) | executor_counts)
  }
}
'

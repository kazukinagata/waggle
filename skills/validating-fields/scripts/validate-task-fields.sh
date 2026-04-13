#!/usr/bin/env bash
# Deterministic field validation for task status transitions.
#
# Usage: validate-task-fields.sh <target_status> <task_json_file>
#
# Arguments:
#   target_status  — Status being transitioned TO: Ready, In Progress, Blocked, Done, Cancelled
#   task_json_file — Path to JSON file in canonical flat format (see SKILL.md)
#
# Output:
#   JSON: { valid: bool, target_status: str, errors: [...], warnings: [...] }
#   Exit code: always 0 (check .valid in output)

set -euo pipefail

TARGET_STATUS="${1:?Usage: validate-task-fields.sh <target_status> <task_json_file>}"
TASK_FILE="${2:?Usage: validate-task-fields.sh <target_status> <task_json_file>}"

if [ ! -f "$TASK_FILE" ]; then
  echo "{\"valid\":false,\"target_status\":\"${TARGET_STATUS}\",\"errors\":[{\"field\":\"input\",\"rule\":\"file_exists\",\"message\":\"Task file not found: ${TASK_FILE}\"}],\"warnings\":[]}"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

# Load code-task keywords from the sibling config file. We pipe-join them
# into a single alternation so jq can match them in a word-boundary regex.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_KEYWORDS_FILE="${SCRIPT_DIR}/../config/code-task-keywords.txt"
if [ -f "$CODE_KEYWORDS_FILE" ]; then
  CODE_KEYWORDS_PATTERN="$(grep -v '^#' "$CODE_KEYWORDS_FILE" | grep -v '^$' | sed 's/ /\\\\s\*/g' | paste -sd'|' -)"
else
  CODE_KEYWORDS_PATTERN=""
fi

RESULT=$(jq --arg target "$TARGET_STATUS" --arg code_keywords "$CODE_KEYWORDS_PATTERN" '
  # Helper: check semantic AC quality (contains verifiable conditions)
  def has_verifiable_conditions:
    # Command patterns
    (test("\\b(npm|curl|git|python|bash|test|run|build|deploy|make|cargo|go)\\b"; "i")) or
    # File path patterns
    (test("/|\\.(ts|js|py|md|html|css|json|yaml|yml|sh|rs|go|java|rb)\\b")) or
    # Numeric thresholds
    (test("\\d+\\s*(%|ms|s|count|times|items)")) or
    # Explicit state verbs
    (test("\\b(returns|displays|creates|exists|passes|fails|contains|shows|generates|sends|receives|confirms|records|updates|produces|outputs|renders|exports|imports|validates|verifies|checks|completes|delivers|publishes|shares|submits|approves)\\b"; "i"));

  # Read canonical flat fields
  (.description // "") as $desc |
  (.acceptanceCriteria // "") as $ac |
  (.executionPlan // "") as $plan |
  (.issuer // false) as $has_issuer |
  (.assigneeCount // 0) as $assignee_count |
  (.priority // null) as $priority |
  (.executor // null) as $executor |
  (.workingDirectory // "") as $workdir |
  (.branch // "") as $branch |
  (.agentOutput // "") as $agent_output |
  (.errorMessage // "") as $error_msg |
  (.parentTaskId // null) as $parent_task_id |
  (.hasChildren // false) as $has_children |
  (.createdAt // null) as $created_at |
  (.repository // "") as $repository |

  # Agent Output on Done becomes a hard error for tasks created on or after
  # this date. Tasks created before this date are grandfathered: empty Agent
  # Output remains a warning for them so we do not retroactively invalidate
  # historical Done tasks.
  "2026-04-14" as $agent_output_required_from |
  ($created_at != null and ($created_at | split("T")[0]) < $agent_output_required_from) as $is_legacy_task |

  # Collect errors and warnings
  [] as $errors | [] as $warnings |

  # --- Hierarchy check (defense-in-depth) ---
  (if $parent_task_id != null and $has_children == true
   then $errors + [{"field":"Parent Task","rule":"hierarchy_2level","message":"This task has subtasks and cannot itself be a subtask (2-level limit)."}]
   else $errors end) as $errors |

  # --- Common checks ---
  (if ($desc | length) == 0
   then $errors + [{"field":"Description","rule":"required_non_empty","message":"Description is required."}]
   else $errors end) as $errors |

  # --- Multi-assignee check (all statuses) ---
  (if $assignee_count > 1
   then $warnings + [{"field":"Assignee","rule":"single_assignee","message":"Multiple people detected in Assignee (\($assignee_count)). Waggle enforces single-assignee per task. Consider splitting into separate tasks."}]
   else $warnings end) as $warnings |

  # --- Status-specific checks ---
  (if $target == "Ready" or $target == "In Progress" then
    # Description length
    (if ($desc | length) > 0 and ($desc | length) < 50
     then $errors + [{"field":"Description","rule":"min_length","message":"Description is too short (< 50 chars). Elaborate on what needs to be done."}]
     else $errors end) as $errors |
    # AC required + semantic check
    (if ($ac | length) == 0
     then $errors + [{"field":"Acceptance Criteria","rule":"required_non_empty","message":"Acceptance Criteria is required for \($target) status."}]
     elif ($ac | has_verifiable_conditions | not)
     then $errors + [{"field":"Acceptance Criteria","rule":"semantic_quality","message":"AC lacks verifiable conditions. Include commands, file paths, metrics, or observable outcomes."}]
     else $errors end) as $errors |
    # Execution Plan required
    (if ($plan | length) == 0
     then $errors + [{"field":"Execution Plan","rule":"required_non_empty","message":"Execution Plan is required for \($target) status."}]
     else $errors end) as $errors |
    # In Progress: Executor required
    (if $target == "In Progress" then
      (if $executor == null
       then $errors + [{"field":"Executor","rule":"required_set","message":"Executor must be set before dispatch."}]
       else $errors end) as $errors |
      # Working Directory for AI executors
      (if ($executor == "cli" or $executor == "claude-desktop" or $executor == "cowork") and ($workdir | length) == 0
       then $errors + [{"field":"Working Directory","rule":"required_for_ai","message":"Working Directory is required for AI executor (\($executor))."}]
       else $errors end) as $errors |
      $errors
     else $errors end) as $errors |
    # Warnings
    (if $has_issuer == false
     then $warnings + [{"field":"Issuer","rule":"recommended","message":"Issuer is empty. Consider setting it manually."}]
     else $warnings end) as $warnings |
    (if $assignee_count == 0
     then $warnings + [{"field":"Assignee","rule":"recommended","message":"Assignee is empty. Issuer provides fallback ownership."}]
     else $warnings end) as $warnings |
    (if $priority == null
     then $warnings + [{"field":"Priority","rule":"recommended","message":"Priority is not set."}]
     else $warnings end) as $warnings |
    (if $target == "In Progress" and $executor == "cli" and ($branch | length) == 0
     then $warnings + [{"field":"Branch","rule":"recommended","message":"Branch is not set. Task will run on current branch."}]
     else $warnings end) as $warnings |
    # Working Directory warning for AI code tasks at Ready.
    # We heuristically check whether description, AC, or plan mention any
    # code-related keyword from config/code-task-keywords.txt. This is a
    # best-effort early signal — it becomes a hard error on In Progress.
    (if $target == "Ready"
        and ($executor == "cli" or $executor == "claude-desktop" or $executor == "claude-code" or $executor == "cowork")
        and ($workdir | length) == 0
        and ($code_keywords | length) > 0
        and (($desc + " " + $ac + " " + $plan) | test("\\b(" + $code_keywords + ")\\b"; "i"))
     then $warnings + [{"field":"Working Directory","rule":"recommended_code_task","message":"Working Directory is not set. AI code tasks need a working directory before dispatch — consider setting it now."}]
     else $warnings end) as $warnings |
    # Repository recommendation for AI code tasks at Ready.
    (if $target == "Ready"
        and ($executor == "cli" or $executor == "claude-desktop" or $executor == "claude-code" or $executor == "cowork")
        and ($repository | length) == 0
        and ($code_keywords | length) > 0
        and (($desc + " " + $ac + " " + $plan) | test("\\b(" + $code_keywords + ")\\b"; "i"))
     then $warnings + [{"field":"Repository","rule":"recommended_code_task","message":"Repository is not set. Consider adding the source repository URL for code tasks."}]
     else $warnings end) as $warnings |
    {"errors": $errors, "warnings": $warnings}

  elif $target == "Blocked" then
    (if ($ac | length) == 0
     then $errors + [{"field":"Acceptance Criteria","rule":"required_non_empty","message":"AC is required even for Blocked tasks. Define what completion looks like."}]
     else $errors end) as $errors |
    (if $has_issuer == false
     then $warnings + [{"field":"Issuer","rule":"recommended","message":"Issuer is empty."}]
     else $warnings end) as $warnings |
    (if ($error_msg | length) == 0
     then $warnings + [{"field":"Error Message","rule":"recommended","message":"Error Message is empty. Document why this task is blocked."}]
     else $warnings end) as $warnings |
    {"errors": $errors, "warnings": $warnings}

  elif $target == "Done" then
    # Helper: is this an AI executor task with empty Agent Output?
    (($executor == "cli" or $executor == "claude-desktop" or $executor == "claude-code" or $executor == "cowork") and ($agent_output | length) == 0) as $ai_missing_output |
    # Legacy tasks keep it as a warning; new tasks get a hard error.
    (if $ai_missing_output and $is_legacy_task
     then $warnings + [{"field":"Agent Output","rule":"legacy_recommended","message":"Agent Output is empty for AI executor (legacy task — created before \($agent_output_required_from), not enforced)."}]
     else $warnings end) as $warnings |
    (if $ai_missing_output and ($is_legacy_task | not)
     then $errors + [{"field":"Agent Output","rule":"required_for_ai_done","message":"Agent Output is required for AI executor tasks transitioning to Done. Record execution results before completing."}]
     else $errors end) as $errors |
    {"errors": $errors, "warnings": $warnings}

  elif $target == "Cancelled" then
    {"errors": $errors, "warnings": $warnings}

  else
    {"errors": $errors, "warnings": $warnings}
  end) as $result |

  {
    "valid": ($result.errors | length == 0),
    "target_status": $target,
    "errors": $result.errors,
    "warnings": $result.warnings
  }
' "$TASK_FILE")

echo "$RESULT"

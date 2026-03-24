#!/usr/bin/env bash
# Deterministic field validation for task status transitions.
#
# Usage: validate-task-fields.sh <target_status> <task_json_file>
#
# Arguments:
#   target_status  — Status being transitioned TO: Ready, In Progress, Blocked, Done
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

RESULT=$(jq --arg target "$TARGET_STATUS" '
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
  (.assigneesCount // 0) as $assignees_count |
  (.priority // null) as $priority |
  (.executor // null) as $executor |
  (.workingDirectory // "") as $workdir |
  (.branch // "") as $branch |
  (.agentOutput // "") as $agent_output |
  (.errorMessage // "") as $error_msg |

  # Collect errors and warnings
  [] as $errors | [] as $warnings |

  # --- Common checks ---
  (if ($desc | length) == 0
   then $errors + [{"field":"Description","rule":"required_non_empty","message":"Description is required."}]
   else $errors end) as $errors |

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
    (if $assignees_count == 0
     then $warnings + [{"field":"Assignees","rule":"recommended","message":"Assignees is empty. Issuer provides fallback ownership."}]
     else $warnings end) as $warnings |
    (if $priority == null
     then $warnings + [{"field":"Priority","rule":"recommended","message":"Priority is not set."}]
     else $warnings end) as $warnings |
    (if $target == "In Progress" and $executor == "cli" and ($branch | length) == 0
     then $warnings + [{"field":"Branch","rule":"recommended","message":"Branch is not set. Task will run on current branch."}]
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
    (if ($executor == "cli" or $executor == "claude-desktop" or $executor == "cowork") and ($agent_output | length) == 0
     then $warnings + [{"field":"Agent Output","rule":"recommended","message":"Agent Output is empty for AI executor. Record execution results."}]
     else $warnings end) as $warnings |
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

#!/usr/bin/env bash
# PreToolUse hook for Waggle: blocks direct Notion MCP writes to Waggle Task
# pages when no authorized Waggle skill is loaded in the recent transcript.
#
# Decision flow:
#   1. WAGGLE_TASK_WRITE_GUARD=off bypasses the guard entirely.
#   2. Otherwise, classify the call via schema fingerprint on tool_input
#      properties (no per-user config — works for any Notion MCP server prefix).
#   3. If fingerprint matches "Waggle Task write", scan the last 3 user-turn
#      boundaries of transcript_path for an authorized skill load signal.
#   4. If no authorization found, deny with a prescriptive redirect message.
#
# Fail-open: any internal error returns {} (allow), so hook bugs never brick
# the user's workflow. See the project plan for the design rationale.

set -u
trap 'echo "{}"; exit 0' ERR

# --- Opt-out ---------------------------------------------------------------
if [[ "${WAGGLE_TASK_WRITE_GUARD:-enforce}" == "off" ]]; then
  echo "{}"
  exit 0
fi

# --- Read hook input -------------------------------------------------------
INPUT="$(cat)"

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null) || { echo "{}"; exit 0; }
TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null) || TRANSCRIPT_PATH=""

case "$TOOL_NAME" in
  *notion-create-pages)    TOOL_OP="create-pages" ;;
  *notion-update-page)     TOOL_OP="update-page" ;;
  *notion-update-relation) TOOL_OP="update-relation" ;;
  *) echo "{}"; exit 0 ;;
esac

# --- Extract fingerprint inputs --------------------------------------------
# For create-pages and update-page, KEYS is a newline-separated list of
# property names. For update-relation, PROPERTY_NAME is the single relation
# property being written.
KEYS=""
STATUS_VALUE=""
PROPERTY_NAME=""

case "$TOOL_OP" in
  create-pages)
    KEYS=$(jq -r '[.tool_input.pages[]?.properties // {} | keys[]?] | unique | .[]?' <<<"$INPUT" 2>/dev/null) || KEYS=""
    # Status may be a nested {select:{name:...}} or a bare string depending
    # on the MCP server's serialization. Try both.
    STATUS_VALUE=$(jq -r '
      [.tool_input.pages[]?.properties.Status]
      | map(select(. != null))
      | (first // empty)
      | (
          if type == "object" then (.select.name? // .status.name? // empty)
          elif type == "string" then .
          else empty
          end
        )
    ' <<<"$INPUT" 2>/dev/null) || STATUS_VALUE=""
    ;;
  update-page)
    # update-page's properties accept string|number|null (see notion-provider
    # SKILL.md), so Status is a bare string here.
    KEYS=$(jq -r '.tool_input.data.properties // {} | keys[]?' <<<"$INPUT" 2>/dev/null) || KEYS=""
    STATUS_VALUE=$(jq -r '.tool_input.data.properties.Status // empty' <<<"$INPUT" 2>/dev/null) || STATUS_VALUE=""
    ;;
  update-relation)
    PROPERTY_NAME=$(jq -r '.tool_input.property_name // empty' <<<"$INPUT" 2>/dev/null) || PROPERTY_NAME=""
    ;;
esac

# --- Fingerprint classification --------------------------------------------
# Highly distinctive fields: 1 occurrence is enough. These names are
# Waggle-specific and rarely co-occur in unrelated Notion DBs.
# Issuer is excluded — Notion rejects writes that pass Issuer (see provider doc).
DISTINCTIVE_FIELDS="|Executor|Acknowledged At|Quality Verdict|Execution Plan|Acceptance Criteria|Blocked By|"

# Common fields: need 2 or more co-occurring to imply a Waggle Task write.
COMMON_FIELDS="|Status|Priority|Assignee|Due Date|Tags|Name|Description|"

# Waggle official Status values — used to discriminate Status updates that
# target the Tasks DB from same-named field updates on Intake Log / Active
# Threads (which use values like "active", "resolved", "closed").
WAGGLE_STATUS_VALUES="|Backlog|Ready|In Progress|In Review|Done|Blocked|Cancelled|"

distinctive_count=0
common_count=0
matched_fields=""

if [[ -n "$KEYS" ]]; then
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if [[ "$DISTINCTIVE_FIELDS" == *"|$key|"* ]]; then
      distinctive_count=$((distinctive_count + 1))
      matched_fields+="${matched_fields:+, }$key"
    elif [[ "$COMMON_FIELDS" == *"|$key|"* ]]; then
      common_count=$((common_count + 1))
      matched_fields+="${matched_fields:+, }$key"
    fi
  done <<<"$KEYS"
fi

should_check_auth=0

if (( distinctive_count >= 1 )); then
  should_check_auth=1
elif (( common_count >= 2 )); then
  should_check_auth=1
elif [[ "$TOOL_OP" == "update-page" || "$TOOL_OP" == "create-pages" ]]; then
  # Status single-field override: a one-field write like `{Status: "Backlog"}`
  # would otherwise slip past the count thresholds (common_count = 1 only).
  # We discriminate by VALUE — only Waggle-official Status values match — so
  # Intake Log (`active`/`resolved`) and Active Threads (`active`/`closed`)
  # are not over-collected. Executor is intentionally not handled here: it's
  # already in DISTINCTIVE_FIELDS, so any Executor write is caught by the
  # distinctive_count >= 1 branch above.
  if echo "$KEYS" | grep -qFx "Status" && [[ "$WAGGLE_STATUS_VALUES" == *"|$STATUS_VALUE|"* ]]; then
    should_check_auth=1
    matched_fields="Status=$STATUS_VALUE"
  fi
elif [[ "$TOOL_OP" == "update-relation" ]] && [[ "$PROPERTY_NAME" == "Blocked By" ]]; then
  # Only Blocked By is gated for relation updates. Parent Task is a common
  # Notion naming convention and would over-collect.
  should_check_auth=1
  matched_fields="Blocked By (relation)"
fi

if (( should_check_auth == 0 )); then
  echo "{}"
  exit 0
fi

# --- Transcript inspection -------------------------------------------------
# Scan backwards from the tail of the transcript. Use user-turn boundaries
# (.type == "user") to scope "recency": authorize if a whitelisted skill load
# signal appears anywhere within the last 3 user turns.
#
# We use awk for performance — spawning jq per JSONL line is too slow.
# The signals we look for are literal text patterns that Claude Code emits
# canonically:
#   1. <command-name>{skill}</command-name>  (skill load system reminder)
#   2. Skill tool tool_use with input.skill == {skill}
#   3. skills/{skill}/SKILL.md path (fallback — appears when SKILL.md is injected)

if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -r "$TRANSCRIPT_PATH" ]]; then
  echo "{}"
  exit 0
fi

authorized=$(tail -n 5000 "$TRANSCRIPT_PATH" 2>/dev/null \
  | awk -v n=3 '
    { lines[NR] = $0 }
    END {
      user_turns = 0
      for (i = NR; i >= 1; i--) {
        line = lines[i]

        # User turn boundary. Increment counter, but fall through to the
        # signal checks below — signals #1 (<command-name>) and #3 (SKILL.md
        # path) actually appear *inside* user-turn JSONL records (system
        # reminders and Read tool results are encoded as user-role entries).
        # Without falling through, those signals would be unreachable and
        # ingesting-messages (loaded via system reminder) would be denied
        # despite being authorized (Claude review feedback).
        if (line ~ /"type"[[:space:]]*:[[:space:]]*"user"/) {
          user_turns++
          if (user_turns > n) {
            print "no"
            exit
          }
        }

        # managing-tasks load signals
        if (index(line, "<command-name>managing-tasks</command-name>") \
            || index(line, "skills/managing-tasks/SKILL.md") \
            || (index(line, "\"name\":\"Skill\"") && index(line, "\"skill\":\"managing-tasks\"")) \
            || (index(line, "\"name\": \"Skill\"") && index(line, "\"skill\": \"managing-tasks\""))) {
          print "yes"
          exit
        }

        # ingesting-messages load signals
        if (index(line, "<command-name>ingesting-messages</command-name>") \
            || index(line, "skills/ingesting-messages/SKILL.md") \
            || (index(line, "\"name\":\"Skill\"") && index(line, "\"skill\":\"ingesting-messages\"")) \
            || (index(line, "\"name\": \"Skill\"") && index(line, "\"skill\": \"ingesting-messages\""))) {
          print "yes"
          exit
        }
      }
      print "no"
    }
  ') || authorized="no"

if [[ "$authorized" == "yes" ]]; then
  echo "{}"
  exit 0
fi

# --- Deny ------------------------------------------------------------------
reason="This tool call targets a Waggle Task page (detected via schema fingerprint: ${matched_fields}) but no authorized Waggle skill (managing-tasks, ingesting-messages) is active in the recent transcript. Direct Notion MCP writes on Waggle Task pages bypass the managing-tasks skill's quality gates (AC/EP rubric, executor-field invariants, Acknowledged At auto-set, subtask cascading, Quality Verdict caching). Invoke the \`managing-tasks\` skill via the Skill tool before retrying this operation. Once managing-tasks is loaded, it will perform the write through the correct flow. To opt out entirely (e.g., emergency manual operation), set WAGGLE_TASK_WRITE_GUARD=off."

# Optional forensic log — append-only, rotated at 10 MB. Lets users diagnose
# unexpected denies without depending on platform telemetry.
log_dir="${HOME}/.waggle"
log_file="${log_dir}/hook-denies.log"
if mkdir -p "$log_dir" 2>/dev/null && [[ -w "$log_dir" ]]; then
  if [[ -f "$log_file" ]]; then
    size=$(wc -c < "$log_file" 2>/dev/null || echo 0)
    if (( size > 10485760 )); then
      # Rotate with a timestamp suffix instead of a single ".1" slot so that
      # successive rotations during deny spikes don't silently overwrite the
      # previous backup (Claude review feedback). Keep at most 5 backups —
      # prune the oldest, leaving forensic evidence bounded but preserved.
      mv "$log_file" "${log_file}.$(date -u +%Y%m%d-%H%M%S)" 2>/dev/null || true
      # Note: `xargs` (not `xargs -r`) — `-r` / --no-run-if-empty is GNU-only
      # and BSD xargs (macOS) errors on it. `rm -f` with no args is a no-op
      # under `2>/dev/null || true`, so pruning works on both platforms.
      ls -1t "${log_file}".* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi
  fi
  printf '%s %s matched=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOOL_NAME" "$matched_fields" >> "$log_file" 2>/dev/null || true
fi

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0

#!/usr/bin/env bash
# check-task-write.sh — PreToolUse guard against direct Notion MCP writes to Waggle Task pages.
#
# Invoked by providers/notion/hooks/hooks.json on matching notion-create-pages /
# notion-update-page / notion-update-relation calls. Reads the hook payload on stdin
# and emits a PreToolUse decision on stdout:
#   - `{}`                                  -> no decision; normal permission flow (allow)
#   - {hookSpecificOutput: permissionDecision: deny ...}  -> block the write
#
# It denies a write only when (a) the payload fingerprints as a Waggle Task page AND
# (b) no authorized Waggle writer skill is visible in the recent transcript. A separate
# hard gate denies Ready+ promotions that carry no valid Quality Verdict.
#
# Fail-open by design: any unexpected error allows the write (see `trap fail ERR`).
#
# Opt-outs:  WAGGLE_TASK_WRITE_GUARD=off   disables the whole guard
#            WAGGLE_QUALITY_GATE=off       disables only the Quality-Verdict gate
#
# NOTE: platform detection is intentionally NOT done here. On Cowork-Windows
# ${CLAUDE_PLUGIN_ROOT} is empty, so this script is never reached at all; the wrapper
# in hooks.json fails open cleanly there. A `uname` check inside this file could never
# run on that platform, so it would be dead code.

set -u
fail(){ echo "{}"; exit 0; }
trap fail ERR

# Global opt-out.
[ "${WAGGLE_TASK_WRITE_GUARD:-}" = "off" ] && { echo "{}"; exit 0; }

INPUT=$(cat)
TOOL=$(jq -r '.tool_name // empty' <<<"$INPUT")
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT")

# ── Classify the call and collect the property fingerprint ──────────────────────────
# NEED_AUTH is set once we're confident the write targets a Waggle Task page.
# MATCHED records what tripped the detector (for the denial message).
NEED_AUTH=""; MATCHED=""
case "$TOOL" in
  *notion-update-relation)
    # The relation MCP tool is waggle-exclusive; any call is task-scoped.
    NEED_AUTH=1; MATCHED="relation update (waggle-exclusive server)" ;;
  *notion-create-pages)
    KEYS=$(jq -r '[.tool_input.pages[]?.properties // {} | keys[]?] | unique | .[]?' <<<"$INPUT")
    STATUS=$(jq -r '[.tool_input.pages[]?.properties.Status] | map(select(.!=null)) | (first // empty)' <<<"$INPUT") ;;
  *notion-update-page)
    # Only property updates are interesting; content inserts pass through.
    CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT")
    [ "$CMD" = "update_properties" ] || { echo "{}"; exit 0; }
    KEYS=$(jq -r '.tool_input.properties // {} | keys[]?' <<<"$INPUT")
    STATUS=$(jq -r '.tool_input.properties.Status // empty' <<<"$INPUT") ;;
  *) echo "{}"; exit 0 ;;
esac

# ── Schema fingerprint (create/update only; relation already decided above) ─────────
# A write looks like a Waggle Task page if it touches >=1 distinctive field, or >=2
# common fields, or sets a recognized Status value.
if [ -z "$NEED_AUTH" ] && [ -n "${KEYS:-}" ]; then
  DIST="|Executor|Acknowledged At|Quality Verdict|Execution Plan|Acceptance Criteria|Blocked By|"
  COMM="|Status|Priority|Assignee|Due Date|Tags|Title|Description|"
  STATUSES="|Backlog|Ready|In Progress|In Review|Done|Blocked|Cancelled|"
  D=0; C=0; M=""
  while IFS= read -r K; do
    [ -z "$K" ] && continue
    # Normalize Notion's composite key prefixes/suffixes (date:/place:/userDefined:, :start, etc.)
    K="${K#date:}"; K="${K#place:}"; K="${K#userDefined:}"
    K="${K%:start}"; K="${K%:end}"; K="${K%:is_datetime}"
    K="${K%:name}"; K="${K%:address}"; K="${K%:latitude}"; K="${K%:longitude}"; K="${K%:google_place_id}"
    if [[ "$DIST" == *"|$K|"* ]]; then D=$((D+1)); M="${M:+$M,}$K"
    elif [[ "$COMM" == *"|$K|"* ]]; then C=$((C+1)); M="${M:+$M,}$K"; fi
  done <<<"$KEYS"
  if [ "$D" -ge 1 ] || [ "$C" -ge 2 ]; then NEED_AUTH=1; MATCHED="$M"
  elif [ -n "${STATUS:-}" ] && [[ "$STATUSES" == *"|$STATUS|"* ]]; then NEED_AUTH=1; MATCHED="Status=$STATUS"; fi
fi

# ── Quality-Verdict gate: every Ready+ promotion must carry a valid verdict ─────────
# Evaluated per page so a batch create with one bad Ready+ page is denied.
if [ -n "$NEED_AUTH" ] && [ "${WAGGLE_QUALITY_GATE:-}" != "off" ]; then
  READYPLUS="|Ready|In Progress|In Review|Done|"
  QVRE="^(PASS|NEEDS_REFINEMENT|REJECT) hash=[0-9a-f]{8} @[^ ]+ v1"
  TAB=$(printf '\t')
  # (Status, Quality Verdict) pairs, one per page being written.
  case "$TOOL" in
    *notion-create-pages) PAIRS=$(jq -r '.tool_input.pages[]? | [(.properties.Status // ""), (.properties."Quality Verdict" // "")] | @tsv' <<<"$INPUT") ;;
    *) PAIRS=$(jq -r '[(.tool_input.properties.Status // ""), (.tool_input.properties."Quality Verdict" // "")] | @tsv' <<<"$INPUT") ;;
  esac
  GATE=""; BADSTATUS=""
  while IFS="$TAB" read -r ST QV; do
    [ -z "$ST" ] && continue
    [[ "$READYPLUS" == *"|$ST|"* ]] || continue
    GATE=1
    [[ "$QV" =~ $QVRE ]] || BADSTATUS="$ST"
  done <<<"$PAIRS"
  if [ -n "$GATE" ] && [ -n "$BADSTATUS" ]; then
    # A live reviewing-quality run in the transcript means the verdict is being authored now.
    if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] && tail -n 5000 "$TRANSCRIPT" 2>/dev/null | grep -Eq "reviewing-quality|task-quality-reviewer-agent"; then echo "{}"; exit 0; fi
    QREASON="This write promotes a Waggle task to Ready+ (Status=$BADSTATUS) but carries no valid Quality Verdict, and no reviewing-quality run is visible in the recent transcript. An unreviewed task cannot enter Ready+ — direct promotion bypasses the Reviewer quality gate. Invoke /waggle:planning-tasks (or managing-tasks) first so reviewing-quality writes a real verdict into the same update. Opt-out: set WAGGLE_QUALITY_GATE=off."
    jq -n --arg e PreToolUse --arg d deny --arg r "$QREASON" '{hookSpecificOutput:{hookEventName:$e,permissionDecision:$d,permissionDecisionReason:$r}}'
    exit 0
  fi
  # Ready+ write with a valid verdict (or no Ready+ status): the gate is satisfied; allow.
  [ -n "$GATE" ] && { echo "{}"; exit 0; }
fi

# Not a Waggle Task write: allow.
[ -z "$NEED_AUTH" ] && { echo "{}"; exit 0; }

# ── Authorization: allow if an authorized writer skill is active in the transcript ──
if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  S="managing-tasks|ingesting-messages|delegating-tasks|executing-tasks|planning-tasks|running-daily-tasks"
  RE="\"skill_name\":\"waggle:($S)\"|<command-name>($S)</command-name>|skills/($S)/SKILL.md|\"skill\":[ ]*\"($S)\""
  if tail -n 5000 "$TRANSCRIPT" 2>/dev/null | grep -Eq "$RE"; then echo "{}"; exit 0; fi
fi

# Task write with no authorized writer in context: deny.
REASON="This call targets a Waggle Task page (detected: $MATCHED) but no authorized Waggle skill is active in the recent transcript. Direct Notion MCP writes bypass managing-tasks quality gates (AC/EP rubric, executor-field invariants, Acknowledged At auto-set, subtask cascading). Invoke /waggle:managing-tasks (or ingesting-messages / delegating-tasks / executing-tasks / planning-tasks / running-daily-tasks) before retrying. Opt-out: set WAGGLE_TASK_WRITE_GUARD=off."
jq -n --arg e PreToolUse --arg d deny --arg r "$REASON" '{hookSpecificOutput:{hookEventName:$e,permissionDecision:$d,permissionDecisionReason:$r}}'
exit 0

#!/usr/bin/env bash
# run.sh — unit test harness for the PreToolUse task-write guard.
#
# For each fixtures/*.json it runs the real guard script (via driver.sh, which
# invokes hooks/check-task-write.sh) and asserts the decision (deny|allow)
# and a clean exit (0). Fixtures whose transcript_path is the literal token
# __TRANSCRIPT__ are materialized at runtime from a companion <name>.transcript
# file, so fixtures stay machine-independent. Also unit-tests the matcher regex.
#
# Exit 0 only if every case passes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXDIR="$HERE/fixtures"
HOOKS_JSON="$HERE/../../hooks/hooks.json"
DRIVER="$HERE/driver.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0

# expected decision per fixture (deny|allow)
expected_for() {
  case "$1" in
    01-guard-off)                       echo allow ;;
    02-non-waggle)                      echo allow ;;
    03-create-distinctive-unauth)       echo deny  ;;
    04-create-distinctive-auth)         echo allow ;;
    05-create-common2-unauth)           echo deny  ;;
    06-update-status-done-unauth)       echo deny  ;;
    07-update-status-resolved)          echo allow ;;
    08-update-date-normalization-unauth) echo deny ;;
    09-update-insert-content)           echo allow ;;
    10-relation-blockedby-unauth)       echo deny  ;;
    11-relation-parenttask-unauth)      echo deny  ;;
    12-auth-executing-skill)            echo allow ;;
    13-auth-delegating-path)            echo allow ;;
    14-viewing-only-unauth)             echo deny  ;;
    15-malformed)                       echo allow ;;
    16-empty-transcript)                echo deny  ;;
    17-relation-blockedby-auth)         echo allow ;;
    18-create-ready-no-verdict-unauth)  echo deny  ;;
    19-update-ready-no-verdict-unauth)  echo deny  ;;
    20-update-ready-pass-verdict)       echo allow ;;
    21-update-ready-needsrefine-verdict) echo allow ;;
    22-update-ready-unreviewed)         echo deny  ;;
    23-update-inprogress-verdict)       echo allow ;;
    24-update-ready-reviewing-quality-trace) echo allow ;;
    25-update-backlog-no-verdict-auth)  echo allow ;;
    26-update-ready-quality-gate-off)   echo allow ;;
    27-create-ready-pass-verdict)       echo allow ;;
    *) echo "UNKNOWN" ;;
  esac
}

run_case() {
  local fx="$1" name exp env_prefix fixture transcript out decision
  name="$(basename "$fx" .json)"
  exp="$(expected_for "$name")"
  if [ "$exp" = "UNKNOWN" ]; then
    echo "FAIL  $name : no expectation defined"; FAIL=$((FAIL+1)); return
  fi

  fixture="$fx"
  # Materialize __TRANSCRIPT__ if a companion transcript exists.
  if [ -f "$FIXDIR/$name.transcript" ]; then
    transcript="$TMP/$name.transcript"
    cp "$FIXDIR/$name.transcript" "$transcript"
    fixture="$TMP/$name.json"
    sed "s#__TRANSCRIPT__#$transcript#g" "$fx" > "$fixture"
  fi

  if [ "$name" = "01-guard-off" ]; then
    out="$(WAGGLE_TASK_WRITE_GUARD=off bash "$DRIVER" "$fixture" 2>/dev/null)"
  elif [ "$name" = "26-update-ready-quality-gate-off" ]; then
    out="$(WAGGLE_QUALITY_GATE=off bash "$DRIVER" "$fixture" 2>/dev/null)"
  else
    out="$(bash "$DRIVER" "$fixture" 2>/dev/null)"
  fi
  local rc=$?

  if [ $rc -ne 0 ]; then
    echo "FAIL  $name : non-zero exit ($rc)"; FAIL=$((FAIL+1)); return
  fi

  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
    decision=deny
  elif [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "{}" ]; then
    decision=allow
  else
    echo "FAIL  $name : unrecognized output: $out"; FAIL=$((FAIL+1)); return
  fi

  if [ "$decision" = "$exp" ]; then
    echo "ok    $name ($decision)"; PASS=$((PASS+1))
  else
    echo "FAIL  $name : expected $exp got $decision"; FAIL=$((FAIL+1))
  fi
}

echo "== fixture cases =="
for fx in "$FIXDIR"/*.json; do
  run_case "$fx"
done

echo "== matcher regex =="
RE="$(jq -r '.hooks.PreToolUse[0].matcher' "$HOOKS_JSON")"
matcher_should() {
  local tool="$1" want="$2" got
  if printf '%s' "$tool" | grep -Eq "$RE"; then got=match; else got=nomatch; fi
  if [ "$got" = "$want" ]; then echo "ok    matcher $tool ($got)"; PASS=$((PASS+1))
  else echo "FAIL  matcher $tool : expected $want got $got"; FAIL=$((FAIL+1)); fi
}
matcher_should mcp__claude_ai_Notion__notion-create-pages       match
matcher_should mcp__claude_ai_Notion__notion-update-page        match
matcher_should mcp__notion-extension__notion-update-relation    match
matcher_should mcp__notion-extension__notion-query              nomatch
matcher_should mcp__claude_ai_Notion__notion-fetch              nomatch

echo "== hooks.json wrapper =="
WRAP_CMD="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS_JSON")"
# Unresolved plugin root (Cowork-Windows symptom): script unreachable -> clean allow.
wrap_out="$(CLAUDE_PLUGIN_ROOT= sh -c "$WRAP_CMD" </dev/null 2>/dev/null)"
wrap_rc=$?
if [ "$wrap_rc" -eq 0 ] && [ "$(printf '%s' "$wrap_out" | tr -d '[:space:]')" = "{}" ]; then
  echo "ok    wrapper empty-CLAUDE_PLUGIN_ROOT -> clean allow"; PASS=$((PASS+1))
else
  echo "FAIL  wrapper empty-CLAUDE_PLUGIN_ROOT : rc=$wrap_rc out=$wrap_out"; FAIL=$((FAIL+1))
fi
# Resolved plugin root: wrapper reaches the script and applies the guard (deny here).
wrap_out="$(CLAUDE_PLUGIN_ROOT="$HERE/../.." sh -c "$WRAP_CMD" < "$FIXDIR/03-create-distinctive-unauth.json" 2>/dev/null)"
wrap_rc=$?
if [ "$wrap_rc" -eq 0 ] && printf '%s' "$wrap_out" | grep -q '"permissionDecision": *"deny"'; then
  echo "ok    wrapper resolved-CLAUDE_PLUGIN_ROOT -> reaches script (deny)"; PASS=$((PASS+1))
else
  echo "FAIL  wrapper resolved-CLAUDE_PLUGIN_ROOT : rc=$wrap_rc out=$wrap_out"; FAIL=$((FAIL+1))
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

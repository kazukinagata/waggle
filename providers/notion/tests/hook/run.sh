#!/usr/bin/env bash
# run.sh — unit tests for the SessionStart guidance hook.
#
# The former PreToolUse hard-deny guard (check-task-write.sh) was removed; it
# false-positive-denied unrelated Notion DBs because it could not scope a write to
# the Waggle Tasks data source without a fetch. It is replaced by a non-blocking
# SessionStart hook (session-guidance.sh) that injects standing guidance.
#
# This suite asserts: the script emits a well-formed SessionStart decision, embeds the
# Tasks data-source id only when WAGGLE_NOTION_TASKS_DB_ID is set, fails open on bad
# input, the hooks.json wrapper fails open on an unresolved CLAUDE_PLUGIN_ROOT, and the
# SessionStart matcher fires on the intended sources.
#
# Exit 0 only if every case passes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HERE/../../hooks"
HOOKS_JSON="$HOOKS_DIR/hooks.json"
SCRIPT="$HOOKS_DIR/session-guidance.sh"

PASS=0; FAIL=0
ok(){ echo "ok    $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL  $1"; FAIL=$((FAIL+1)); }

# Assert stdout is valid JSON with hookEventName == "SessionStart" and non-empty context.
assert_session_json() {
  local label="$1" out="$2"
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then bad "$label : not valid JSON: $out"; return; fi
  local ev ctx
  ev="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // empty')"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  [ "$ev" = "SessionStart" ] || { bad "$label : hookEventName=$ev"; return; }
  [ -n "$ctx" ] || { bad "$label : empty additionalContext"; return; }
  ok "$label"
}

echo "== session-guidance.sh =="

# 1. With the env var: valid SessionStart JSON, and the id is embedded.
OUT="$(printf '%s' '{"source":"startup"}' | WAGGLE_NOTION_TASKS_DB_ID=ds-1234 bash "$SCRIPT" 2>/dev/null)"
assert_session_json "env-set: well-formed SessionStart context" "$OUT"
if printf '%s' "$OUT" | jq -er '.hookSpecificOutput.additionalContext | test("ds-1234")' >/dev/null 2>&1; then
  ok "env-set: data source id embedded"; else bad "env-set: id NOT embedded: $OUT"; fi

# 2. Without the env var: still valid, but the id must be absent.
OUT="$(printf '%s' '{"source":"compact"}' | env -u WAGGLE_NOTION_TASKS_DB_ID bash "$SCRIPT" 2>/dev/null)"
assert_session_json "env-unset: well-formed SessionStart context" "$OUT"
if printf '%s' "$OUT" | jq -er '.hookSpecificOutput.additionalContext | test("data source id")' >/dev/null 2>&1; then
  bad "env-unset: id leaked: $OUT"; else ok "env-unset: no id in context"; fi

# 3. Fail-open on malformed stdin (still exits 0 with valid JSON).
OUT="$(printf '%s' 'not json at all' | env -u WAGGLE_NOTION_TASKS_DB_ID bash "$SCRIPT" 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "malformed stdin: exits 0 with valid JSON"; else bad "malformed stdin: rc=$RC out=$OUT"; fi

echo "== hooks.json wrapper =="
WRAP_CMD="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON")"
# Unresolved plugin root (Cowork-Windows symptom): script unreachable -> clean no-op.
OUT="$(CLAUDE_PLUGIN_ROOT= sh -c "$WRAP_CMD" </dev/null 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "{}" ]; then
  ok "wrapper empty-CLAUDE_PLUGIN_ROOT -> clean no-op"; else bad "wrapper empty-root: rc=$RC out=$OUT"; fi
# Resolved plugin root: wrapper reaches the script and emits SessionStart context.
OUT="$(CLAUDE_PLUGIN_ROOT="$HERE/../.." sh -c "$WRAP_CMD" </dev/null 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1; then
  ok "wrapper resolved-CLAUDE_PLUGIN_ROOT -> emits SessionStart context"; else bad "wrapper resolved-root: rc=$RC out=$OUT"; fi

echo "== SessionStart matcher =="
RE="$(jq -r '.hooks.SessionStart[0].matcher' "$HOOKS_JSON")"
matcher_should() {
  local src="$1" want="$2" got
  if printf '%s' "$src" | grep -Eq "^($RE)$"; then got=match; else got=nomatch; fi
  if [ "$got" = "$want" ]; then ok "matcher source=$src ($got)"; else bad "matcher source=$src: expected $want got $got"; fi
}
matcher_should startup match
matcher_should compact match
matcher_should resume  match
matcher_should clear   nomatch

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

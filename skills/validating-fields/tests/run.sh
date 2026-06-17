#!/usr/bin/env bash
# run.sh — tests for validate-task-fields.sh Quality Verdict integrity checks.
#
# Focuses on the verdict format / PASS gate added for Ready / In Progress: a
# fabricated (non-hex / mnemonic hash) or non-PASS verdict must invalidate the
# transition, while a well-formed PASS verdict passes and an absent verdict is a
# warning (not a hard error). Content-hash matching is out of scope here (verified
# by the org-layer hook) — a mnemonic that happens to be all-hex is a known gap.
#
# Requires bash + jq. Exit 0 only if every case passes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/validate-task-fields.sh"

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

DESC='Implement the foo endpoint so that it returns 200 and renders output correctly for users'
AC='Run npm test; /src/foo.ts returns 200 and displays the result'
EP='1. edit /src/foo.ts 2. npm test'

# task <verdict> -> canonical flat JSON with valid AC/EP/Description so only the
# verdict drives the assertion.
task() {
  jq -nc --arg d "$DESC" --arg ac "$AC" --arg ep "$EP" --arg v "$1" \
    '{description:$d,acceptanceCriteria:$ac,executionPlan:$ep,issuer:true,assigneeCount:1,priority:"P2",qualityVerdict:$v}'
}

# run <name> <target> <verdict> <expect-valid:true|false> [expect-error-rule]
run() {
  local name="$1" target="$2" verdict="$3" expect="$4" rule="${5:-}"
  local f out valid
  f="$(mktemp)"; task "$verdict" >"$f"
  out="$(bash "$SCRIPT" "$target" "$f")"; rm -f "$f"
  if ! jq -e . <<<"$out" >/dev/null 2>&1; then no "$name" "non-JSON: $out"; return; fi
  valid="$(jq -r '.valid' <<<"$out")"
  if [ "$valid" != "$expect" ]; then no "$name" "valid=$valid expected=$expect; $out"; return; fi
  if [ -n "$rule" ] && ! jq -e --arg r "$rule" '.errors[]|select(.rule==$r)' <<<"$out" >/dev/null; then
    no "$name" "missing error rule '$rule'; $out"; return
  fi
  ok "$name"
}

# Fabricated mnemonic hash (non-hex) at Ready -> invalid (verdict_format).
run "Ready + fabricated mnemonic hash -> invalid" Ready 'PASS hash=line0612a @2026-06-10T00:00:00Z v1' false verdict_format
# Well-formed PASS verdict -> verdict does not invalidate.
run "Ready + well-formed PASS -> valid" Ready 'PASS hash=abc12345 @2026-06-10T10:42:00Z v1' true
# Well-formed but non-PASS at Ready -> invalid (verdict_not_pass).
run "Ready + NEEDS_REFINEMENT -> invalid" Ready 'NEEDS_REFINEMENT hash=abc12345 @2026-06-10T10:42:00Z v1' false verdict_not_pass
# Absent verdict -> not a hard error (warning only).
run "Ready + no verdict -> valid (warning only)" Ready '' true
# In Progress is gated the same as Ready.
run "In Progress + fabricated hash -> invalid" "In Progress" 'PASS hash=menu0001x @2026-06-10T00:00:00Z v1' false verdict_format
# Backlog is not a Ready+ transition -> verdict not checked.
run "Backlog + fabricated hash -> valid (not checked)" Backlog 'PASS hash=line0612a @x v1' true
# suppressed-until suffix is accepted by the format.
run "Ready + PASS w/ suppressed-until -> valid" Ready 'PASS hash=abc12345 @2026-06-10T10:42:00Z v1 suppressed-until=2026-06-17T10:42:00Z' true
# Forward-compat: a future v2 with unknown trailing key=value pairs must NOT be rejected
# (cache-format.md "Forward compatibility").
run "Ready + PASS v2 w/ unknown trailing key -> valid" Ready 'PASS hash=abc12345 @2026-06-10T10:42:00Z v2 newkey=foo' true
# Whitespace-only verdict is treated as absent (warning, not a hard format error).
run "Ready + whitespace-only verdict -> valid (treated absent)" Ready '   ' true
# A fabricated verdict that adds a trailing key is still caught (hash is the signal).
run "Ready + fabricated hash w/ trailing key -> invalid" Ready 'PASS hash=line0612a @2026-06-10T00:00:00Z v1 extra=1' false verdict_format

# Absent verdict raises the verdict_recommended warning.
WARN_F="$(mktemp)"; task '' >"$WARN_F"
if bash "$SCRIPT" Ready "$WARN_F" | jq -e '.warnings[]|select(.rule=="verdict_recommended")' >/dev/null; then
  ok "Ready + no verdict -> verdict_recommended warning present"
else
  no "Ready + no verdict -> verdict_recommended warning present" "warning missing"
fi
rm -f "$WARN_F"

echo "---- $PASS passed, $FAIL failed ----"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# run.sh — behavior-pinning tests for validate-task-fields.sh.
#
# This suite is the drift guard between the script, SKILL.md's Validation Rules
# table, and references/quality-rubric.md: every documented rule has at least one
# fixture here. If the docs and the script disagree, these tests are the arbiter.
# Any change to the script or the rule docs must update this file in the same
# commit (see SKILL.md "Drift guard").
#
# Requires bash + jq. Exit 0 only if every case passes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/validate-task-fields.sh"

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# Baseline task: everything a Ready/In Progress transition needs. Tests override
# individual fields via jq-merge to isolate the rule under test.
BASE='{
  "description": "Implement the foo endpoint so that it returns 200 and renders output correctly for users",
  "acceptanceCriteria": "Run npm test; /src/foo.ts returns 200 and displays the result",
  "executionPlan": "1. edit /src/foo.ts 2. npm test",
  "issuer": true,
  "assigneeCount": 1,
  "priority": "P2",
  "executor": "cli",
  "workingDirectory": "/work/repo",
  "createdAt": "2026-05-01T00:00:00.000Z",
  "qualityVerdict": ""
}'

# run <name> <target> <json-override> <expect-valid:true|false> [expect-rule] [expect-kind:errors|warnings]
run() {
  local name="$1" target="$2" override="$3" expect="$4" rule="${5:-}" kind="${6:-errors}"
  local f out valid
  f="$(mktemp)"
  jq -nc --argjson base "$BASE" --argjson o "$override" '$base * $o' >"$f"
  out="$(bash "$SCRIPT" "$target" "$f")"; rm -f "$f"
  if ! jq -e . <<<"$out" >/dev/null 2>&1; then no "$name" "non-JSON: $out"; return; fi
  valid="$(jq -r '.valid' <<<"$out")"
  if [ "$valid" != "$expect" ]; then no "$name" "valid=$valid expected=$expect; $out"; return; fi
  if [ -n "$rule" ] && ! jq -e --arg r "$rule" ".${kind}[]|select(.rule==\$r)" <<<"$out" >/dev/null; then
    no "$name" "missing $kind rule '$rule'; $out"; return
  fi
  ok "$name"
}

# ---------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------
run "Ready + baseline task -> valid" Ready '{}' true
run "Cancelled + baseline -> valid" Cancelled '{}' true

# ---------------------------------------------------------------------------
# Language independence (v3.0.0 regression — semantic_quality removal)
# A well-specified AC written entirely in Japanese must pass Ready: Layer 1 is
# structural-only and must never judge AC content by English keyword lists.
# ---------------------------------------------------------------------------
run "Ready + pure-Japanese AC -> valid" Ready \
  '{"acceptanceCriteria":"完成版のブランチが下書きテーマとして管理画面に存在し、マーチャントがテーマエディタ上で内容を確認済みであること"}' true
run "Ready + pure-Japanese AC and EP -> valid" Ready \
  '{"acceptanceCriteria":"定例でマーチャントと構成を確認し、確定版のマージが完了している","executionPlan":"1. 下書きテーマを作成する 2. 定例で内容を確認する 3. 確定版のマージを依頼する"}' true

# ---------------------------------------------------------------------------
# Description rules
# ---------------------------------------------------------------------------
run "Ready + empty Description -> invalid" Ready '{"description":""}' false required_non_empty
run "Ready + short Description (<50 chars) -> invalid" Ready '{"description":"Fix the bug quickly"}' false min_length
run "Blocked + empty Description -> invalid" Blocked '{"description":""}' false required_non_empty

# ---------------------------------------------------------------------------
# AC / EP required
# ---------------------------------------------------------------------------
run "Ready + empty AC -> invalid" Ready '{"acceptanceCriteria":""}' false required_non_empty
run "Ready + empty EP -> invalid" Ready '{"executionPlan":""}' false required_non_empty
run "Blocked + empty AC -> invalid" Blocked '{"acceptanceCriteria":""}' false required_non_empty

# ---------------------------------------------------------------------------
# Reserved placeholders (structural rule: any of the three strings blocks Ready+)
# ---------------------------------------------------------------------------
run "Ready + [DRAFT-AC] in AC -> invalid" Ready \
  '{"acceptanceCriteria":"[DRAFT-AC] branch exists for GP and merchant editing"}' false placeholder_present
run "Ready + [NEEDS-REFINE] in AC -> invalid" Ready \
  '{"acceptanceCriteria":"[NEEDS-REFINE] Run npm test; /src/foo.ts returns 200"}' false placeholder_present
run "Ready + [DRAFT-EP] in EP -> invalid" Ready \
  '{"executionPlan":"[DRAFT-EP] 1. (to be refined by planning agent) 2. ..."}' false placeholder_present
run "Ready + [DRAFT-EP] left inside AC -> invalid" Ready \
  '{"acceptanceCriteria":"[DRAFT-EP] leftover stub text that was pasted into the wrong field"}' false placeholder_present
run "In Progress + [NEEDS-REFINE] in EP -> invalid" "In Progress" \
  '{"executionPlan":"[NEEDS-REFINE] 1. edit /src/foo.ts 2. npm test"}' false placeholder_present
run "Backlog + [DRAFT-AC] -> valid (placeholders gate Ready+ only)" Backlog \
  '{"acceptanceCriteria":"[DRAFT-AC] stub"}' true

# ---------------------------------------------------------------------------
# Quality Verdict integrity (format + PASS gate)
# ---------------------------------------------------------------------------
run "Ready + fabricated mnemonic hash -> invalid" Ready \
  '{"qualityVerdict":"PASS hash=line0612a @2026-06-10T00:00:00Z v1"}' false verdict_format
run "Ready + well-formed PASS -> valid" Ready \
  '{"qualityVerdict":"PASS hash=abc12345 @2026-06-10T10:42:00Z v1"}' true
run "Ready + NEEDS_REFINEMENT -> invalid" Ready \
  '{"qualityVerdict":"NEEDS_REFINEMENT hash=abc12345 @2026-06-10T10:42:00Z v1"}' false verdict_not_pass
run "Ready + REJECT -> invalid" Ready \
  '{"qualityVerdict":"REJECT hash=abc12345 @2026-06-10T10:42:00Z v1"}' false verdict_not_pass
run "Ready + no verdict -> valid (warning only)" Ready '{"qualityVerdict":""}' true
run "Ready + no verdict -> verdict_recommended warning" Ready '{"qualityVerdict":""}' true verdict_recommended warnings
run "Ready + whitespace-only verdict -> valid (treated absent)" Ready '{"qualityVerdict":"   "}' true
run "In Progress + fabricated hash -> invalid" "In Progress" \
  '{"qualityVerdict":"PASS hash=menu0001x @2026-06-10T00:00:00Z v1"}' false verdict_format
run "Backlog + fabricated hash -> valid (not checked)" Backlog \
  '{"qualityVerdict":"PASS hash=line0612a @x v1"}' true
# Legacy tolerance: v2.x lines carry a suppressed-until key. Suppression was
# removed in v3.0.0, but parsers MUST NOT reject unknown trailing keys, so
# existing DB values keep parsing (the key carries no semantics anymore).
run "Ready + legacy suppressed-until key tolerated" Ready \
  '{"qualityVerdict":"PASS hash=abc12345 @2026-06-10T10:42:00Z v1 suppressed-until=2026-06-17T10:42:00Z"}' true
run "Ready + PASS v2 w/ unknown trailing key -> valid (forward-compat)" Ready \
  '{"qualityVerdict":"PASS hash=abc12345 @2026-06-10T10:42:00Z v2 newkey=foo"}' true
run "Ready + fabricated hash w/ trailing key -> invalid" Ready \
  '{"qualityVerdict":"PASS hash=line0612a @2026-06-10T00:00:00Z v1 extra=1"}' false verdict_format

# ---------------------------------------------------------------------------
# In Progress: executor + working directory
# ---------------------------------------------------------------------------
run "In Progress + baseline -> valid" "In Progress" '{}' true
run "In Progress + no executor -> invalid" "In Progress" '{"executor":null}' false required_set
run "In Progress + AI executor w/o WD -> invalid" "In Progress" '{"workingDirectory":""}' false required_for_ai
run "In Progress + human executor w/o WD -> valid" "In Progress" '{"executor":"human","workingDirectory":""}' true

# ---------------------------------------------------------------------------
# Done: Agent Output (with createdAt grandfathering)
# ---------------------------------------------------------------------------
run "Done + AI executor + empty output (new task) -> invalid" Done \
  '{"agentOutput":"","createdAt":"2026-05-01T00:00:00.000Z"}' false required_for_ai_done
run "Done + AI executor + empty output (legacy task) -> valid (warning)" Done \
  '{"agentOutput":"","createdAt":"2026-01-01T00:00:00.000Z"}' true legacy_recommended warnings
run "Done + AI executor + output present -> valid" Done '{"agentOutput":"done, tests pass"}' true
run "Done + human executor + empty output -> valid" Done '{"executor":"human","agentOutput":""}' true

# ---------------------------------------------------------------------------
# Hierarchy + assignee
# ---------------------------------------------------------------------------
run "Ready + subtask that has children -> invalid" Ready \
  '{"parentTaskId":"abc","hasChildren":true}' false hierarchy_2level
run "Ready + multiple assignees -> warning" Ready '{"assigneeCount":2}' true single_assignee warnings

echo "---- $PASS passed, $FAIL failed ----"
[ "$FAIL" -eq 0 ]

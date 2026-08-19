# tmux Parallel Execution Flow (Claude Code only)

Phases 3–6 of the executing-tasks skill. Loaded when the user chooses "tmux parallel execution".

## Phase 3: Prepare Files

Set session name: `SESSION="waggle-$(date +%s)"`
Set session directory: `SDIR="/tmp/waggle/$SESSION"`
Create directory: `mkdir -p "$SDIR"`

For each task `i` (0-indexed), generate two files:

**`$SDIR/task-{i}.md`** — Dispatch prompt (see `dispatch-prompt.md` in this directory)

**`$SDIR/task-{i}.sh`** — Launcher script:

```bash
#!/bin/bash
set -euo pipefail
TASK_TITLE="<title>"
TASK_ID="<notion-page-id>"
PANE_ID="$TMUX_PANE"
SDIR="<session-dir>"
IDX="<i>"
PERMISSION_MODE="<selected-permission-mode>"
unset CLAUDECODE

# Crash fallback
trap 'tmux select-pane -t "$PANE_ID" -T "CRASHED: $TASK_TITLE"; \
  printf "{\"task_id\":\"%s\",\"status\":\"crashed\"}\n" "$TASK_ID" \
  > "$SDIR/task-$IDX.status.json"' EXIT

# Working Directory validation
if [ ! -d "<working-directory>" ]; then
  tmux select-pane -t "$PANE_ID" -T "ERROR: $TASK_TITLE (no workdir)"
  printf "{\"task_id\":\"%s\",\"status\":\"error\",\"message\":\"Working directory not found\"}\n" \
    "$TASK_ID" > "$SDIR/task-$IDX.status.json"
  trap - EXIT; exit 1
fi

cd "<working-directory>"

# Branch checkout (only if Branch field is set)
# if [ -n "<branch>" ]; then
#   git checkout "<branch>" 2>/dev/null || git checkout -b "<branch>"
# fi

# Execute task (Interactive mode: TUI is displayed in real time)
PROMPT=$(cat "$SDIR/task-$IDX.md")
tmux pipe-pane -t "$PANE_ID" -o "cat >> $SDIR/task-$IDX.log"

claude --permission-mode "$PERMISSION_MODE" "$PROMPT"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  tmux select-pane -t "$PANE_ID" -T "ERROR($EXIT_CODE): $TASK_TITLE"
  printf "{\"task_id\":\"%s\",\"status\":\"error\",\"exit_code\":%d}\n" \
    "$TASK_ID" "$EXIT_CODE" > "$SDIR/task-$IDX.status.json"
else
  tmux select-pane -t "$PANE_ID" -T "DONE: $TASK_TITLE"
  printf "{\"task_id\":\"%s\",\"status\":\"done\"}\n" \
    "$TASK_ID" > "$SDIR/task-$IDX.status.json"
fi

trap - EXIT
```

## Phase 4: Atomic Claim (Notion Update)

**After all files are generated, before tmux launch**, update Notion for each task:
- Status → "In Progress"
- Dispatched At → current time in ISO 8601

If a claim fails for a task, exclude it from the batch and revert Status to "Ready".

Session Reference is written in Phase 5 after pane creation succeeds.

## Phase 5: tmux Session + Pane Creation

Launch tmux using the script:

```bash
SCRIPT=scripts/launch-tmux.sh; SKILL_DIR="${CLAUDE_SKILL_DIR}"
if [ ! -d "$SKILL_DIR" ]; then _S="${PWD%%/mnt/*}"; _R="$_S/mnt/.remote-plugins"
  case "$SKILL_DIR" in */plugin_*) _P="plugin_${SKILL_DIR#*/plugin_}"; SKILL_DIR="$_R/$_P"
    if [ ! -f "$SKILL_DIR/$SCRIPT" ]; then _M=$(find "$_R/${_P%%/*}" -path "*/$SCRIPT" 2>/dev/null)
      [ "$(printf %s "$_M" | grep -c .)" = 1 ] && SKILL_DIR="${_M%/$SCRIPT}"; fi ;;
  esac
fi
[ -f "$SKILL_DIR/$SCRIPT" ] || { echo "waggle: skill directory unresolved; $SCRIPT not found. tmux session not launched." >&2; exit 1; }
bash "$SKILL_DIR/$SCRIPT" "$SDIR" "$SESSION" "$N"
```

The leading eight lines resolve the skill directory for the runtime the shell is
actually running in; see the `provider-contract` skill for why each clause is required.
Resolution and invocation must stay in the same Bash call. If the block reports the
directory unresolved, treat it exactly like "tmux not installed" and fall back to
sequential Agent tool execution.

If the script exits with code 1 (tmux not installed), fall back to sequential Agent tool execution.

After pane creation, if running outside tmux, try to auto-open a terminal window:

```bash
# Auto-open terminal only when running outside tmux
if [ -z "${TMUX:-}" ]; then
  # waggle-ci: fail-open — best-effort convenience step, never a check or a write
  SCRIPT=scripts/open-terminal.sh; SKILL_DIR="${CLAUDE_SKILL_DIR}"
  if [ ! -d "$SKILL_DIR" ]; then _S="${PWD%%/mnt/*}"; _R="$_S/mnt/.remote-plugins"
    case "$SKILL_DIR" in */plugin_*) _P="plugin_${SKILL_DIR#*/plugin_}"; SKILL_DIR="$_R/$_P"
      if [ ! -f "$SKILL_DIR/$SCRIPT" ]; then _M=$(find "$_R/${_P%%/*}" -path "*/$SCRIPT" 2>/dev/null)
        [ "$(printf %s "$_M" | grep -c .)" = 1 ] && SKILL_DIR="${_M%/$SCRIPT}"; fi ;;
    esac
  fi
  [ -f "$SKILL_DIR/$SCRIPT" ] && bash "$SKILL_DIR/$SCRIPT" "$SESSION" || true
fi
```

Auto-opening a terminal is best-effort, so this site fails open rather than closed: an
unresolved skill directory skips the convenience step and leaves the tmux session
running for the user to attach manually. Every site that performs a *check* or a
*write* must fail closed instead — see the `provider-contract` skill.

After each pane is created successfully, set pane titles and write Session Reference to Notion:
- Inside tmux: `tmux select-pane -t "$CURRENT:$SESSION:0.$i" -T "<task-i-title>"`
- Outside tmux: `tmux select-pane -t "$SESSION:0.$i" -T "<task-i-title>"`
- Session Reference format: `<session-name>:0.<pane-index>` (e.g., `waggle-1741305052:0.2`)

## Phase 6: Report & Fire-and-Forget

Report to the user:

```
Running N tasks in parallel:
- waggle-<ts>:0.0 → Feature Login
- waggle-<ts>:0.1 → API Tests
- waggle-<ts>:0.2 → Fix Bug #42

Monitoring:
  tmux attach -t waggle-<ts>         (from outside tmux)
  tmux switch-client -t waggle-<ts>  (from inside tmux)

Check completion status: /managing-tasks (my tasks)  or  ls /tmp/waggle/waggle-<ts>/
```

The Orchestrator exits here. Each Sub-Agent runs independently and handles its own completion.

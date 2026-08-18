#!/bin/bash
set -euo pipefail

# Usage: launch-tmux.sh <session-dir> <session-name> <task-count>
SDIR="${1:?Usage: launch-tmux.sh <session-dir> <session-name> <task-count>}"
SESSION="${2:?}"
N="${3:?}"

if ! command -v tmux &>/dev/null; then
  echo "tmux is not installed. Falling back to sequential execution." >&2
  exit 1
fi

if [ -n "${TMUX:-}" ]; then
  # Inside tmux: create a new window in the current session
  CURRENT=$(tmux display-message -p '#S')
  tmux new-window -t "$CURRENT" -n "$SESSION"
  tmux send-keys -t "$CURRENT:$SESSION" "bash $SDIR/task-0.sh" Enter
  for i in $(seq 1 $((N-1))); do
    tmux split-window -t "$CURRENT:$SESSION" "bash $SDIR/task-$i.sh"
  done
  tmux select-layout -t "$CURRENT:$SESSION" tiled
  tmux set-option -t "$CURRENT:$SESSION" -w pane-border-status top
else
  # Outside tmux: create a new detached session
  tmux new-session -d -s "$SESSION" -x 220 -y 50 "bash $SDIR/task-0.sh"
  for i in $(seq 1 $((N-1))); do
    tmux split-window -t "$SESSION" "bash $SDIR/task-$i.sh"
  done
  tmux select-layout -t "$SESSION" tiled
  tmux set-option -t "$SESSION" pane-border-status top
  tmux set-option -t "$SESSION" remain-on-exit on
fi

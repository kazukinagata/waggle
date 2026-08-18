#!/bin/bash
# Usage: open-terminal.sh <session-name>
# Exit codes: 0 = opened, 1 = failed (caller should show manual instructions)
SESSION="${1:?}"

# --- Platform detection ---
detect_platform() {
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then
    echo "wsl"
  elif [ "$(uname -s)" = "Darwin" ]; then
    echo "macos"
  elif [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    echo "linux-desktop"
  else
    echo "unknown"
  fi
}

PLATFORM=$(detect_platform)

case "$PLATFORM" in
  wsl)
    if command -v wt.exe &>/dev/null; then
      wt.exe new-tab bash -c "tmux attach -t $SESSION"
    else
      exit 1
    fi
    ;;
  macos)
    osascript -e "tell app \"Terminal\" to do script \"tmux attach -t $SESSION\"" 2>/dev/null || exit 1
    ;;
  linux-desktop)
    if command -v gnome-terminal &>/dev/null; then
      gnome-terminal -- bash -c "tmux attach -t $SESSION; exec bash"
    elif command -v konsole &>/dev/null; then
      konsole -e bash -c "tmux attach -t $SESSION; exec bash"
    elif command -v xfce4-terminal &>/dev/null; then
      xfce4-terminal -e "bash -c 'tmux attach -t $SESSION; exec bash'"
    elif command -v xterm &>/dev/null; then
      xterm -e bash -c "tmux attach -t $SESSION; exec bash"
    else
      exit 1
    fi
    ;;
  *)
    exit 1
    ;;
esac

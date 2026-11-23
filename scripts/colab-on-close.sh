#!/usr/bin/env bash
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/miniconda3/bin:$HOME/anaconda3/bin:/usr/local/bin:/usr/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE_FILE="$HOME/.config/colab-cli/vscode-runner-state.env"
SESSIONS_FILE="$HOME/.config/colab-cli/sessions.json"
LOCK_DIR="/tmp/colab-runner-on-close-${UID:-$(id -u)}.lock"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

has_active_sessions() {
  if [[ -f "$STATE_FILE" ]]; then
    local active_vms=""
    # shellcheck disable=SC1090
    source "$STATE_FILE" 2>/dev/null || true
    active_vms="${COLAB_RUNNER_ACTIVE_VMS:-0}"
    if [[ "$active_vms" =~ ^[0-9]+$ && "$active_vms" -gt 0 ]]; then
      return 0
    fi
  fi

  if [[ -f "$SESSIONS_FILE" ]]; then
    local trimmed
    trimmed="$(tr -d '[:space:]' < "$SESSIONS_FILE" 2>/dev/null || echo "{}")"
    if [[ -n "$trimmed" && "$trimmed" != "{}" && "$trimmed" != "[]" ]]; then
      return 0
    fi
  fi

  return 1
}

send_desktop_popup() {
  local urgency="$1" title="$2" body="$3"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN POPUP][$urgency] $title — $body"
    return 0
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u "$urgency" -a "Colab Runner" "$title" "$body" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${body//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 || true
  fi
}

if ! has_active_sessions; then
  exit 0
fi

# Atomic mkdir lock to prevent duplicate notifications/stops when SIGHUP + VS Code deactivate fire together
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

send_desktop_popup \
  "critical" \
  "Colab Sessions Still Running!" \
  "Stopping all active Colab VMs immediately so your credits / session hours don't keep burning."

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Would run: $SCRIPT_DIR/colab-switch.sh --stop"
  exit 0
fi

"$SCRIPT_DIR/colab-switch.sh" --stop >/dev/null 2>&1 || true

send_desktop_popup \
  "normal" \
  "Colab VMs Stopped" \
  "All active Colab sessions were terminated to protect your credits."

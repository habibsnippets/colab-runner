#!/usr/bin/env bash
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/miniconda3/bin:$HOME/anaconda3/bin:/usr/local/bin:/usr/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
COLAB_BIN="$(command -v colab || echo "$HOME/.local/bin/colab")"
COLAB_PY="$HOME/.local/share/uv/tools/google-colab-cli/bin/python3"
STATE_DIR="$HOME/.config/colab-cli"
STATE_FILE="$STATE_DIR/vscode-runner-state.env"
LEGACY_TOKEN="$STATE_DIR/token.json"

run_colab() {
  if [[ -d "$SCRIPT_DIR/py_ipv4" ]]; then
    PYTHONPATH="$SCRIPT_DIR/py_ipv4${PYTHONPATH:+:$PYTHONPATH}" "$COLAB_BIN" "$@"
  else
    "$COLAB_BIN" "$@"
  fi
}

run_tier_info() {
  local py_bin="python3"
  if [[ -f "$COLAB_BIN" ]]; then
    local shebang_py
    shebang_py="$(head -n 1 "$COLAB_BIN" 2>/dev/null | sed 's/^#!//' | awk '{print $1}')"
    if [[ -n "$shebang_py" && -x "$shebang_py" ]]; then
      py_bin="$shebang_py"
    fi
  fi
  if [[ -d "$SCRIPT_DIR/py_ipv4" ]]; then
    PYTHONPATH="$SCRIPT_DIR/py_ipv4${PYTHONPATH:+:$PYTHONPATH}" "$py_bin" "$SCRIPT_DIR/colab-tier-info.py" </dev/null 2>/dev/null || true
  else
    "$py_bin" "$SCRIPT_DIR/colab-tier-info.py" </dev/null 2>/dev/null || true
  fi
}

BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
DIM="\033[2m"
RESET="\033[0m"

INVOKED_NAME="$(basename "$0")"
ACTION=""
SWITCH_ACCOUNT=0
CHECK_ONLY=0

case "$INVOKED_NAME" in
  colab-login) ACTION="login" ;;
  colab-logout) ACTION="logout" ;;
  colab-status) ACTION="status" ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    login|logout|status) ACTION="$1"; shift ;;
    --switch|-s) SWITCH_ACCOUNT=1; shift ;;
    --check|-c) CHECK_ONLY=1; shift ;;
    -h|--help)
      echo "Usage:"
      echo "  colab-login [--switch] [--check]   Sign in or switch Google Colab account in terminal"
      echo "  colab-logout                       Sign out and clear Colab CLI credentials"
      echo "  colab-status                       Show account, credits/session hours, active VMs & sync VS Code"
      exit 0
      ;;
    *) echo -e "${RED}[Colab Auth] Unknown option: $1${RESET}" >&2; exit 2 ;;
  esac
done

[[ -z "$ACTION" ]] && ACTION="status"

clear_credentials() {
  rm -f "$LEGACY_TOKEN" 2>/dev/null || true
  local py_bin="python3"
  if [[ -f "$COLAB_BIN" ]]; then
    local shebang_py
    shebang_py="$(head -n 1 "$COLAB_BIN" 2>/dev/null | sed 's/^#!//' | awk '{print $1}')"
    if [[ -n "$shebang_py" && -x "$shebang_py" ]]; then
      py_bin="$shebang_py"
    fi
  elif [[ -x "$COLAB_PY" ]]; then
    py_bin="$COLAB_PY"
  fi
  "$py_bin" - << 'EOF' 2>/dev/null || true
try:
    import keyring
    keyring.delete_password("google-colab-cli", "oauth_token")
except Exception:
    pass
EOF
}

format_remaining_time() {
  local start_ep="$1" max_s="$2"
  local now rem hrs mins
  now="$(date +%s)"
  rem=$(( max_s - (now - start_ep) ))
  [[ "$rem" -lt 0 ]] && rem=0
  hrs=$(( rem / 3600 ))
  mins=$(( (rem % 3600) / 60 ))
  if [[ "$hrs" -gt 0 ]]; then
    echo "${hrs}h ${mins}m left"
  else
    echo "${mins}m left"
  fi
}

write_state_env() {
  local email="$1"
  local tier="$2"
  local balance="$3"
  local rate="$4"
  local active_vms="$5"
  local eligible_gpus="$6"
  local eligible_tpus="$7"
  local sess_epoch="$8"

  mkdir -p "$STATE_DIR"

  local mode="local"
  local hardware="cpu"
  local local_device="cpu"
  local high_mem="0"
  local hw_label="LOCAL CPU"
  if [[ -f "$STATE_FILE" ]]; then
    # Preserve currently selected execution mode & hardware label
    # shellcheck disable=SC1090
    source "$STATE_FILE" 2>/dev/null || true
    mode="${COLAB_RUNNER_MODE:-local}"
    hardware="${COLAB_RUNNER_HARDWARE:-cpu}"
    local_device="${COLAB_RUNNER_LOCAL_DEVICE:-cpu}"
    high_mem="${COLAB_RUNNER_HIGH_MEM:-0}"
    hw_label="${COLAB_RUNNER_HW_LABEL:-LOCAL CPU}"
  fi

  local max_secs="14400"
  [[ "$hardware" == "cpu" ]] && max_secs="43200"
  [[ ! "$active_vms" =~ ^[0-9]+$ || "$active_vms" -eq 0 ]] && sess_epoch="0"

  cat > "$STATE_FILE" <<EOF
COLAB_RUNNER_MODE='${mode}'
COLAB_RUNNER_HARDWARE='${hardware}'
COLAB_RUNNER_LOCAL_DEVICE='${local_device}'
COLAB_RUNNER_HIGH_MEM='${high_mem}'
COLAB_RUNNER_HW_LABEL='${hw_label}'
COLAB_RUNNER_EMAIL='${email}'
COLAB_RUNNER_TIER='${tier}'
COLAB_RUNNER_CREDITS='${balance} CU'
COLAB_RUNNER_RATE='${rate}'
COLAB_RUNNER_ACTIVE_VMS='${active_vms}'
COLAB_RUNNER_ELIGIBLE_GPUS='${eligible_gpus}'
COLAB_RUNNER_ELIGIBLE_TPUS='${eligible_tpus}'
COLAB_RUNNER_SESSION_START_EPOCH='${sess_epoch}'
COLAB_RUNNER_SESSION_MAX_SECS='${max_secs}'
EOF
}

fetch_and_sync_status() {
  EMAIL=""
  TIER="free"
  BALANCE="0.00"
  RATE="0.00/hr"
  ACTIVE_VMS="0"
  ELIGIBLE_GPUS="T4"
  ELIGIBLE_TPUS=""
  SESSION_START_EPOCH="0"
  SESSIONS_OUT=""

  if [[ ! -x "$COLAB_BIN" ]] && ! command -v "$COLAB_BIN" >/dev/null 2>&1 && [[ "${COLAB_RUNNER_SIMULATE_FREE:-0}" != "1" ]]; then
    echo -e "${RED}[Colab Auth] 'colab' CLI not found.${RESET}" >&2
    return 1
  fi

  local info_out
  info_out="$(run_tier_info)"
  while IFS='=' read -r k v; do
    case "$k" in
      EMAIL) EMAIL="$v" ;;
      TIER) TIER="$v" ;;
      BALANCE) BALANCE="$v" ;;
      RATE) RATE="$v" ;;
      ACTIVE_VMS) ACTIVE_VMS="$v" ;;
      ELIGIBLE_GPUS) ELIGIBLE_GPUS="$v" ;;
      ELIGIBLE_TPUS) ELIGIBLE_TPUS="$v" ;;
      SESSION_START_EPOCH) SESSION_START_EPOCH="$v" ;;
    esac
  done <<< "$info_out"

  if [[ -n "$EMAIL" ]] && [[ "${COLAB_RUNNER_SIMULATE_FREE:-0}" != "1" ]]; then
    SESSIONS_OUT="$(run_colab sessions </dev/null 2>/dev/null || true)"
  fi

  write_state_env "$EMAIL" "$TIER" "$BALANCE" "$RATE" "$ACTIVE_VMS" "$ELIGIBLE_GPUS" "$ELIGIBLE_TPUS" "$SESSION_START_EPOCH"
}

quota_line_for_display() {
  if [[ "$TIER" == "paid" ]]; then
    echo "${BALANCE} compute units | Burn Rate: ${RATE} | Active VMs: ${ACTIVE_VMS}"
    return
  fi
  local hardware="cpu"
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" 2>/dev/null || true
    hardware="${COLAB_RUNNER_HARDWARE:-cpu}"
  fi
  local max_s="14400" limit_label="4h max for T4 GPU"
  if [[ "$hardware" == "cpu" ]]; then
    max_s="43200"
    limit_label="12h max for CPU"
  fi
  if [[ "$ACTIVE_VMS" =~ ^[0-9]+$ && "$ACTIVE_VMS" -gt 0 && "$SESSION_START_EPOCH" =~ ^[0-9]+$ && "$SESSION_START_EPOCH" -gt 0 ]]; then
    echo "Free Tier — $(format_remaining_time "$SESSION_START_EPOCH" "$max_s") (${limit_label}) | Active VMs: ${ACTIVE_VMS}"
  else
    echo "Free Tier (4h T4 GPU / 12h CPU session limit) | Active VMs: ${ACTIVE_VMS}"
  fi
}

if [[ "$ACTION" == "logout" ]]; then
  clear_credentials
  write_state_env "" "free" "0.00" "0.00/hr" "0" "T4" "" "0"
  echo ""
  echo -e "${YELLOW}======================================================================${RESET}"
  echo -e " ${YELLOW}COLAB ACCOUNT SIGNED OUT${RESET}"
  echo -e " ${DIM}Cleared keyring and legacy token credentials.${RESET}"
  echo -e " ${CYAN}To sign back in anytime, run:${RESET} ${BOLD}colab-login${RESET}"
  echo -e "${YELLOW}======================================================================${RESET}"
  echo ""
  exit 0
fi

if [[ "$ACTION" == "status" ]]; then
  fetch_and_sync_status
  echo ""
  echo -e "${CYAN}======================================================================${RESET}"
  if [[ -n "$EMAIL" ]]; then
    echo -e " ${GREEN}COLAB ACCOUNT STATUS :${RESET} ${BOLD}SIGNED IN (${TIER^^} TIER)${RESET}"
    echo -e " ${CYAN}GOOGLE ACCOUNT       :${RESET} ${EMAIL}"
    if [[ "$TIER" == "paid" ]]; then
      echo -e " ${YELLOW}REMAINING CREDITS    :${RESET} $(quota_line_for_display)"
    else
      echo -e " ${YELLOW}SESSION QUOTA        :${RESET} $(quota_line_for_display)"
    fi
    echo -e " ${CYAN}ELIGIBLE RUNTIMES    :${RESET} Local CPU, Local GPU, Colab CPU${ELIGIBLE_GPUS:+, ${ELIGIBLE_GPUS}}${ELIGIBLE_TPUS:+, ${ELIGIBLE_TPUS}}"
    if [[ -n "$SESSIONS_OUT" ]]; then
      echo -e " ${CYAN}SESSIONS             :${RESET}"
      while IFS= read -r line; do
        [[ -n "$line" ]] && echo "   $line"
      done <<< "$SESSIONS_OUT"
    fi
  else
    echo -e " ${RED}COLAB ACCOUNT STATUS :${RESET} ${BOLD}SIGNED OUT${RESET}"
    echo -e " ${CYAN}Run ${BOLD}/login${RESET}${CYAN} in this terminal to connect your Google account.${RESET}"
  fi
  echo -e "${CYAN}======================================================================${RESET}"
  echo ""
  [[ -n "$EMAIL" ]] && exit 0 || exit 1
fi

# ACTION == "login"
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  fetch_and_sync_status
  if [[ -n "$EMAIL" ]]; then
    echo -e "${GREEN}[Colab Auth]${RESET} Signed in as ${BOLD}${EMAIL}${RESET} | ${YELLOW}$(quota_line_for_display)${RESET}"
    exit 0
  else
    echo -e "${RED}[Colab Auth]${RESET} Not signed in. Run ${BOLD}/login${RESET} to authenticate."
    exit 1
  fi
fi

if [[ "$SWITCH_ACCOUNT" -eq 1 ]]; then
  echo -e "${YELLOW}[Colab Auth] Clearing existing Colab credentials to switch account...${RESET}"
  clear_credentials
  write_state_env "" "free" "0.00" "0.00/hr" "0" "T4" "" "0"
else
  fetch_and_sync_status
  if [[ -n "$EMAIL" ]]; then
    echo ""
    echo -e "${GREEN}[Colab Auth] Already signed in as ${BOLD}${EMAIL}${RESET} ($(quota_line_for_display))."
    read -r -p "Switch to a different Google account? [y/N]: " reply
    case "$reply" in
      [yY]|[yY][eE][sS])
        clear_credentials
        write_state_env "" "free" "0.00" "0.00/hr" "0" "T4" "" "0"
        ;;
      *)
        echo -e "${CYAN}[Colab Auth] Keeping active account (${EMAIL}).${RESET}"
        exit 0
        ;;
    esac
  fi
fi

echo ""
echo -e "${CYAN}======================================================================${RESET}"
echo -e " ${BOLD}GOOGLE COLAB TERMINAL SIGN-IN${RESET}"
echo -e " 1. Open the Google authorization URL printed below in your browser."
echo -e " 2. Approve access and copy the authorization code."
echo -e " 3. Paste the code here and press Enter."
echo -e "${CYAN}======================================================================${RESET}"
echo ""

if ! run_colab --auth=oauth2 whoami; then
  echo -e "${RED}[Colab Auth] Sign-in was not completed.${RESET}" >&2
  fetch_and_sync_status
  exit 1
fi

fetch_and_sync_status
if [[ -n "$EMAIL" ]]; then
  echo ""
  echo -e "${GREEN}======================================================================${RESET}"
  echo -e " ${GREEN}SIGN-IN SUCCESSFUL (${TIER^^} TIER)${RESET}"
  echo -e " ${CYAN}GOOGLE ACCOUNT    :${RESET} ${BOLD}${EMAIL}${RESET}"
  echo -e " ${YELLOW}QUOTA             :${RESET} $(quota_line_for_display)"
  echo -e " ${CYAN}ELIGIBLE RUNTIMES :${RESET} Local CPU, Local GPU, Colab CPU${ELIGIBLE_GPUS:+, ${ELIGIBLE_GPUS}}${ELIGIBLE_TPUS:+, ${ELIGIBLE_TPUS}}"
  echo -e "${GREEN}======================================================================${RESET}"
  echo ""
  exit 0
else
  echo -e "${RED}[Colab Auth] Could not verify signed-in session.${RESET}" >&2
  exit 1
fi

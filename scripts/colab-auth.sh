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

BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
MAGENTA="\033[1;35m"
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
      echo "  colab-status                       Show account, credits, active VMs & sync VS Code"
      exit 0
      ;;
    *) echo -e "${RED}[Colab Auth] Unknown option: $1${RESET}" >&2; exit 2 ;;
  esac
done

[[ -z "$ACTION" ]] && ACTION="status"

clear_credentials() {
  rm -f "$LEGACY_TOKEN" 2>/dev/null || true
  local py_bin="python3"
  [[ -x "$COLAB_PY" ]] && py_bin="$COLAB_PY"
  "$py_bin" - << 'EOF' 2>/dev/null || true
try:
    import keyring
    keyring.delete_password("google-colab-cli", "oauth_token")
except Exception:
    pass
EOF
}

write_state_env() {
  local email="$1"
  local balance="$2"
  local rate="$3"
  local active_vms="$4"

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

  local short_credits="${balance/ compute units/ CU}"
  [[ -z "$short_credits" || "$short_credits" == "N/A" ]] && short_credits="?"
  [[ -z "$rate" ]] && rate="0.00/hr"
  [[ -z "$active_vms" ]] && active_vms="0"

  cat > "$STATE_FILE" <<EOF
COLAB_RUNNER_MODE='${mode}'
COLAB_RUNNER_HARDWARE='${hardware}'
COLAB_RUNNER_LOCAL_DEVICE='${local_device}'
COLAB_RUNNER_HIGH_MEM='${high_mem}'
COLAB_RUNNER_HW_LABEL='${hw_label}'
COLAB_RUNNER_EMAIL='${email}'
COLAB_RUNNER_CREDITS='${short_credits}'
COLAB_RUNNER_RATE='${rate}'
COLAB_RUNNER_ACTIVE_VMS='${active_vms}'
EOF
}

fetch_and_sync_status() {
  EMAIL=""
  BALANCE="N/A"
  RATE="0.00/hr"
  ACTIVE_VMS="0"
  SESSIONS_OUT=""

  if [[ ! -x "$COLAB_BIN" ]] && ! command -v "$COLAB_BIN" >/dev/null 2>&1; then
    echo -e "${RED}[Colab Auth] 'colab' CLI not found.${RESET}" >&2
    return 1
  fi

  local whoami_out usage_out
  whoami_out="$(run_colab whoami </dev/null 2>/dev/null || true)"
  EMAIL="$(echo "$whoami_out" | awk -F': *' '/^Email:/ {print $2; exit}')"

  if [[ -n "$EMAIL" ]]; then
    usage_out="$(run_colab usage </dev/null 2>/dev/null || true)"
    SESSIONS_OUT="$(run_colab sessions </dev/null 2>/dev/null || true)"
    BALANCE="$(echo "$usage_out" | awk -F': *' '/^Current balance:/ {print $2; exit}')"
    RATE="$(echo "$usage_out" | awk -F': *' '/^Usage rate:/ {print $2; exit}')"
    ACTIVE_VMS="$(echo "$usage_out" | awk -F': *' '/^Active assignments:/ {print $2; exit}')"
    [[ -z "$BALANCE" ]] && BALANCE="?"
    [[ -z "$RATE" ]] && RATE="0.00/hr"
    [[ -z "$ACTIVE_VMS" ]] && ACTIVE_VMS="0"
  fi

  write_state_env "$EMAIL" "$BALANCE" "$RATE" "$ACTIVE_VMS"
}

if [[ "$ACTION" == "logout" ]]; then
  clear_credentials
  write_state_env "" "N/A" "0.00/hr" "0"
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
    echo -e " ${GREEN}COLAB ACCOUNT STATUS :${RESET} ${BOLD}SIGNED IN${RESET}"
    echo -e " ${CYAN}GOOGLE ACCOUNT       :${RESET} ${EMAIL}"
    echo -e " ${YELLOW}REMAINING CREDITS    :${RESET} ${BALANCE} | Burn Rate: ${RATE} | Active VMs: ${ACTIVE_VMS}"
    if [[ -n "$SESSIONS_OUT" ]]; then
      echo -e " ${CYAN}SESSIONS             :${RESET}"
      while IFS= read -r line; do
        [[ -n "$line" ]] && echo "   $line"
      done <<< "$SESSIONS_OUT"
    fi
  else
    echo -e " ${RED}COLAB ACCOUNT STATUS :${RESET} ${BOLD}SIGNED OUT${RESET}"
    echo -e " ${CYAN}Run ${BOLD}colab-login${RESET}${CYAN} in this terminal to connect your Google account.${RESET}"
  fi
  echo -e "${CYAN}======================================================================${RESET}"
  echo ""
  [[ -n "$EMAIL" ]] && exit 0 || exit 1
fi

# ACTION == "login"
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  fetch_and_sync_status
  if [[ -n "$EMAIL" ]]; then
    echo -e "${GREEN}[Colab Auth]${RESET} Signed in as ${BOLD}${EMAIL}${RESET} | Credits: ${YELLOW}${BALANCE}${RESET} (${RATE})"
    exit 0
  else
    echo -e "${RED}[Colab Auth]${RESET} Not signed in. Run ${BOLD}colab-login${RESET} to authenticate."
    exit 1
  fi
fi

if [[ "$SWITCH_ACCOUNT" -eq 1 ]]; then
  echo -e "${YELLOW}[Colab Auth] Clearing existing Colab credentials to switch account...${RESET}"
  clear_credentials
  write_state_env "" "N/A" "0.00/hr" "0"
else
  # Check if already signed in
  fetch_and_sync_status
  if [[ -n "$EMAIL" ]]; then
    echo ""
    echo -e "${GREEN}[Colab Auth] Already signed in as ${BOLD}${EMAIL}${RESET} (${BALANCE})."
    read -r -p "Switch to a different Google account? [y/N]: " reply
    case "$reply" in
      [yY]|[yY][eE][sS])
        clear_credentials
        write_state_env "" "N/A" "0.00/hr" "0"
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
  echo -e " ${GREEN}SIGN-IN SUCCESSFUL${RESET}"
  echo -e " ${CYAN}GOOGLE ACCOUNT    :${RESET} ${BOLD}${EMAIL}${RESET}"
  echo -e " ${YELLOW}REMAINING CREDITS :${RESET} ${BALANCE} | Burn Rate: ${RATE} | Active VMs: ${ACTIVE_VMS}"
  echo -e "${GREEN}======================================================================${RESET}"
  echo ""
  exit 0
else
  echo -e "${RED}[Colab Auth] Could not verify signed-in session.${RESET}" >&2
  exit 1
fi

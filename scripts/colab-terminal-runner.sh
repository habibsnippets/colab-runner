#!/usr/bin/env bash
set -uo pipefail

export COLAB_RUNNER_INTERNAL=1
export PATH="$HOME/.local/bin:$HOME/miniconda3/bin:$HOME/anaconda3/bin:/usr/local/bin:/usr/bin:$PATH"

MODE="local"
HARDWARE="cpu"
FILE_PATH=""
PYTHON_BIN="python3"
COLAB_BIN="colab"
EXEC_TIMEOUT="3600"
HIGH_MEM=0
AUTO_STOP_PREV=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-local}"; shift 2 ;;
    --hardware) HARDWARE="${2:-cpu}"; shift 2 ;;
    --file) FILE_PATH="${2:-}"; shift 2 ;;
    --python) PYTHON_BIN="${2:-python3}"; shift 2 ;;
    --colab) COLAB_BIN="${2:-colab}"; shift 2 ;;
    --timeout) EXEC_TIMEOUT="${2:-3600}"; shift 2 ;;
    --high-mem) HIGH_MEM=1; shift ;;
    --auto-stop-prev) AUTO_STOP_PREV=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
MAGENTA="\033[1;35m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
DIM="\033[2m"
RESET="\033[0m"

if [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]]; then
  echo -e "${RED}[Colab Runner] File not found: ${FILE_PATH:-<empty>}${RESET}" >&2
  exit 1
fi

EXT="${FILE_PATH##*.}"
EXT_LOWER="$(echo "$EXT" | tr '[:upper:]' '[:lower:]')"
if [[ "$EXT_LOWER" != "py" && "$EXT_LOWER" != "ipynb" ]]; then
  echo -e "${RED}[Colab Runner] Unsupported file type: .$EXT_LOWER (expected .py or .ipynb)${RESET}" >&2
  exit 1
fi

fetch_colab_info() {
  COLAB_EMAIL="Not signed in"
  COLAB_RAW_EMAIL=""
  COLAB_BALANCE="N/A"
  COLAB_RATE="N/A"
  COLAB_ACTIVE="0"

  if command -v "$COLAB_BIN" >/dev/null 2>&1; then
    local whoami_out usage_out
    whoami_out="$("$COLAB_BIN" whoami </dev/null 2>/dev/null || true)"
    usage_out="$("$COLAB_BIN" usage </dev/null 2>/dev/null || true)"

    local email balance rate active
    email="$(echo "$whoami_out" | awk -F': *' '/^Email:/ {print $2; exit}')"
    balance="$(echo "$usage_out" | awk -F': *' '/^Current balance:/ {print $2; exit}')"
    rate="$(echo "$usage_out" | awk -F': *' '/^Usage rate:/ {print $2; exit}')"
    active="$(echo "$usage_out" | awk -F': *' '/^Active assignments:/ {print $2; exit}')"

    if [[ -n "$email" ]]; then
      COLAB_EMAIL="$email"
      COLAB_RAW_EMAIL="$email"
    fi
    [[ -n "$balance" ]] && COLAB_BALANCE="$balance"
    [[ -n "$rate" ]] && COLAB_RATE="$rate"
    [[ -n "$active" ]] && COLAB_ACTIVE="$active"
  fi
}

write_runner_state() {
  local state_dir="$HOME/.config/colab-cli"
  local state_file="$state_dir/vscode-runner-state.env"
  mkdir -p "$state_dir"

  local hw_label="LOCAL"
  if [[ "$MODE" == "colab" ]]; then
    hw_label="$(format_hardware_label "$HARDWARE")"
  fi
  local short_credits="${COLAB_BALANCE/ compute units/ CU}"
  [[ "$short_credits" == "N/A" ]] && short_credits="?"

  cat > "$state_file" <<EOF
COLAB_RUNNER_MODE='${MODE}'
COLAB_RUNNER_HARDWARE='${HARDWARE}'
COLAB_RUNNER_HIGH_MEM='${HIGH_MEM}'
COLAB_RUNNER_HW_LABEL='${hw_label}'
COLAB_RUNNER_EMAIL='${COLAB_RAW_EMAIL}'
COLAB_RUNNER_CREDITS='${short_credits}'
COLAB_RUNNER_RATE='${COLAB_RATE}'
COLAB_RUNNER_ACTIVE_VMS='${COLAB_ACTIVE}'
EOF
}

format_hardware_label() {
  local hw="$1"
  local label=""
  case "$hw" in
    cpu) label="COLAB CPU" ;;
    gpu:*) label="COLAB GPU — ${hw#gpu:}" ;;
    tpu:*) label="COLAB TPU — ${hw#tpu:}" ;;
    *) label="COLAB ($hw)" ;;
  esac
  if [[ "$HIGH_MEM" -eq 1 && "$hw" != "gpu:L4" && "$hw" != tpu:* ]]; then
    label="$label (High-RAM)"
  fi
  echo "$label"
}

session_name_for_hw() {
  local hw="$1"
  local slug
  slug="$(echo "$hw" | tr '[:upper:]:' '[:lower:]-')"
  if [[ "$HIGH_MEM" -eq 1 && "$hw" != "gpu:L4" && "$hw" != tpu:* ]]; then
    echo "vscode-${slug}-himem"
  else
    echo "vscode-${slug}"
  fi
}

detect_local_hardware() {
  local cpu_model cores ram_gb gpu_info
  cpu_model="$(lscpu 2>/dev/null | awk -F': *' '/^Model name:/ {print $2; exit}')"
  [[ -z "$cpu_model" ]] && cpu_model="$(uname -m)"
  cores="$(nproc 2>/dev/null || echo "?")"
  ram_gb="$(free -h 2>/dev/null | awk '/^Mem:/ {print $2; exit}')"
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
    gpu_info="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd ', ' -)"
  else
    gpu_info=""
  fi
  if [[ -n "$gpu_info" ]]; then
    echo "${cpu_model} (${cores} cores, ${ram_gb} RAM) | GPU: ${gpu_info}"
  else
    echo "${cpu_model} (${cores} cores, ${ram_gb} RAM) | No Local NVIDIA GPU"
  fi
}

fetch_colab_info
write_runner_state

if [[ "$MODE" == "local" ]]; then
  LOCAL_HW="$(detect_local_hardware)"
  PY_VER="$("$PYTHON_BIN" --version 2>&1 || echo "Python unavailable")"
  echo ""
  echo -e "${CYAN}======================================================================${RESET}"
  echo -e " ${GREEN}EXECUTION TARGET :${RESET} ${BOLD}LOCAL MACHINE HARDWARE${RESET}"
  echo -e " ${CYAN}LOCAL HARDWARE   :${RESET} ${LOCAL_HW}"
  echo -e " ${CYAN}PYTHON RUNTIME   :${RESET} ${PY_VER} ($(command -v "$PYTHON_BIN" || echo "$PYTHON_BIN"))"
  echo -e " ${YELLOW}COLAB CREDITS    :${RESET} ${COLAB_BALANCE} | Rate: ${COLAB_RATE} | Account: ${COLAB_EMAIL} [Standby]"
  echo -e " ${CYAN}FILE             :${RESET} ${FILE_PATH}"
  echo -e "${CYAN}======================================================================${RESET}"
  echo ""

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${DIM}[Dry Run] Local execution skipped.${RESET}"
    exit 0
  fi

  if [[ "$EXT_LOWER" == "py" ]]; then
    "$PYTHON_BIN" "$FILE_PATH"
    EXIT_CODE=$?
  else
    "$PYTHON_BIN" "$SCRIPT_DIR/local-ipynb-runner.py" "$FILE_PATH"
    EXIT_CODE=$?
  fi

  echo ""
  echo -e "${CYAN}----------------------------------------------------------------------${RESET}"
  echo -e " ${GREEN}Finished (Local Machine)${RESET} | Exit Code: ${EXIT_CODE} | Colab Credits: ${YELLOW}${COLAB_BALANCE}${RESET}"
  echo -e "${CYAN}----------------------------------------------------------------------${RESET}"
  exit "$EXIT_CODE"
fi

# --- Google Colab Execution ---
if ! command -v "$COLAB_BIN" >/dev/null 2>&1; then
  echo -e "${RED}[Colab Runner] 'colab' CLI not found in PATH.${RESET}" >&2
  exit 1
fi

HW_LABEL="$(format_hardware_label "$HARDWARE")"
SESSION_NAME="$(session_name_for_hw "$HARDWARE")"

echo ""
echo -e "${MAGENTA}======================================================================${RESET}"
echo -e " ${MAGENTA}EXECUTION TARGET :${RESET} ${BOLD}GOOGLE COLAB REMOTE VM${RESET}"
echo -e " ${GREEN}SELECTED RUNTIME :${RESET} ${BOLD}${HW_LABEL}${RESET}"
echo -e " ${CYAN}GOOGLE ACCOUNT   :${RESET} ${COLAB_EMAIL}"
echo -e " ${YELLOW}COLAB CREDITS    :${RESET} ${COLAB_BALANCE} | Burn Rate: ${COLAB_RATE} | Active VMs: ${COLAB_ACTIVE}"
echo -e " ${CYAN}SESSION NAME     :${RESET} ${SESSION_NAME}"
echo -e " ${CYAN}FILE             :${RESET} ${FILE_PATH}"
echo -e "${MAGENTA}======================================================================${RESET}"
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo -e "${DIM}[Dry Run] Colab session provisioning & execution skipped.${RESET}"
  exit 0
fi

SESSIONS_OUT="$("$COLAB_BIN" sessions 2>/dev/null || true)"
HAS_TARGET_SESSION=0
OTHER_VSCODE_SESSIONS=()

while IFS= read -r line; do
  if [[ "$line" =~ ^\[([^\]]+)\][[:space:]] ]]; then
    s_name="${BASH_REMATCH[1]}"
    if [[ "$s_name" == "$SESSION_NAME" ]]; then
      HAS_TARGET_SESSION=1
    elif [[ "$s_name" == vscode-* ]]; then
      OTHER_VSCODE_SESSIONS+=("$s_name")
    fi
  fi
done <<< "$SESSIONS_OUT"

if [[ "$AUTO_STOP_PREV" -eq 1 && ${#OTHER_VSCODE_SESSIONS[@]} -gt 0 ]]; then
  for old_s in "${OTHER_VSCODE_SESSIONS[@]}"; do
    echo -e "${YELLOW}[Colab Runner] Switching runtime: stopping previous session '${old_s}'...${RESET}"
    "$COLAB_BIN" stop -s "$old_s" || true
  done
fi

if [[ "$HAS_TARGET_SESSION" -eq 0 ]]; then
  NEW_ARGS=(new -s "$SESSION_NAME")
  case "$HARDWARE" in
    cpu) ;;
    gpu:*) NEW_ARGS+=(--gpu "${HARDWARE#gpu:}") ;;
    tpu:*) NEW_ARGS+=(--tpu "${HARDWARE#tpu:}") ;;
  esac
  if [[ "$HIGH_MEM" -eq 1 ]]; then
    NEW_ARGS+=(--high-mem)
  fi
  echo -e "${CYAN}[Colab Runner] Provisioning Colab runtime (${HW_LABEL})...${RESET}"
  if ! "$COLAB_BIN" "${NEW_ARGS[@]}"; then
    echo -e "${RED}[Colab Runner] Failed to provision Colab runtime '${HW_LABEL}'.${RESET}" >&2
    exit 1
  fi
else
  echo -e "${GREEN}[Colab Runner] Reusing active Colab session '${SESSION_NAME}' (${HW_LABEL}).${RESET}"
fi

echo -e "${CYAN}[Colab Runner] Executing '${FILE_PATH}' on ${HW_LABEL}...${RESET}"
"$COLAB_BIN" exec -s "$SESSION_NAME" -f "$FILE_PATH" --timeout "$EXEC_TIMEOUT"
EXIT_CODE=$?

fetch_colab_info
write_runner_state
echo ""
echo -e "${MAGENTA}----------------------------------------------------------------------${RESET}"
echo -e " ${MAGENTA}Finished (${HW_LABEL})${RESET} | Exit Code: ${EXIT_CODE}"
echo -e " ${YELLOW}Remaining Credits:${RESET} ${COLAB_BALANCE} | Burn Rate: ${COLAB_RATE} | Active VMs: ${COLAB_ACTIVE}"
echo -e " ${DIM}Tip: Session '${SESSION_NAME}' stays warm for fast re-runs. Use 'Stop Active Colab Sessions' when done.${RESET}"
echo -e "${MAGENTA}----------------------------------------------------------------------${RESET}"
exit "$EXIT_CODE"

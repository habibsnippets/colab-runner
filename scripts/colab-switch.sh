#!/usr/bin/env bash
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/miniconda3/bin:$HOME/anaconda3/bin:/usr/local/bin:/usr/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
COLAB_BIN="$(command -v colab || echo "$HOME/.local/bin/colab")"
STATE_DIR="$HOME/.config/colab-cli"
STATE_FILE="$STATE_DIR/vscode-runner-state.env"

BOLD="\033[1m"
DARK="\033[1;34m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
MAGENTA="\033[1;35m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
GREY="\033[90m"
DIM="\033[2m"
RESET="\033[0m"

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

# Load existing state
CUR_MODE="local"
CUR_HW="cpu"
CUR_LOCAL_DEV="cpu"
CUR_HIGH_MEM="0"
CUR_SESSION_EPOCH="0"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" 2>/dev/null || true
  CUR_MODE="${COLAB_RUNNER_MODE:-local}"
  CUR_HW="${COLAB_RUNNER_HARDWARE:-cpu}"
  CUR_LOCAL_DEV="${COLAB_RUNNER_LOCAL_DEVICE:-cpu}"
  CUR_HIGH_MEM="${COLAB_RUNNER_HIGH_MEM:-0}"
  CUR_SESSION_EPOCH="${COLAB_RUNNER_SESSION_START_EPOCH:-0}"
fi

HIGH_MEM=0
TARGET_ARG=""
STOP_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --high-mem|-m) HIGH_MEM=1; shift ;;
    --stop) STOP_ALL=1; shift ;;
    -h|--help)
      echo "Usage: /switch [target] [--high-mem]"
      echo "Targets: local | local-cpu | local-gpu | cpu | t4 | l4 | g4 | a100 | h100 | v5e1 | v6e1 | stop"
      exit 0
      ;;
    *)
      if [[ -z "$TARGET_ARG" ]]; then
        TARGET_ARG="$1"
      fi
      shift
      ;;
  esac
done

fetch_colab_info() {
  EMAIL=""
  TIER="free"
  BALANCE="0.00"
  RATE="0.00/hr"
  ACTIVE_VMS="0"
  ELIGIBLE_GPUS="T4"
  ELIGIBLE_TPUS=""
  SESSION_START_EPOCH="$CUR_SESSION_EPOCH"

  if command -v "$COLAB_BIN" >/dev/null 2>&1 || [[ "${COLAB_RUNNER_SIMULATE_FREE:-0}" == "1" ]]; then
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
  fi
}

is_gpu_eligible() {
  local gpu_upper
  gpu_upper="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  [[ ",${ELIGIBLE_GPUS}," == *",${gpu_upper},"* ]]
}

is_tpu_eligible() {
  local tpu_upper
  tpu_upper="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  [[ ",${ELIGIBLE_TPUS}," == *",${tpu_upper},"* ]]
}

max_secs_for_hw() {
  local hw="$1"
  if [[ "$hw" == "cpu" ]]; then
    echo "43200"
  else
    echo "14400"
  fi
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

quota_summary_text() {
  local hw="$1"
  if [[ "$TIER" == "paid" ]]; then
    echo "Credits: ${BALANCE} CU (${RATE})"
    return
  fi
  local max_s
  max_s="$(max_secs_for_hw "$hw")"
  if [[ "$ACTIVE_VMS" =~ ^[0-9]+$ && "$ACTIVE_VMS" -gt 0 && "$SESSION_START_EPOCH" =~ ^[0-9]+$ && "$SESSION_START_EPOCH" -gt 0 ]]; then
    echo "Free Session: $(format_remaining_time "$SESSION_START_EPOCH" "$max_s")"
  else
    echo "Free Tier (4h T4 / 12h CPU)"
  fi
}

stop_all_sessions() {
  if ! command -v "$COLAB_BIN" >/dev/null 2>&1; then
    echo -e "${RED}[Colab] 'colab' CLI not found.${RESET}" >&2
    return 1
  fi
  local sessions_out stopped=0
  sessions_out="$(run_colab sessions </dev/null 2>/dev/null || true)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\][[:space:]] ]]; then
      local s_name="${BASH_REMATCH[1]}"
      if [[ "$s_name" != "?" && "$s_name" != "colab" ]]; then
        echo -e "${YELLOW}[Colab] Stopping session '${s_name}'...${RESET}"
        run_colab stop -s "$s_name" </dev/null || true
        stopped=1
      fi
    fi
  done <<< "$sessions_out"
  if [[ "$stopped" -eq 0 ]]; then
    echo -e "${DIM}[Colab] No active Colab VMs to stop.${RESET}"
  fi
}

detect_local_gpu_summary() {
  local smi_gpu="" pci_gpus=""
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
    smi_gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd ', ' -)"
    echo "ACTIVE:${smi_gpu}"
    return
  fi
  if command -v lspci >/dev/null 2>&1; then
    pci_gpus="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/^[^:]*: //' | paste -sd '; ' - || true)"
  fi
  if [[ -n "$pci_gpus" ]]; then
    echo "INACTIVE:${pci_gpus}"
  else
    echo "NONE:"
  fi
}

format_hw_label() {
  local mode="$1" hw="$2" himem="$3" local_dev="${4:-cpu}"
  if [[ "$mode" == "local" ]]; then
    if [[ "$local_dev" == "gpu" ]]; then
      echo "LOCAL GPU"
    else
      echo "LOCAL CPU"
    fi
    return
  fi
  local label=""
  case "$hw" in
    cpu) label="COLAB CPU" ;;
    gpu:*) label="COLAB GPU — ${hw#gpu:}" ;;
    tpu:*) label="COLAB TPU — ${hw#tpu:}" ;;
    *) label="COLAB ($hw)" ;;
  esac
  if [[ "$himem" -eq 1 && "$hw" != "gpu:L4" && "$hw" != tpu:* ]]; then
    label="$label (High-RAM)"
  fi
  echo "$label"
}

write_state() {
  local mode="$1" hw="$2" himem="$3" local_dev="${4:-cpu}"
  mkdir -p "$STATE_DIR"
  local hw_label max_secs
  hw_label="$(format_hw_label "$mode" "$hw" "$himem" "$local_dev")"
  max_secs="$(max_secs_for_hw "$hw")"
  if [[ ! "$ACTIVE_VMS" =~ ^[0-9]+$ || "$ACTIVE_VMS" -eq 0 ]]; then
    SESSION_START_EPOCH="0"
  fi

  cat > "$STATE_FILE" <<EOF
COLAB_RUNNER_MODE='${mode}'
COLAB_RUNNER_HARDWARE='${hw}'
COLAB_RUNNER_LOCAL_DEVICE='${local_dev}'
COLAB_RUNNER_HIGH_MEM='${himem}'
COLAB_RUNNER_HW_LABEL='${hw_label}'
COLAB_RUNNER_EMAIL='${EMAIL}'
COLAB_RUNNER_TIER='${TIER}'
COLAB_RUNNER_CREDITS='${BALANCE} CU'
COLAB_RUNNER_RATE='${RATE}'
COLAB_RUNNER_ACTIVE_VMS='${ACTIVE_VMS}'
COLAB_RUNNER_ELIGIBLE_GPUS='${ELIGIBLE_GPUS}'
COLAB_RUNNER_ELIGIBLE_TPUS='${ELIGIBLE_TPUS}'
COLAB_RUNNER_SESSION_START_EPOCH='${SESSION_START_EPOCH}'
COLAB_RUNNER_SESSION_MAX_SECS='${max_secs}'
EOF
}

print_gpu_option() {
  local num="$1" slug="$2" desc="$3" gpu_code="$4"
  if is_gpu_eligible "$gpu_code"; then
    local extra=""
    if [[ "$TIER" == "free" && "$gpu_code" == "T4" ]]; then
      extra=" • Free Tier: 4h session"
    fi
    echo -e "  ${DARK}[${num}]${RESET} ${BOLD}${slug}${RESET} — ${BOLD}${desc}${extra}${RESET}"
  else
    echo -e "  ${GREY}[${num}] ${slug} — ${desc} (Unavailable — requires Colab Pro / Compute Units)${RESET}"
  fi
}

print_tpu_option() {
  local num="$1" slug="$2" desc="$3" tpu_code="$4"
  if is_tpu_eligible "$tpu_code"; then
    echo -e "  ${DARK}[${num}]${RESET} ${BOLD}${slug}${RESET} — ${BOLD}${desc}${RESET}"
  else
    echo -e "  ${GREY}[${num}] ${slug} — ${desc} (Unavailable — requires Colab Pro / Compute Units)${RESET}"
  fi
}

fetch_colab_info

if [[ "$STOP_ALL" -eq 1 ]]; then
  stop_all_sessions
  fetch_colab_info
  SESSION_START_EPOCH="0"
  write_state "$CUR_MODE" "$CUR_HW" "$CUR_HIGH_MEM" "$CUR_LOCAL_DEV"
  exit 0
fi

if [[ -z "$TARGET_ARG" ]]; then
  cur_label="$(format_hw_label "$CUR_MODE" "$CUR_HW" "$CUR_HIGH_MEM" "$CUR_LOCAL_DEV")"
  quota_str="$(quota_summary_text "$CUR_HW")"
  echo ""
  echo -e "${CYAN}==========================================================================${RESET}"
  echo -e " ${BOLD}SELECT EXECUTION RUNTIME${RESET}  ${DIM}(Current: ${cur_label} | ${quota_str})${RESET}"
  echo -e "${CYAN}--------------------------------------------------------------------------${RESET}"
  echo -e "  ${GREEN}[1]${RESET} ${BOLD}local-cpu${RESET} — ${BOLD}Local Machine CPU${RESET} ${DIM}(forces CPU-only locally)${RESET}"
  echo -e "  ${GREEN}[2]${RESET} ${BOLD}local-gpu${RESET} — ${BOLD}Local Machine GPU${RESET} ${DIM}(uses local CUDA/MPS GPU if active)${RESET}"
  if [[ "$TIER" == "free" ]]; then
    echo -e "  ${DARK}[3]${RESET} ${BOLD}cpu${RESET}       — ${BOLD}Google Colab CPU (Free Tier: 12h session)${RESET}"
  else
    echo -e "  ${DARK}[3]${RESET} ${BOLD}cpu${RESET}       — ${BOLD}Google Colab CPU${RESET}"
  fi
  print_gpu_option "4" "t4       " "Google Colab GPU: T4 (16 GB VRAM)" "T4"
  print_gpu_option "5" "l4       " "Google Colab GPU: L4 (24 GB VRAM)" "L4"
  print_gpu_option "6" "g4       " "Google Colab GPU: G4" "G4"
  print_gpu_option "7" "a100     " "Google Colab GPU: A100" "A100"
  print_gpu_option "8" "h100     " "Google Colab GPU: H100" "H100"
  if is_tpu_eligible "V5E1" || is_tpu_eligible "V6E1"; then
    echo -e "  ${DARK}[9]${RESET} ${BOLD}v5e1/v6e1${RESET} — ${BOLD}Google Colab TPU (enter v5e1 or v6e1)${RESET}"
  else
    echo -e "  ${GREY}[9] v5e1/v6e1 — Google Colab TPU (Unavailable — requires Colab Pro / Compute Units)${RESET}"
  fi
  echo -e "  ${YELLOW}[0]${RESET} ${BOLD}stop${RESET}      — Stop All Active Colab VMs"
  echo -e "${CYAN}==========================================================================${RESET}"
  read -r -p "Choose runtime [1-9, 0, or name] (Enter to cancel): " TARGET_ARG
  if [[ -z "$TARGET_ARG" ]]; then
    echo -e "${DIM}[/switch] Cancelled.${RESET}"
    exit 0
  fi
fi

NORM="$(echo "$TARGET_ARG" | tr '[:upper:]' '[:lower:]')"
NEW_MODE="$CUR_MODE"
NEW_HW="$CUR_HW"
NEW_LOCAL_DEV="$CUR_LOCAL_DEV"
NEW_HIMEM="$HIGH_MEM"

case "$NORM" in
  0|stop|off)
    stop_all_sessions
    fetch_colab_info
    SESSION_START_EPOCH="0"
    write_state "$CUR_MODE" "$CUR_HW" "$CUR_HIGH_MEM" "$CUR_LOCAL_DEV"
    exit 0
    ;;
  1|local|local-cpu|loc|host|pc)
    NEW_MODE="local"
    NEW_HW="cpu"
    NEW_LOCAL_DEV="cpu"
    NEW_HIMEM=0
    ;;
  2|local-gpu|localgpu)
    NEW_MODE="local"
    NEW_HW="cpu"
    NEW_LOCAL_DEV="gpu"
    NEW_HIMEM=0
    ;;
  3|cpu|colab-cpu)
    NEW_MODE="colab"
    NEW_HW="cpu"
    ;;
  4|t4|gpu|gpu:t4|colab-t4)
    NEW_MODE="colab"
    NEW_HW="gpu:T4"
    ;;
  5|l4|gpu:l4|colab-l4)
    NEW_MODE="colab"
    NEW_HW="gpu:L4"
    ;;
  6|g4|gpu:g4|colab-g4)
    NEW_MODE="colab"
    NEW_HW="gpu:G4"
    ;;
  7|a100|gpu:a100|colab-a100)
    NEW_MODE="colab"
    NEW_HW="gpu:A100"
    ;;
  8|h100|gpu:h100|colab-h100)
    NEW_MODE="colab"
    NEW_HW="gpu:H100"
    ;;
  9|v5e1|tpu|tpu:v5e1)
    NEW_MODE="colab"
    NEW_HW="tpu:v5e1"
    ;;
  v6e1|tpu:v6e1)
    NEW_MODE="colab"
    NEW_HW="tpu:v6e1"
    ;;
  *)
    echo -e "${RED}[/switch] Unknown runtime: '$TARGET_ARG'. Try: local-cpu, local-gpu, cpu, t4, l4, g4, a100, h100, v5e1, v6e1, stop${RESET}" >&2
    exit 2
    ;;
esac

if [[ "$NEW_MODE" == "colab" ]]; then
  if [[ "$NEW_HW" == gpu:* ]]; then
    req_gpu="${NEW_HW#gpu:}"
    if [[ -n "$EMAIL" ]] && ! is_gpu_eligible "$req_gpu"; then
      echo -e "${RED}[/switch] '${req_gpu}' is unavailable on your current Colab tier (${TIER}).${RESET}" >&2
      echo -e "${YELLOW}[/switch] Available runtimes: local-cpu, local-gpu, cpu${ELIGIBLE_GPUS:+, ${ELIGIBLE_GPUS}}${ELIGIBLE_TPUS:+, ${ELIGIBLE_TPUS}}${RESET}" >&2
      exit 2
    fi
  elif [[ "$NEW_HW" == tpu:* ]]; then
    req_tpu="${NEW_HW#tpu:}"
    if [[ -n "$EMAIL" ]] && ! is_tpu_eligible "$req_tpu"; then
      echo -e "${RED}[/switch] TPU '${req_tpu}' is unavailable on your current Colab tier (${TIER}).${RESET}" >&2
      echo -e "${YELLOW}[/switch] Available runtimes: local-cpu, local-gpu, cpu${ELIGIBLE_GPUS:+, ${ELIGIBLE_GPUS}}${ELIGIBLE_TPUS:+, ${ELIGIBLE_TPUS}}${RESET}" >&2
      exit 2
    fi
  fi
fi

if [[ "$NEW_MODE" == "colab" && -z "$EMAIL" ]]; then
  echo -e "${YELLOW}[/switch] Warning: Not signed in to Colab CLI yet. Run ${BOLD}/login${RESET}${YELLOW} before running code on Colab.${RESET}"
fi

write_state "$NEW_MODE" "$NEW_HW" "$NEW_HIMEM" "$NEW_LOCAL_DEV"
NEW_LABEL="$(format_hw_label "$NEW_MODE" "$NEW_HW" "$NEW_HIMEM" "$NEW_LOCAL_DEV")"
QUOTA_OUT="$(quota_summary_text "$NEW_HW")"

if [[ "$NEW_MODE" == "local" ]]; then
  if [[ "$NEW_LOCAL_DEV" == "gpu" ]]; then
    local_gpu_probe="$(detect_local_gpu_summary)"
    probe_state="${local_gpu_probe%%:*}"
    probe_detail="${local_gpu_probe#*:}"
    if [[ "$probe_state" == "ACTIVE" ]]; then
      echo -e "${GREEN}[/switch]${RESET} Active runtime -> ${GREEN}${BOLD}LOCAL MACHINE GPU (${probe_detail})${RESET} | ${YELLOW}${QUOTA_OUT}${RESET}"
    elif [[ "$probe_state" == "INACTIVE" ]]; then
      echo -e "${GREEN}[/switch]${RESET} Active runtime -> ${GREEN}${BOLD}LOCAL MACHINE GPU${RESET} | ${YELLOW}${QUOTA_OUT}${RESET}"
      echo -e "${YELLOW}[/switch] Note: PCI GPU detected (${probe_detail}), but NVIDIA/CUDA driver is not active right now — PyTorch will fall back to CPU unless CUDA driver is installed/loaded.${RESET}"
    else
      echo -e "${GREEN}[/switch]${RESET} Active runtime -> ${GREEN}${BOLD}LOCAL MACHINE GPU${RESET} | ${YELLOW}${QUOTA_OUT}${RESET}"
      echo -e "${YELLOW}[/switch] Note: No NVIDIA CUDA GPU detected locally; scripts will fall back to CPU.${RESET}"
    fi
  else
    echo -e "${GREEN}[/switch]${RESET} Active runtime -> ${GREEN}${BOLD}LOCAL MACHINE CPU${RESET} (CUDA disabled locally) | ${YELLOW}${QUOTA_OUT}${RESET}"
  fi
  if [[ "$ACTIVE_VMS" =~ ^[0-9]+$ && "$ACTIVE_VMS" -gt 0 ]]; then
    echo -e "${YELLOW}[/switch] Note: You still have ${ACTIVE_VMS} active Colab VM(s) running. Run ${BOLD}/stop${RESET}${YELLOW} to release them.${RESET}"
  fi
else
  echo -e "${MAGENTA}[/switch]${RESET} Active runtime -> ${MAGENTA}${BOLD}${NEW_LABEL}${RESET} | ${YELLOW}${QUOTA_OUT}${RESET}"
fi

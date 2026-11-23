#!/usr/bin/env bash
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/miniconda3/bin:$HOME/anaconda3/bin:/usr/local/bin:/usr/bin:$PATH"

COLAB_BIN="$(command -v colab || echo "$HOME/.local/bin/colab")"
STATE_DIR="$HOME/.config/colab-cli"
STATE_FILE="$STATE_DIR/vscode-runner-state.env"

BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
MAGENTA="\033[1;35m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
DIM="\033[2m"
RESET="\033[0m"

# Load existing state
CUR_MODE="local"
CUR_HW="cpu"
CUR_LOCAL_DEV="cpu"
CUR_HIGH_MEM="0"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" 2>/dev/null || true
  CUR_MODE="${COLAB_RUNNER_MODE:-local}"
  CUR_HW="${COLAB_RUNNER_HARDWARE:-cpu}"
  CUR_LOCAL_DEV="${COLAB_RUNNER_LOCAL_DEVICE:-cpu}"
  CUR_HIGH_MEM="${COLAB_RUNNER_HIGH_MEM:-0}"
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
  BALANCE="N/A"
  RATE="0.00/hr"
  ACTIVE_VMS="0"
  if command -v "$COLAB_BIN" >/dev/null 2>&1; then
    local whoami_out usage_out
    whoami_out="$("$COLAB_BIN" whoami </dev/null 2>/dev/null || true)"
    EMAIL="$(echo "$whoami_out" | awk -F': *' '/^Email:/ {print $2; exit}')"
    if [[ -n "$EMAIL" ]]; then
      usage_out="$("$COLAB_BIN" usage </dev/null 2>/dev/null || true)"
      BALANCE="$(echo "$usage_out" | awk -F': *' '/^Current balance:/ {print $2; exit}')"
      RATE="$(echo "$usage_out" | awk -F': *' '/^Usage rate:/ {print $2; exit}')"
      ACTIVE_VMS="$(echo "$usage_out" | awk -F': *' '/^Active assignments:/ {print $2; exit}')"
      [[ -z "$BALANCE" ]] && BALANCE="?"
      [[ -z "$RATE" ]] && RATE="0.00/hr"
      [[ -z "$ACTIVE_VMS" ]] && ACTIVE_VMS="0"
    fi
  fi
}

stop_all_sessions() {
  if ! command -v "$COLAB_BIN" >/dev/null 2>&1; then
    echo -e "${RED}[Colab] 'colab' CLI not found.${RESET}" >&2
    return 1
  fi
  local sessions_out stopped=0
  sessions_out="$("$COLAB_BIN" sessions </dev/null 2>/dev/null || true)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\][[:space:]] ]]; then
      local s_name="${BASH_REMATCH[1]}"
      if [[ "$s_name" != "?" ]]; then
        echo -e "${YELLOW}[Colab] Stopping session '${s_name}'...${RESET}"
        "$COLAB_BIN" stop -s "$s_name" </dev/null || true
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
  local hw_label short_credits
  hw_label="$(format_hw_label "$mode" "$hw" "$himem" "$local_dev")"
  short_credits="${BALANCE/ compute units/ CU}"
  [[ -z "$short_credits" || "$short_credits" == "N/A" ]] && short_credits="?"

  cat > "$STATE_FILE" <<EOF
COLAB_RUNNER_MODE='${mode}'
COLAB_RUNNER_HARDWARE='${hw}'
COLAB_RUNNER_LOCAL_DEVICE='${local_dev}'
COLAB_RUNNER_HIGH_MEM='${himem}'
COLAB_RUNNER_HW_LABEL='${hw_label}'
COLAB_RUNNER_EMAIL='${EMAIL}'
COLAB_RUNNER_CREDITS='${short_credits}'
COLAB_RUNNER_RATE='${RATE}'
COLAB_RUNNER_ACTIVE_VMS='${ACTIVE_VMS}'
EOF
}

fetch_colab_info

if [[ "$STOP_ALL" -eq 1 ]]; then
  stop_all_sessions
  fetch_colab_info
  write_state "$CUR_MODE" "$CUR_HW" "$CUR_HIGH_MEM" "$CUR_LOCAL_DEV"
  exit 0
fi

if [[ -z "$TARGET_ARG" ]]; then
  cur_label="$(format_hw_label "$CUR_MODE" "$CUR_HW" "$CUR_HIGH_MEM" "$CUR_LOCAL_DEV")"
  short_c="${BALANCE/ compute units/ CU}"
  echo ""
  echo -e "${CYAN}======================================================================${RESET}"
  echo -e " ${BOLD}SELECT EXECUTION RUNTIME${RESET}  ${DIM}(Current: ${cur_label} | Credits: ${short_c})${RESET}"
  echo -e "${CYAN}----------------------------------------------------------------------${RESET}"
  echo -e "  ${GREEN}[1]${RESET} local-cpu — Local Machine CPU (forces CUDA_VISIBLE_DEVICES='')"
  echo -e "  ${GREEN}[2]${RESET} local-gpu — Local Machine GPU (uses local CUDA/NVIDIA GPU if active)"
  echo -e "  ${MAGENTA}[3]${RESET} cpu       — Google Colab CPU"
  echo -e "  ${MAGENTA}[4]${RESET} t4        — Google Colab GPU: T4 (16 GB VRAM)"
  echo -e "  ${MAGENTA}[5]${RESET} l4        — Google Colab GPU: L4 (24 GB VRAM)"
  echo -e "  ${MAGENTA}[6]${RESET} g4        — Google Colab GPU: G4"
  echo -e "  ${MAGENTA}[7]${RESET} a100      — Google Colab GPU: A100"
  echo -e "  ${MAGENTA}[8]${RESET} h100      — Google Colab GPU: H100"
  echo -e "  ${MAGENTA}[9]${RESET} v5e1/v6e1 — Google Colab TPU (enter v5e1 or v6e1)"
  echo -e "  ${YELLOW}[0]${RESET} stop      — Stop All Active Colab VMs"
  echo -e "${CYAN}======================================================================${RESET}"
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

if [[ "$NEW_MODE" == "colab" && -z "$EMAIL" ]]; then
  echo -e "${YELLOW}[/switch] Warning: Not signed in to Colab CLI yet. Run ${BOLD}/login${RESET}${YELLOW} before running code on Colab.${RESET}"
fi

write_state "$NEW_MODE" "$NEW_HW" "$NEW_HIMEM" "$NEW_LOCAL_DEV"
NEW_LABEL="$(format_hw_label "$NEW_MODE" "$NEW_HW" "$NEW_HIMEM" "$NEW_LOCAL_DEV")"

if [[ "$NEW_MODE" == "local" ]]; then
  if [[ "$NEW_LOCAL_DEV" == "gpu" ]]; then
    local_gpu_probe="$(detect_local_gpu_summary)"
    probe_state="${local_gpu_probe%%:*}"
    probe_detail="${local_gpu_probe#*:}"
    if [[ "$probe_state" == "ACTIVE" ]]; then
      echo -e "${GREEN}[/switch]${RESET} Active runtime -> ${GREEN}${BOLD}LOCAL MACHINE GPU (${probe_detail})${RESET} | Colab Credits: ${YELLOW}${BALANCE}${RESET} (${RATE})"
    elif [[ "$probe_state" == "INACTIVE" ]]; then
      echo -e "${GREEN}[/switch]${RESET} Active runtime -> ${GREEN}${BOLD}LOCAL MACHINE GPU${RESET} | Colab Credits: ${YELLOW}${BALANCE}${RESET} (${RATE})"
      echo -e "${YELLOW}[/switch] Note: PCI GPU detected (${probe_detail}), but NVIDIA/CUDA driver is not active right now — PyTorch will fall back to CPU unless CUDA driver is installed/loaded.${RESET}"
    else
      echo -e "${GREEN}[/switch]${RESET} Active runtime -> ${GREEN}${BOLD}LOCAL MACHINE GPU${RESET} | Colab Credits: ${YELLOW}${BALANCE}${RESET} (${RATE})"
      echo -e "${YELLOW}[/switch] Note: No NVIDIA CUDA GPU detected locally; scripts will fall back to CPU.${RESET}"
    fi
  else
    echo -e "${GREEN}[/switch]${RESET} Active runtime -> ${GREEN}${BOLD}LOCAL MACHINE CPU${RESET} (CUDA disabled locally) | Colab Credits: ${YELLOW}${BALANCE}${RESET} (${RATE})"
  fi
  if [[ "$ACTIVE_VMS" =~ ^[0-9]+$ && "$ACTIVE_VMS" -gt 0 ]]; then
    echo -e "${YELLOW}[/switch] Note: You still have ${ACTIVE_VMS} active Colab VM(s) running. Run ${BOLD}/stop${RESET}${YELLOW} to release them.${RESET}"
  fi
else
  echo -e "${MAGENTA}[/switch]${RESET} Active runtime -> ${MAGENTA}${BOLD}${NEW_LABEL}${RESET} | Colab Credits: ${YELLOW}${BALANCE}${RESET} (${RATE})"
fi

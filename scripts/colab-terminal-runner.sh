#!/usr/bin/env bash
set -uo pipefail

export COLAB_RUNNER_INTERNAL=1
export PATH="$HOME/.local/bin:$HOME/miniconda3/bin:$HOME/anaconda3/bin:/usr/local/bin:/usr/bin:$PATH"

MODE="local"
HARDWARE="cpu"
LOCAL_DEVICE="cpu"
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
    --local-device) LOCAL_DEVICE="${2:-cpu}"; shift 2 ;;
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

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE_DIR="$HOME/.config/colab-cli"
STATE_FILE="$STATE_DIR/vscode-runner-state.env"

run_colab() {
  if [[ -d "$SCRIPT_DIR/py_ipv4" ]]; then
    PYTHONPATH="$SCRIPT_DIR/py_ipv4${PYTHONPATH:+:$PYTHONPATH}" "$COLAB_BIN" "$@"
  else
    "$COLAB_BIN" "$@"
  fi
}

run_tier_info() {
  local py_bin="python3"
  local colab_resolved=""
  colab_resolved="$(command -v "$COLAB_BIN" 2>/dev/null || echo "$COLAB_BIN")"
  if [[ -f "$colab_resolved" ]]; then
    local shebang_py
    shebang_py="$(head -n 1 "$colab_resolved" 2>/dev/null | sed 's/^#!//' | awk '{print $1}')"
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

SESSION_START_EPOCH="0"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" 2>/dev/null || true
  SESSION_START_EPOCH="${COLAB_RUNNER_SESSION_START_EPOCH:-0}"
fi

fetch_colab_info() {
  COLAB_EMAIL="Not signed in"
  COLAB_RAW_EMAIL=""
  COLAB_TIER="free"
  COLAB_BALANCE="0.00"
  COLAB_RATE="0.00/hr"
  COLAB_ACTIVE="0"
  COLAB_ELIGIBLE_GPUS="T4"
  COLAB_ELIGIBLE_TPUS=""

  if command -v "$COLAB_BIN" >/dev/null 2>&1 || [[ "${COLAB_RUNNER_SIMULATE_FREE:-0}" == "1" ]]; then
    local info_out email=""
    info_out="$(run_tier_info)"
    while IFS='=' read -r k v; do
      case "$k" in
        EMAIL) email="$v" ;;
        TIER) COLAB_TIER="$v" ;;
        BALANCE) COLAB_BALANCE="$v" ;;
        RATE) COLAB_RATE="$v" ;;
        ACTIVE_VMS) COLAB_ACTIVE="$v" ;;
        ELIGIBLE_GPUS) COLAB_ELIGIBLE_GPUS="$v" ;;
        ELIGIBLE_TPUS) COLAB_ELIGIBLE_TPUS="$v" ;;
        SESSION_START_EPOCH)
          if [[ "$SESSION_START_EPOCH" == "0" && "$v" != "0" ]]; then
            SESSION_START_EPOCH="$v"
          fi
          ;;
      esac
    done <<< "$info_out"
    if [[ -n "$email" ]]; then
      COLAB_EMAIL="$email"
      COLAB_RAW_EMAIL="$email"
    fi
  fi
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

quota_banner_text() {
  if [[ -z "$COLAB_RAW_EMAIL" ]]; then
    echo "Not signed in (run /login)"
    return
  fi
  if [[ "$COLAB_TIER" == "paid" ]]; then
    echo "${COLAB_BALANCE} compute units | Rate: ${COLAB_RATE} | Active VMs: ${COLAB_ACTIVE}"
    return
  fi
  local max_s limit_txt
  max_s="$(max_secs_for_hw "$HARDWARE")"
  limit_txt="4h max for T4 GPU"
  [[ "$HARDWARE" == "cpu" ]] && limit_txt="12h max for CPU"
  if [[ "$COLAB_ACTIVE" =~ ^[0-9]+$ && "$COLAB_ACTIVE" -gt 0 && "$SESSION_START_EPOCH" =~ ^[0-9]+$ && "$SESSION_START_EPOCH" -gt 0 ]]; then
    echo "Free Tier — $(format_remaining_time "$SESSION_START_EPOCH" "$max_s") (${limit_txt}) | Active VMs: ${COLAB_ACTIVE}"
  else
    echo "Free Tier (4h T4 GPU / 12h CPU limit) | Active VMs: ${COLAB_ACTIVE}"
  fi
}

write_runner_state() {
  mkdir -p "$STATE_DIR"

  local hw_label="LOCAL CPU"
  if [[ "$MODE" == "local" && "$LOCAL_DEVICE" == "gpu" ]]; then
    hw_label="LOCAL GPU"
  elif [[ "$MODE" == "colab" ]]; then
    hw_label="$(format_hardware_label "$HARDWARE")"
  fi
  local max_secs
  max_secs="$(max_secs_for_hw "$HARDWARE")"
  if [[ ! "$COLAB_ACTIVE" =~ ^[0-9]+$ || "$COLAB_ACTIVE" -eq 0 ]]; then
    SESSION_START_EPOCH="0"
  fi

  cat > "$STATE_FILE" <<EOF
COLAB_RUNNER_MODE='${MODE}'
COLAB_RUNNER_HARDWARE='${HARDWARE}'
COLAB_RUNNER_LOCAL_DEVICE='${LOCAL_DEVICE}'
COLAB_RUNNER_HIGH_MEM='${HIGH_MEM}'
COLAB_RUNNER_HW_LABEL='${hw_label}'
COLAB_RUNNER_EMAIL='${COLAB_RAW_EMAIL}'
COLAB_RUNNER_TIER='${COLAB_TIER}'
COLAB_RUNNER_CREDITS='${COLAB_BALANCE} CU'
COLAB_RUNNER_RATE='${COLAB_RATE}'
COLAB_RUNNER_ACTIVE_VMS='${COLAB_ACTIVE}'
COLAB_RUNNER_ELIGIBLE_GPUS='${COLAB_ELIGIBLE_GPUS}'
COLAB_RUNNER_ELIGIBLE_TPUS='${COLAB_ELIGIBLE_TPUS}'
COLAB_RUNNER_SESSION_START_EPOCH='${SESSION_START_EPOCH}'
COLAB_RUNNER_SESSION_MAX_SECS='${max_secs}'
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
  local cpu_model cores ram_gb gpu_info pci_gpus
  cpu_model="$(lscpu 2>/dev/null | awk -F': *' '/^Model name:/ {print $2; exit}')"
  [[ -z "$cpu_model" ]] && cpu_model="$(uname -m)"
  cores="$(nproc 2>/dev/null || echo "?")"
  ram_gb="$(free -h 2>/dev/null | awk '/^Mem:/ {print $2; exit}')"
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
    gpu_info="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd ', ' -)"
    echo "${cpu_model} (${cores} cores, ${ram_gb} RAM) | Active CUDA GPU: ${gpu_info}"
  elif command -v lspci >/dev/null 2>&1; then
    pci_gpus="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/^[^:]*: //' | paste -sd '; ' - || true)"
    if [[ -n "$pci_gpus" ]]; then
      echo "${cpu_model} (${cores} cores, ${ram_gb} RAM) | PCI GPU: ${pci_gpus} (CUDA driver inactive)"
    else
      echo "${cpu_model} (${cores} cores, ${ram_gb} RAM) | No Local GPU"
    fi
  else
    echo "${cpu_model} (${cores} cores, ${ram_gb} RAM) | No Local NVIDIA GPU"
  fi
}

fetch_colab_info
write_runner_state

if [[ "$MODE" == "local" ]]; then
  LOCAL_HW="$(detect_local_hardware)"
  PY_VER="$("$PYTHON_BIN" --version 2>&1 || echo "Python unavailable")"
  LOCAL_TARGET_LABEL="LOCAL MACHINE CPU (CUDA disabled)"
  if [[ "$LOCAL_DEVICE" == "gpu" ]]; then
    LOCAL_TARGET_LABEL="LOCAL MACHINE GPU (falls back to CPU if CUDA unavailable)"
  fi
  echo ""
  echo -e "${CYAN}======================================================================${RESET}"
  echo -e " ${GREEN}EXECUTION TARGET :${RESET} ${BOLD}${LOCAL_TARGET_LABEL}${RESET}"
  echo -e " ${CYAN}LOCAL HARDWARE   :${RESET} ${LOCAL_HW}"
  echo -e " ${CYAN}PYTHON RUNTIME   :${RESET} ${PY_VER} ($(command -v "$PYTHON_BIN" || echo "$PYTHON_BIN"))"
  echo -e " ${YELLOW}COLAB QUOTA      :${RESET} $(quota_banner_text) | Account: ${COLAB_EMAIL} [Standby]"
  echo -e " ${CYAN}FILE             :${RESET} ${FILE_PATH}"
  echo -e "${CYAN}======================================================================${RESET}"
  echo ""

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${DIM}[Dry Run] Local execution skipped.${RESET}"
    exit 0
  fi

  export COLAB_RUNNER_LOCAL_DEVICE="$LOCAL_DEVICE"
  if [[ "$LOCAL_DEVICE" == "cpu" ]]; then
    export CUDA_VISIBLE_DEVICES=""
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
  echo -e " ${GREEN}Finished (Local Machine)${RESET} | Exit Code: ${EXIT_CODE} | Colab: ${YELLOW}$(quota_banner_text)${RESET}"
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
echo -e " ${YELLOW}COLAB QUOTA      :${RESET} $(quota_banner_text)"
echo -e " ${CYAN}SESSION NAME     :${RESET} ${SESSION_NAME}"
echo -e " ${CYAN}FILE             :${RESET} ${FILE_PATH}"
echo -e "${MAGENTA}======================================================================${RESET}"
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo -e "${DIM}[Dry Run] Colab session provisioning & execution skipped.${RESET}"
  exit 0
fi

SESSIONS_OUT="$(run_colab sessions </dev/null 2>/dev/null || true)"
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
    run_colab stop -s "$old_s" || true
  done
  SESSION_START_EPOCH="0"
fi

build_gpu_fallback_chain() {
  local req_upper
  req_upper="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  local all_ranked=("H100" "A100" "L4" "G4" "T4")
  local chain=("$req_upper")
  local seen=",${req_upper},"

  # Find index of requested GPU in ranked order
  local req_idx=0 i=0
  for g in "${all_ranked[@]}"; do
    if [[ "$g" == "$req_upper" ]]; then
      req_idx=$i
      break
    fi
    i=$((i + 1))
  done

  # 1) Add lower/next-best eligible GPUs first (e.g. A100 -> L4 -> G4 -> T4)
  for (( idx=req_idx+1; idx<${#all_ranked[@]}; idx++ )); do
    local cand="${all_ranked[$idx]}"
    if [[ ",${COLAB_ELIGIBLE_GPUS}," == *",${cand},"* && "$seen" != *",${cand},"* ]]; then
      chain+=("$cand")
      seen="${seen}${cand},"
    fi
  done

  # 2) Add any remaining eligible GPUs above requested (e.g. if user requested G4, also try L4)
  for (( idx=req_idx-1; idx>=0; idx-- )); do
    local cand="${all_ranked[$idx]}"
    if [[ ",${COLAB_ELIGIBLE_GPUS}," == *",${cand},"* && "$seen" != *",${cand},"* ]]; then
      chain+=("$cand")
      seen="${seen}${cand},"
    fi
  done

  echo "${chain[*]}"
}

summarize_assign_error() {
  local out="$1"
  if [[ "$out" == *"Service Unavailable"* || "$out" == *"503"* ]]; then
    echo "at capacity / 503 Service Unavailable on Google Colab"
  elif [[ "$out" == *"TooManyAssignmentsError"* || "$out" == *"412"* ]]; then
    echo "assignment/quota limit reached (HTTP 412)"
  elif [[ "$out" == *"400"* || "$out" == *"403"* ]]; then
    echo "not entitled on current Colab tier"
  else
    echo "backend allocation failed"
  fi
}

if [[ "$HAS_TARGET_SESSION" -eq 0 ]]; then
  if [[ "$HARDWARE" == gpu:* ]]; then
    REQ_GPU="${HARDWARE#gpu:}"
    read -r -a GPU_CANDIDATES <<< "$(build_gpu_fallback_chain "$REQ_GPU")"
    PROVISIONED_OK=0
    TOTAL_CANDS="${#GPU_CANDIDATES[@]}"

    for (( c_idx=0; c_idx<TOTAL_CANDS; c_idx++ )); do
      CAND_GPU="${GPU_CANDIDATES[$c_idx]}"
      CAND_HW="gpu:${CAND_GPU}"
      CAND_LABEL="$(format_hardware_label "$CAND_HW")"
      CAND_SESSION="$(session_name_for_hw "$CAND_HW")"

      NEW_ARGS=(new -s "$CAND_SESSION" --gpu "$CAND_GPU")
      if [[ "$HIGH_MEM" -eq 1 && "$CAND_GPU" != "L4" ]]; then
        NEW_ARGS+=(--high-mem)
      fi

      echo -e "${CYAN}[Colab Runner] Requesting Colab runtime (${CAND_LABEL})...${RESET}"
      ASSIGN_OUT="$(COLAB_CLI_ASSIGN_RETRIES=1 COLAB_CLI_RETRY_BACKOFF=3 run_colab "${NEW_ARGS[@]}" 2>&1)"
      ASSIGN_RC=$?

      if [[ "$ASSIGN_RC" -eq 0 ]]; then
        echo -e "${GREEN}[colab] Session '${CAND_SESSION}' READY.${RESET}"
        if [[ "$CAND_GPU" != "$REQ_GPU" ]]; then
          echo -e "${GREEN}${BOLD}[Colab Runner] '${REQ_GPU}' was unavailable — automatically connected to next best available GPU: ${CAND_LABEL}${RESET}"
        fi
        HARDWARE="$CAND_HW"
        HW_LABEL="$CAND_LABEL"
        SESSION_NAME="$CAND_SESSION"
        SESSION_START_EPOCH="$(date +%s)"
        write_runner_state
        PROVISIONED_OK=1
        break
      else
        REASON="$(summarize_assign_error "$ASSIGN_OUT")"
        echo -e "${YELLOW}[Colab Runner] Colab GPU '${CAND_GPU}' is currently unavailable (${REASON}).${RESET}"
        next_idx=$((c_idx + 1))
        if [[ "$next_idx" -lt "$TOTAL_CANDS" ]]; then
          NEXT_GPU="${GPU_CANDIDATES[$next_idx]}"
          echo -e "${CYAN}[Colab Runner] Automatically trying next best available GPU: COLAB GPU — ${NEXT_GPU}...${RESET}"
        fi
      fi
    done

    if [[ "$PROVISIONED_OK" -eq 0 ]]; then
      TRIED_STR="$(IFS=' -> '; echo "${GPU_CANDIDATES[*]}")"
      echo ""
      echo -e "${RED}======================================================================${RESET}"
      echo -e " ${RED}ALL ELIGIBLE COLAB GPUs ARE CURRENTLY UNAVAILABLE${RESET}"
      echo -e " ${YELLOW}Tried:${RESET} ${TRIED_STR} (Google Colab regional GPU pool is at capacity)"
      echo -e " ${CYAN}Tip:${RESET} Try again in a few minutes, or switch to CPU:"
      echo -e "      ${BOLD}/switch cpu${RESET}        (Google Colab CPU)"
      echo -e "      ${BOLD}/switch local-cpu${RESET}  (Local Machine CPU)"
      echo -e "${RED}======================================================================${RESET}"
      exit 1
    fi
  else
    NEW_ARGS=(new -s "$SESSION_NAME")
    if [[ "$HARDWARE" == tpu:* ]]; then
      NEW_ARGS+=(--tpu "${HARDWARE#tpu:}")
    fi
    if [[ "$HIGH_MEM" -eq 1 ]]; then
      NEW_ARGS+=(--high-mem)
    fi
    echo -e "${CYAN}[Colab Runner] Requesting Colab runtime (${HW_LABEL})...${RESET}"
    ASSIGN_OUT="$(COLAB_CLI_ASSIGN_RETRIES=1 COLAB_CLI_RETRY_BACKOFF=3 run_colab "${NEW_ARGS[@]}" 2>&1)"
    if [[ $? -ne 0 ]]; then
      REASON="$(summarize_assign_error "$ASSIGN_OUT")"
      echo -e "${RED}[Colab Runner] Colab runtime '${HW_LABEL}' is currently unavailable (${REASON}).${RESET}" >&2
      exit 1
    fi
    echo -e "${GREEN}[colab] Session '${SESSION_NAME}' READY.${RESET}"
    SESSION_START_EPOCH="$(date +%s)"
    write_runner_state
  fi
else
  echo -e "${GREEN}[Colab Runner] Reusing active Colab session '${SESSION_NAME}' (${HW_LABEL}).${RESET}"
  if [[ "$SESSION_START_EPOCH" == "0" ]]; then
    SESSION_START_EPOCH="$(date +%s)"
  fi
fi

echo -e "${CYAN}[Colab Runner] Executing '${FILE_PATH}' on ${HW_LABEL}...${RESET}"
run_colab exec -s "$SESSION_NAME" -f "$FILE_PATH" --timeout "$EXEC_TIMEOUT"
EXIT_CODE=$?

fetch_colab_info
write_runner_state
echo ""
echo -e "${MAGENTA}----------------------------------------------------------------------${RESET}"
echo -e " ${MAGENTA}Finished (${HW_LABEL})${RESET} | Exit Code: ${EXIT_CODE}"
echo -e " ${YELLOW}Quota Status:${RESET} $(quota_banner_text)"
echo -e " ${DIM}Tip: Session '${SESSION_NAME}' stays warm for fast re-runs. Run '/stop' when finished.${RESET}"
echo -e "${MAGENTA}----------------------------------------------------------------------${RESET}"
exit "$EXIT_CODE"

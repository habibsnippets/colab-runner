# Colab & Local Runner CLI shell integration.
# Provides /switch, /run, /login, /logout, /status, /stop, /help,
# smart `python <file.py|file.ipynb>` routing, and a persistent prompt badge.

if [[ -n "${__COLAB_RUNNER_RCFILE_MODE:-}" && -f "$HOME/.bashrc" && -z "${__COLAB_RUNNER_BASHRC_LOADED:-}" ]]; then
  export __COLAB_RUNNER_BASHRC_LOADED=1
  # shellcheck disable=SC1091
  source "$HOME/.bashrc"
fi

if [[ $- == *i* && -z "${__COLAB_RUNNER_PROMPT_INSTALLED:-}" ]]; then
  __COLAB_RUNNER_PROMPT_INSTALLED=1
  __COLAB_RUNNER_ACTIVE_PREFIX=""
  __COLAB_RUNNER_STATE_FILE="$HOME/.config/colab-cli/vscode-runner-state.env"

  __colab_runner_prompt() {
    local mode="local"
    local hw_label="LOCAL CPU"
    local credits="?"
    local rate="0.00/hr"
    local email=""
    local active_vms="0"

    if [[ -f "$__COLAB_RUNNER_STATE_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$__COLAB_RUNNER_STATE_FILE" 2>/dev/null || true
      mode="${COLAB_RUNNER_MODE:-local}"
      hw_label="${COLAB_RUNNER_HW_LABEL:-LOCAL CPU}"
      credits="${COLAB_RUNNER_CREDITS:-?}"
      rate="${COLAB_RUNNER_RATE:-0.00/hr}"
      email="${COLAB_RUNNER_EMAIL:-}"
      active_vms="${COLAB_RUNNER_ACTIVE_VMS:-0}"
    fi

    local base_ps1="$PS1"
    if [[ -n "$__COLAB_RUNNER_ACTIVE_PREFIX" ]]; then
      base_ps1="${base_ps1//"$__COLAB_RUNNER_ACTIVE_PREFIX"/}"
    fi

    local badge=""
    local term_title=""
    if [[ "$mode" == "colab" ]]; then
      local vm_tag=""
      if [[ "$active_vms" =~ ^[0-9]+$ && "$active_vms" -gt 0 ]]; then
        vm_tag=" | ${active_vms} VM"
      fi
      if [[ -n "$email" ]]; then
        badge="\[\e[1;35m\][☁ ${hw_label}\[\e[0m\] \[\e[1;33m\]| ${credits} (${rate})${vm_tag}\[\e[1;35m\]]\[\e[0m\] "
        term_title="${hw_label} | ${credits} (${rate})"
      else
        badge="\[\e[1;31m\][☁ ${hw_label} | Run /login]\[\e[0m\] "
        term_title="${hw_label} | Run /login"
      fi
    else
      if [[ -n "$email" ]]; then
        badge="\[\e[1;32m\][🖥 ${hw_label}\[\e[0m\] \[\e[1;33m\]| Colab: ${credits} (${rate})\[\e[1;32m\]]\[\e[0m\] "
        term_title="${hw_label} | Colab: ${credits}"
      else
        badge="\[\e[1;32m\][🖥 ${hw_label}\[\e[0m\] \[\e[2m\]| Colab: Signed Out\[\e[1;32m\]]\[\e[0m\] "
        term_title="${hw_label} | Colab: Signed Out"
      fi
    fi

    __COLAB_RUNNER_ACTIVE_PREFIX="$badge"
    PS1="${badge}${base_ps1}"
    printf '\033]0;%s\007' "$term_title"
  }

  if [[ -z "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="__colab_runner_prompt"
  elif [[ "$PROMPT_COMMAND" != *"__colab_runner_prompt"* ]]; then
    PROMPT_COMMAND="__colab_runner_prompt; ${PROMPT_COMMAND}"
  fi

  # --- Slash Commands ---
  /switch() {
    "$HOME/.local/bin/colab-switch" "$@"
  }

  /login() {
    "$HOME/.local/bin/colab-login" "$@"
  }

  /logout() {
    "$HOME/.local/bin/colab-logout" "$@"
  }

  /status() {
    local mode="local" hw_label="LOCAL CPU"
    if [[ -f "$__COLAB_RUNNER_STATE_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$__COLAB_RUNNER_STATE_FILE" 2>/dev/null || true
      mode="${COLAB_RUNNER_MODE:-local}"
      hw_label="${COLAB_RUNNER_HW_LABEL:-LOCAL CPU}"
    fi
    echo -e "\033[1;36m[Active Runtime]\033[0m ${hw_label} (mode=${mode})"
    "$HOME/.local/bin/colab-status" "$@"
  }

  /stop() {
    "$HOME/.local/bin/colab-switch" --stop
  }

  /run() {
    local file_path="${1:-}"
    if [[ -z "$file_path" ]]; then
      echo "Usage: /run <script.py | notebook.ipynb>" >&2
      return 2
    fi

    local mode="local" hw="cpu" local_dev="cpu" himem="0"
    if [[ -f "$__COLAB_RUNNER_STATE_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$__COLAB_RUNNER_STATE_FILE" 2>/dev/null || true
      mode="${COLAB_RUNNER_MODE:-local}"
      hw="${COLAB_RUNNER_HARDWARE:-cpu}"
      local_dev="${COLAB_RUNNER_LOCAL_DEVICE:-cpu}"
      himem="${COLAB_RUNNER_HIGH_MEM:-0}"
    fi

    local args=(--mode "$mode" --hardware "$hw" --local-device "$local_dev" --file "$file_path" --auto-stop-prev)
    [[ "$himem" == "1" ]] && args+=(--high-mem)
    "$HOME/.local/bin/colab-runner" "${args[@]}"
  }

  /help() {
    cat << 'EOF'

Colab & Local CLI Commands:
  /switch                 Interactive menu (Local CPU/GPU, Colab CPU, T4, L4, G4, A100, H100, TPU)
  /switch <target>        Direct: local-cpu | local-gpu | cpu | t4 | l4 | g4 | a100 | h100 | v5e1 | v6e1
  /run <file>             Run a .py script or .ipynb notebook on the active runtime
  python <file.py|.ipynb> Also routes automatically to the active runtime!
  /login [--switch]       Sign in or switch Google Colab account in terminal
  /logout                 Sign out and clear Colab credentials
  /status                 Show active runtime, Google account, remaining credits & VMs
  /stop                   Stop all active Colab VMs (protect compute units)
  /help                   Show this help message

EOF
  }

  # Transparent python / python3 wrapper for single .py or .ipynb file execution
  __colab_python_dispatch() {
    local real_py="$1"
    shift
    if [[ -z "${COLAB_RUNNER_INTERNAL:-}" && $# -eq 1 && -f "$1" ]]; then
      case "$1" in
        *.py|*.ipynb)
          /run "$1"
          return $?
          ;;
      esac
    fi
    command "$real_py" "$@"
  }

  python() {
    __colab_python_dispatch python "$@"
  }

  python3() {
    __colab_python_dispatch python3 "$@"
  }

  # Tab completions
  complete -W "local local-cpu local-gpu cpu t4 l4 g4 a100 h100 v5e1 v6e1 stop --high-mem" /switch
  complete -W "--switch --check" /login
  complete -f -X '!*.@(py|ipynb)' /run
fi

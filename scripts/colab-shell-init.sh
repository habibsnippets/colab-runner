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

  __colab_format_free_badge() {
    local mode="$1" hw="$2" active_vms="$3" start_ep="$4" max_s="$5"
    if [[ "$active_vms" =~ ^[0-9]+$ && "$active_vms" -gt 0 && "$start_ep" =~ ^[0-9]+$ && "$start_ep" -gt 0 ]]; then
      local now rem hrs mins
      now="$(date +%s)"
      [[ ! "$max_s" =~ ^[0-9]+$ || "$max_s" -eq 0 ]] && max_s=14400
      rem=$(( max_s - (now - start_ep) ))
      [[ "$rem" -lt 0 ]] && rem=0
      hrs=$(( rem / 3600 ))
      mins=$(( (rem % 3600) / 60 ))
      if [[ "$hrs" -gt 0 ]]; then
        echo "Free: ${hrs}h ${mins}m left"
      else
        echo "Free: ${mins}m left"
      fi
    elif [[ "$mode" == "colab" ]]; then
      if [[ "$hw" == "cpu" ]]; then
        echo "Free: 12h CPU max"
      else
        echo "Free: 4h T4 max"
      fi
    else
      echo "Free Tier (4h T4/12h CPU)"
    fi
  }

  __colab_runner_prompt() {
    local mode="local"
    local hw="cpu"
    local hw_label="LOCAL CPU"
    local tier="paid"
    local credits="?"
    local rate="0.00/hr"
    local email=""
    local active_vms="0"
    local start_ep="0"
    local max_s="14400"

    if [[ -f "$__COLAB_RUNNER_STATE_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$__COLAB_RUNNER_STATE_FILE" 2>/dev/null || true
      mode="${COLAB_RUNNER_MODE:-local}"
      hw="${COLAB_RUNNER_HARDWARE:-cpu}"
      hw_label="${COLAB_RUNNER_HW_LABEL:-LOCAL CPU}"
      tier="${COLAB_RUNNER_TIER:-paid}"
      credits="${COLAB_RUNNER_CREDITS:-?}"
      rate="${COLAB_RUNNER_RATE:-0.00/hr}"
      email="${COLAB_RUNNER_EMAIL:-}"
      active_vms="${COLAB_RUNNER_ACTIVE_VMS:-0}"
      start_ep="${COLAB_RUNNER_SESSION_START_EPOCH:-0}"
      max_s="${COLAB_RUNNER_SESSION_MAX_SECS:-14400}"
    fi

    local base_ps1="$PS1"
    if [[ -n "$__COLAB_RUNNER_ACTIVE_PREFIX" ]]; then
      base_ps1="${base_ps1//"$__COLAB_RUNNER_ACTIVE_PREFIX"/}"
    fi

    local quota_badge=""
    if [[ "$tier" == "free" ]]; then
      quota_badge="$(__colab_format_free_badge "$mode" "$hw" "$active_vms" "$start_ep" "$max_s")"
    else
      quota_badge="${credits} (${rate})"
    fi

    local badge=""
    local term_title=""
    if [[ "$mode" == "colab" ]]; then
      local vm_tag=""
      if [[ "$active_vms" =~ ^[0-9]+$ && "$active_vms" -gt 0 ]]; then
        vm_tag=" | ${active_vms} VM"
      fi
      if [[ -n "$email" ]]; then
        badge="\[\e[1;35m\][☁ ${hw_label}\[\e[0m\] \[\e[1;33m\]| ${quota_badge}${vm_tag}\[\e[1;35m\]]\[\e[0m\] "
        term_title="${hw_label} | ${quota_badge}"
      else
        badge="\[\e[1;31m\][☁ ${hw_label} | Run /login]\[\e[0m\] "
        term_title="${hw_label} | Run /login"
      fi
    else
      if [[ -n "$email" ]]; then
        badge="\[\e[1;32m\][🖥 ${hw_label}\[\e[0m\] \[\e[1;33m\]| Colab: ${quota_badge}\[\e[1;32m\]]\[\e[0m\] "
        term_title="${hw_label} | Colab: ${quota_badge}"
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
  /status                 Show active runtime, Google account, remaining credits/hours & VMs
  /stop                   Stop all active Colab VMs (protect compute units / quota)
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

  # --- Close / Exit Credit Protection ---
  __colab_has_active_sessions() {
    local active_vms="0"
    if [[ -f "$__COLAB_RUNNER_STATE_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$__COLAB_RUNNER_STATE_FILE" 2>/dev/null || true
      active_vms="${COLAB_RUNNER_ACTIVE_VMS:-0}"
      if [[ "$active_vms" =~ ^[0-9]+$ && "$active_vms" -gt 0 ]]; then
        return 0
      fi
    fi
    local sessions_file="$HOME/.config/colab-cli/sessions.json"
    if [[ -f "$sessions_file" ]]; then
      local trimmed
      trimmed="$(tr -d '[:space:]' < "$sessions_file" 2>/dev/null || echo "{}")"
      if [[ -n "$trimmed" && "$trimmed" != "{}" && "$trimmed" != "[]" ]]; then
        return 0
      fi
    fi
    return 1
  }

  exit() {
    if __colab_has_active_sessions; then
      echo ""
      echo -e "\033[1;31m======================================================================\033[0m"
      echo -e " \033[1;31mWARNING: ACTIVE COLAB SESSION(S) STILL RUNNING!\033[0m"
      echo -e " \033[1;33mStop them now — otherwise your Colab credits / session hours\033[0m"
      echo -e " \033[1;33mwill keep burning in the background!\033[0m"
      echo -e "\033[1;31m======================================================================\033[0m"
      local reply=""
      read -r -p "Stop all active Colab VMs before exiting? [Y/n/c(ancel)]: " reply
      case "$reply" in
        [cC]|[cC][aA][nN][cC][eE][lL])
          echo -e "\033[1;36m[Colab Runner]\033[0m Exit cancelled. Run /stop when ready."
          return 0
          ;;
        [nN]|[nN][oO])
          echo -e "\033[1;33m[Colab Runner]\033[0m Leaving Colab VM(s) running."
          ;;
        *)
          "$HOME/.local/bin/colab-switch" --stop
          ;;
      esac
    fi
    builtin exit "$@"
  }

  __colab_on_sighup() {
    if __colab_has_active_sessions && [[ -x "$HOME/.local/bin/colab-on-close" ]]; then
      nohup "$HOME/.local/bin/colab-on-close" >/dev/null 2>&1 &
    fi
  }
  trap '__colab_on_sighup' HUP

  # Tab completions
  complete -W "local local-cpu local-gpu cpu t4 l4 g4 a100 h100 v5e1 v6e1 stop --high-mem" /switch
  complete -W "--switch --check" /login
  complete -f -X '!*.@(py|ipynb)' /run
fi

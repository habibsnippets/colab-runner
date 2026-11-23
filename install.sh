#!/usr/bin/env bash
set -euo pipefail

# Pinned release tag. Override with COLAB_RUNNER_REF=main (or another tag) if you want to.
COLAB_RUNNER_VERSION="0.3.1"
COLAB_RUNNER_REF="${COLAB_RUNNER_REF:-v$COLAB_RUNNER_VERSION}"
REPO_RAW_BASE="https://raw.githubusercontent.com/habibsnippets/colab-runner/$COLAB_RUNNER_REF"
VSIX_NAME="colab-vscode-runner-$COLAB_RUNNER_VERSION.vsix"
VSIX_URL="https://github.com/habibsnippets/colab-runner/releases/download/v$COLAB_RUNNER_VERSION/$VSIX_NAME"
INSTALL_DIR="$HOME/.local/share/colab-runner"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
VENV_DIR="$INSTALL_DIR/venv"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/colab-cli"
BASHRC_FILE="$HOME/.bashrc"

export PATH="$BIN_DIR:$HOME/.cargo/bin:$PATH"

INSTALL_VSCODE_EXT=1
for arg in "$@"; do
  case "$arg" in
    --no-vscode) INSTALL_VSCODE_EXT=0 ;;
    --with-vscode) INSTALL_VSCODE_EXT=1 ;;
    -h|--help)
      echo "Usage: install.sh [--no-vscode]"
      echo "Installs google-colab-cli (>=0.8.0), colab-runner slash commands, and VS Code extension."
      echo ""
      echo "This script writes to:"
      echo "  ~/.local/share/colab-runner/   scripts (and a private venv if needed)"
      echo "  ~/.local/bin/                  colab-* command symlinks"
      echo "  ~/.config/colab-cli/           shell-init.sh"
      echo "  ~/.bashrc (and ~/.bash_profile on macOS)  a marked block, removed by uninstall.sh"
      echo ""
      echo "Env: COLAB_RUNNER_REF=<tag|branch> to install a specific ref (default v$COLAB_RUNNER_VERSION)."
      exit 0
      ;;
  esac
done

BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

echo -e "${CYAN}==> Installing Colab CLI & Colab Runner in one go...${RESET}"

mkdir -p "$SCRIPTS_DIR" "$BIN_DIR" "$CONFIG_DIR"

# 1. Install or upgrade prerequisite: google-colab-cli >= 0.8.0
echo -e "${CYAN}==> Step 1/4: Installing prerequisite (google-colab-cli >= 0.8.0)...${RESET}"

install_with_venv() {
  local py_cmd="$1"
  echo -e "${CYAN}    Creating isolated venv at $VENV_DIR...${RESET}"
  "$py_cmd" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
  "$VENV_DIR/bin/pip" install -U "google-colab-cli>=0.8.0"
  ln -sf "$VENV_DIR/bin/colab" "$BIN_DIR/colab"
}

if command -v uv >/dev/null 2>&1; then
  uv tool install -U "google-colab-cli>=0.8.0"
elif command -v curl >/dev/null 2>&1 && ! command -v pip3 >/dev/null 2>&1 && ! command -v pip >/dev/null 2>&1; then
  echo -e "${CYAN}    Installing uv to manage google-colab-cli...${RESET}"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$BIN_DIR:$HOME/.cargo/bin:$PATH"
  uv tool install -U "google-colab-cli>=0.8.0"
elif command -v python3 >/dev/null 2>&1 && python3 -m venv --help >/dev/null 2>&1; then
  install_with_venv python3
elif command -v pip3 >/dev/null 2>&1; then
  pip3 install --user -U "google-colab-cli>=0.8.0" || pip3 install --user --break-system-packages -U "google-colab-cli>=0.8.0"
elif command -v pip >/dev/null 2>&1; then
  pip install --user -U "google-colab-cli>=0.8.0" || pip install --user --break-system-packages -U "google-colab-cli>=0.8.0"
else
  echo -e "${RED}Error: Could not install google-colab-cli. Please install Python 3 (with venv/pip) or uv first.${RESET}" >&2
  exit 1
fi

COLAB_EXE="$(command -v colab || echo "$BIN_DIR/colab")"
if [[ ! -x "$COLAB_EXE" ]]; then
  echo -e "${RED}Error: 'colab' CLI was not found at $COLAB_EXE after installation.${RESET}" >&2
  exit 1
fi
echo -e "${GREEN}    Verified:${RESET} $("$COLAB_EXE" version 2>/dev/null || echo "colab installed at $COLAB_EXE")"

# 2. Install runner scripts
echo -e "${CYAN}==> Step 2/4: Installing colab-runner scripts & commands...${RESET}"
mkdir -p "$SCRIPTS_DIR/py_ipv4"
SCRIPT_FILES=(
  "colab-auth.sh"
  "colab-on-close.sh"
  "colab-shell-init.sh"
  "colab-switch.sh"
  "colab-terminal-runner.sh"
  "colab-tier-info.py"
  "local-ipynb-runner.py"
  "py_ipv4/sitecustomize.py"
)

LOCAL_REPO_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  CANDIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -d "$CANDIDATE_DIR/scripts" ]]; then
    LOCAL_REPO_DIR="$CANDIDATE_DIR"
  fi
fi

for f in "${SCRIPT_FILES[@]}"; do
  if [[ -n "$LOCAL_REPO_DIR" && -f "$LOCAL_REPO_DIR/scripts/$f" ]]; then
    cp "$LOCAL_REPO_DIR/scripts/$f" "$SCRIPTS_DIR/$f"
  else
    curl -fsSL "$REPO_RAW_BASE/scripts/$f" -o "$SCRIPTS_DIR/$f"
  fi
  chmod +x "$SCRIPTS_DIR/$f"
done

ln -sf "$SCRIPTS_DIR/colab-switch.sh" "$BIN_DIR/colab-switch"
ln -sf "$SCRIPTS_DIR/colab-terminal-runner.sh" "$BIN_DIR/colab-runner"
ln -sf "$SCRIPTS_DIR/colab-auth.sh" "$BIN_DIR/colab-login"
ln -sf "$SCRIPTS_DIR/colab-auth.sh" "$BIN_DIR/colab-logout"
ln -sf "$SCRIPTS_DIR/colab-auth.sh" "$BIN_DIR/colab-status"
ln -sf "$SCRIPTS_DIR/colab-on-close.sh" "$BIN_DIR/colab-on-close"

# 3. Configure shell integration (/switch, /run, /login, /status, /stop, prompt badge)
echo -e "${CYAN}==> Step 3/4: Configuring Bash slash commands (/switch, /run, /login, /help)...${RESET}"
cp "$SCRIPTS_DIR/colab-shell-init.sh" "$CONFIG_DIR/shell-init.sh"
chmod +x "$CONFIG_DIR/shell-init.sh"

hook_shell_rc() {
  local rc_file="$1"
  touch "$rc_file"
  if ! grep -q '\.local/bin' "$rc_file" 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc_file"
  fi

  python3 - "$rc_file" << 'EOF'
import re, sys
rc_path = sys.argv[1]
with open(rc_path, "r", encoding="utf-8") as f:
    text = f.read()

block = """# >>> COLAB_VSCODE_RUNNER_SHELL_INIT >>>
if [[ $- == *i* && -f "$HOME/.config/colab-cli/shell-init.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/colab-cli/shell-init.sh"
fi
# <<< COLAB_VSCODE_RUNNER_SHELL_INIT <<<"""

pattern = r"# >>> COLAB_VSCODE_RUNNER_SHELL_INIT >>>.*?# <<< COLAB_VSCODE_RUNNER_SHELL_INIT <<<"
if re.search(pattern, text, flags=re.S):
    text = re.sub(pattern, block, text, flags=re.S)
else:
    text = text.rstrip() + "\n\n" + block + "\n"

with open(rc_path, "w", encoding="utf-8") as f:
    f.write(text)
EOF
}

hook_shell_rc "$BASHRC_FILE"
if [[ "$(uname -s)" == "Darwin" || -f "$HOME/.bash_profile" ]]; then
  if ! grep -q '\.bashrc' "$HOME/.bash_profile" 2>/dev/null; then
    hook_shell_rc "$HOME/.bash_profile"
  fi
fi

# 4. Install VS Code extension if `code` CLI is available
echo -e "${CYAN}==> Step 4/4: Checking VS Code extension...${RESET}"
if [[ "$INSTALL_VSCODE_EXT" -eq 1 ]] && command -v code >/dev/null 2>&1; then
  VSIX_PATH="$INSTALL_DIR/$VSIX_NAME"
  if [[ -n "$LOCAL_REPO_DIR" && -f "$LOCAL_REPO_DIR/$VSIX_NAME" ]]; then
    VSIX_PATH="$LOCAL_REPO_DIR/$VSIX_NAME"
  elif ! curl -fsSL "$VSIX_URL" -o "$VSIX_PATH"; then
    VSIX_PATH=""
    echo -e "${YELLOW}    Could not download $VSIX_URL; skipping VS Code extension (CLI tools are ready).${RESET}"
  fi
  if [[ -n "$VSIX_PATH" ]]; then
    code --uninstall-extension local.colab-vscode-runner >/dev/null 2>&1 || true  # pre-0.3.1 ID
    code --install-extension "$VSIX_PATH" --force >/dev/null
    echo -e "${GREEN}    Installed VS Code extension:${RESET} habibsnippets.colab-vscode-runner@$COLAB_RUNNER_VERSION"
  fi
elif [[ "$INSTALL_VSCODE_EXT" -eq 0 ]]; then
  echo -e "${YELLOW}    Skipped VS Code extension (--no-vscode).${RESET}"
else
  echo -e "${YELLOW}    'code' CLI not found; skipping VS Code extension (CLI tools are ready).${RESET}"
fi

echo ""
echo -e "${GREEN}======================================================================${RESET}"
echo -e " ${BOLD}All set! Colab CLI + Colab Runner installed.${RESET}"
echo -e " 1. Reload your shell:  ${CYAN}source ~/.bashrc${RESET}"
echo -e " 2. Sign in to Colab:   ${CYAN}/login${RESET}"
echo -e " 3. Switch runtime:     ${CYAN}/switch t4${RESET}  (or ${CYAN}/switch cpu${RESET}, ${CYAN}/switch local${RESET})"
echo -e " 4. Run code:           ${CYAN}/run script.py${RESET}  or  ${CYAN}python notebook.ipynb${RESET}"
echo -e " 5. See all commands:   ${CYAN}/help${RESET}"
echo -e "${GREEN}======================================================================${RESET}"

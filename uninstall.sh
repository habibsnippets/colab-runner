#!/usr/bin/env bash
set -euo pipefail

echo "==> Removing Colab & Local CLI Runner..."

rm -f \
  "$HOME/.local/bin/colab-switch" \
  "$HOME/.local/bin/colab-runner" \
  "$HOME/.local/bin/colab-login" \
  "$HOME/.local/bin/colab-logout" \
  "$HOME/.local/bin/colab-status" \
  "$HOME/.local/bin/colab-on-close" \
  "$HOME/.config/colab-cli/shell-init.sh" \
  "$HOME/.config/colab-cli/vscode-runner-state.env"

rm -rf "$HOME/.local/share/colab-runner"

if [[ -f "$HOME/.bashrc" ]]; then
  python3 - "$HOME/.bashrc" << 'EOF'
import re, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    text = f.read()
text = re.sub(
    r"\n?# >>> COLAB_VSCODE_RUNNER_SHELL_INIT >>>.*?# <<< COLAB_VSCODE_RUNNER_SHELL_INIT <<<\n?",
    "\n",
    text,
    flags=re.S,
)
with open(p, "w", encoding="utf-8") as f:
    f.write(text)
EOF
fi

echo "==> Done. Open a new shell or run 'source ~/.bashrc'."

# Colab Runner (`colab-runner`)

A lightweight, CLI-first workflow (plus optional VS Code extension) to seamlessly run `.py` scripts and `.ipynb` notebooks on your **Local Machine** or **Google Colab (CPU, T4, L4, G4, A100, H100, TPU)** right from your terminal—complete with slash commands (`/switch`, `/run`, `/login`, `/status`, `/stop`) and a persistent terminal prompt showing your active runtime and remaining Colab credits.

![Colab Runner CLI /help Output](assets/colab-runner-help.png)

---

## Features

- **Slash commands in any Bash terminal:** Switch between Local CPU, Colab CPU, and Colab GPUs/TPUs with `/switch`.
- **Transparent `python` routing:** Once you `/switch t4` (or `/switch cpu`, `/switch local`), running either `/run script.py` or `python script.py` / `python notebook.ipynb` automatically executes on the active hardware.
- **Persistent prompt indicator:** Your active hardware and remaining Colab compute units stay visible in your terminal prompt across `clear`, `Ctrl+L`, and VS Code's **Clear Terminal** button.
- **Terminal-native Google Colab auth:** Connect, switch accounts, or sign out cleanly in the terminal via `/login`, `/login --switch`, and `/logout`.
- **Compute-unit safety:** Switching runtimes automatically stops previous `vscode-*` Colab VMs, and `/stop` tears down all active Colab sessions so you don't burn idle credits.

![Switching Runtimes in VS Code Terminal](assets/colab-runner-switch.png)

---

## Installation (Single Command)

Run this **one command** in your VS Code terminal or any Linux/macOS Bash terminal—it automatically installs the prerequisite (`google-colab-cli >= 0.8.0`), all slash commands (`/switch`, `/run`, `/login`, `/status`, `/stop`), and the VS Code extension (when `code` is available):

```bash
curl -fsSL https://raw.githubusercontent.com/habibsnippets/colab-runner/main/install.sh | bash
```

*(Pass `--no-vscode` if you only want the terminal CLI without installing the VS Code extension: `curl -fsSL https://raw.githubusercontent.com/habibsnippets/colab-runner/main/install.sh | bash -s -- --no-vscode`)*

### Alternative: Install from Cloned Repository

```bash
git clone https://github.com/habibsnippets/colab-runner.git
cd colab-runner
./install.sh
```

Then reload your shell (or open a new terminal):

```bash
source ~/.bashrc
```

---

## Quick Start (30 Seconds)

1. **Link your Google Colab account in the terminal:**
   ```bash
   /login
   ```
   Open the printed Google authorization URL, approve access, and paste the authorization code back into the terminal.

2. **Choose your runtime:**
   ```bash
   /switch           # Interactive menu
   /switch t4        # Or switch directly to Colab T4 GPU
   /switch cpu       # Switch to Colab CPU
   /switch local-gpu # Switch to Local Machine GPU (if CUDA/NVIDIA GPU is active)
   /switch local-cpu # Switch to Local Machine CPU
   ```

3. **Run any `.py` script or `.ipynb` notebook:**
   ```bash
   /run examples/benchmark_hardware.py
   # or simply:
   python examples/benchmark_hardware.py
   python examples/test_notebook.ipynb
   ```

4. **Check credits or stop active VMs when finished:**
   ```bash
   /status
   /stop
   ```

---

## Command Reference

| Command | Description |
| :--- | :--- |
| `/switch` | Open interactive menu (`Local CPU`, `Local GPU`, `Colab CPU`, `T4`, `L4`, `G4`, `A100`, `H100`, `TPU v5e1`/`v6e1`, `stop`) |
| `/switch <target>` | Direct switch (`local-cpu`, `local-gpu`, `cpu`, `t4`, `l4`, `g4`, `a100`, `h100`, `v5e1`, `v6e1`, `stop`; optional `--high-mem`) |
| `/run <file>` | Run a `.py` script or `.ipynb` notebook on the active runtime |
| `python <file.py\|.ipynb>` | Automatically routes single `.py` / `.ipynb` file execution to the active runtime |
| `/login [--switch]` | Sign in to Google Colab or switch accounts directly in the terminal |
| `/logout` | Sign out and clear Colab CLI credentials (keyring & legacy token file) |
| `/status` | Display active runtime, Google account, remaining credits, burn rate & active VMs |
| `/stop` | Stop all active Colab VMs to preserve compute units |
| `/help` | Show the slash command reference |

> **Note:** Underlying standalone binaries (`colab-switch`, `colab-runner`, `colab-login`, `colab-logout`, `colab-status`) are also installed in `~/.local/bin/`.

---

## Sample Hardware Benchmark (`examples/benchmark_hardware.py`)

Run `python examples/benchmark_hardware.py` across runtimes to verify active hardware and measure latency:

| Benchmark | Local Machine CPU (`i5-1135G7`) | Google Colab CPU (`Xeon @ 2.20GHz`) | Google Colab GPU (`Tesla T4`, 16 GB) |
| :--- | :---: | :---: | :---: |
| **`4096×4096` FP32 MatMul (Mean)** | `356.87 ms` (`385.1 GFLOPS`) | `2245.33 ms` (`61.2 GFLOPS`) | **`33.55 ms` (`4096.3 GFLOPS`)** |
| **3-Layer MLP Forward (`B=2048`)** | `494.93 ms` | `2889.66 ms` | **`41.19 ms`** |
| **Elementwise Ops (`16.7M` floats)** | `79.19 ms` | `283.61 ms` | **`3.46 ms`** |

---

## Uninstall

```bash
./uninstall.sh
```

## Requirements

- Linux or macOS with Bash (all prerequisites including `google-colab-cli >= 0.8.0` are installed automatically by `install.sh`)
- Python 3 (with `venv`/`pip`) or `uv`
- Google Colab account (GPU/TPU availability depends on your Colab tier/compute units)

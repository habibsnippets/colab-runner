const vscode = require('vscode');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TERMINAL_NAME = 'Colab / Local Runner';

function buildEnv() {
  const home = os.homedir();
  const extraPaths = [
    path.join(home, '.local', 'bin'),
    path.join(home, 'miniconda3', 'bin'),
    path.join(home, 'anaconda3', 'bin'),
    '/usr/local/bin',
    '/usr/bin'
  ];
  return {
    ...process.env,
    PATH: `${extraPaths.join(':')}:${process.env.PATH || ''}`
  };
}

function shellSingleQuote(str) {
  return `'${String(str).replace(/'/g, `'\\''`)}'`;
}

function installCliHelpers(extensionPath) {
  const home = os.homedir();
  const configDir = path.join(home, '.config', 'colab-cli');
  const localBinDir = path.join(home, '.local', 'bin');
  const scriptsDir = path.join(extensionPath, 'scripts');

  try {
    fs.mkdirSync(configDir, { recursive: true });
    fs.mkdirSync(localBinDir, { recursive: true });

    const shellInitSrc = path.join(scriptsDir, 'colab-shell-init.sh');
    const shellInitDst = path.join(configDir, 'shell-init.sh');
    if (fs.existsSync(shellInitSrc)) {
      fs.copyFileSync(shellInitSrc, shellInitDst);
      fs.chmodSync(shellInitDst, 0o755);
    }

    const symlinks = [
      ['colab-switch.sh', 'colab-switch'],
      ['colab-terminal-runner.sh', 'colab-runner'],
      ['colab-auth.sh', 'colab-login'],
      ['colab-auth.sh', 'colab-logout'],
      ['colab-auth.sh', 'colab-status']
    ];
    for (const [srcName, binName] of symlinks) {
      const target = path.join(scriptsDir, srcName);
      const linkPath = path.join(localBinDir, binName);
      if (fs.existsSync(target)) {
        fs.chmodSync(target, 0o755);
        try {
          if (fs.lstatSync(linkPath)) fs.unlinkSync(linkPath);
        } catch (_) {
          // Not present
        }
        fs.symlinkSync(target, linkPath);
      }
    }
  } catch (_) {
    // Non-fatal
  }
}

function getOrCreateRunnerTerminal(extensionPath) {
  let term = vscode.window.terminals.find((t) => t.name === TERMINAL_NAME);
  if (!term) {
    const shellInit = path.join(extensionPath, 'scripts', 'colab-shell-init.sh');
    const hasInit = fs.existsSync(shellInit);
    term = vscode.window.createTerminal({
      name: TERMINAL_NAME,
      shellPath: '/bin/bash',
      shellArgs: hasInit ? ['--rcfile', shellInit] : undefined,
      env: {
        PATH: buildEnv().PATH,
        ...(hasInit ? { __COLAB_RUNNER_RCFILE_MODE: '1' } : {})
      }
    });
  }
  return term;
}

function resolveActiveFilePath() {
  const activeNotebook = vscode.window.activeNotebookEditor;
  if (activeNotebook && activeNotebook.notebook && activeNotebook.notebook.uri.scheme === 'file') {
    return { fsPath: activeNotebook.notebook.uri.fsPath, doc: null, notebook: activeNotebook.notebook };
  }
  const activeEditor = vscode.window.activeTextEditor;
  if (activeEditor && activeEditor.document && activeEditor.document.uri.scheme === 'file') {
    return { fsPath: activeEditor.document.uri.fsPath, doc: activeEditor.document, notebook: null };
  }
  return null;
}

async function runFileCommand(extensionPath, uriArg) {
  let filePath = null;
  if (uriArg && uriArg.fsPath) {
    filePath = uriArg.fsPath;
  } else {
    const resolved = resolveActiveFilePath();
    if (!resolved) {
      vscode.window.showWarningMessage('Open a .py script or .ipynb notebook to run.');
      return;
    }
    if (resolved.doc && resolved.doc.isDirty) await resolved.doc.save();
    if (resolved.notebook && resolved.notebook.isDirty) await resolved.notebook.save();
    filePath = resolved.fsPath;
  }

  const ext = path.extname(filePath).toLowerCase();
  if (ext !== '.py' && ext !== '.ipynb') {
    vscode.window.showWarningMessage(`Unsupported file type "${ext}". Expected .py or .ipynb.`);
    return;
  }

  const term = getOrCreateRunnerTerminal(extensionPath);
  term.show(true);
  term.sendText(`/run ${shellSingleQuote(filePath)}`, true);
}

function openTerminalCommand(extensionPath) {
  const term = getOrCreateRunnerTerminal(extensionPath);
  term.show(true);
  term.sendText('/help', true);
}

function activate(context) {
  installCliHelpers(context.extensionPath);

  // Sync Colab status silently into state file on startup
  const statusBin = path.join(os.homedir(), '.local', 'bin', 'colab-status');
  if (fs.existsSync(statusBin)) {
    const child = execFile(statusBin, [], { env: buildEnv(), timeout: 15000 }, () => {});
    if (child && child.stdin) child.stdin.end();
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('colabRunner.runFile', (uri) => runFileCommand(context.extensionPath, uri)),
    vscode.commands.registerCommand('colabRunner.openTerminal', () => openTerminalCommand(context.extensionPath))
  );
}

function deactivate() {}

module.exports = {
  activate,
  deactivate
};

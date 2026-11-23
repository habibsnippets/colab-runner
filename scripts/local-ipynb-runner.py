#!/usr/bin/env python3
"""Lightweight local .ipynb runner with zero third-party dependencies."""

import contextlib
import io
import json
import os
import sys
import traceback


class _TeeStream(io.TextIOBase):
    def __init__(self, primary, buffer):
        self.primary = primary
        self.buffer = buffer

    def write(self, s):
        self.primary.write(s)
        self.primary.flush()
        self.buffer.write(s)
        return len(s)

    def flush(self):
        self.primary.flush()


def main():
    if len(sys.argv) < 2:
        print("Usage: local-ipynb-runner.py <notebook.ipynb>", file=sys.stderr)
        sys.exit(2)

    nb_path = os.path.abspath(sys.argv[1])
    with open(nb_path, "r", encoding="utf-8") as f:
        nb = json.load(f)

    nb_dir = os.path.dirname(nb_path)
    if nb_dir:
        os.chdir(nb_dir)
        if nb_dir not in sys.path:
            sys.path.insert(0, nb_dir)

    namespace = {"__name__": "__main__", "__file__": nb_path}
    exec_count = 0
    had_error = False

    for idx, cell in enumerate(nb.get("cells", []), start=1):
        if cell.get("cell_type") != "code":
            continue

        source = cell.get("source", "")
        if isinstance(source, list):
            source = "".join(source)

        if not source.strip():
            continue

        exec_count += 1
        cell["execution_count"] = exec_count
        cell["outputs"] = []

        first_line = source.lstrip().splitlines()[0] if source.strip() else ""
        title = f" ({first_line})" if first_line.startswith("# @title") else ""
        print(f"\n\033[1;34m--- [Cell {idx}{title}] ---\033[0m")

        stdout_buf = io.StringIO()
        stderr_buf = io.StringIO()

        try:
            code_obj = compile(source, f"{nb_path}#cell-{idx}", "exec")
            with contextlib.redirect_stdout(_TeeStream(sys.stdout, stdout_buf)), contextlib.redirect_stderr(
                _TeeStream(sys.stderr, stderr_buf)
            ):
                exec(code_obj, namespace)
        except Exception as exc:
            had_error = True
            tb_text = traceback.format_exc()
            print(tb_text, file=sys.stderr, end="")
            cell["outputs"].append(
                {
                    "output_type": "error",
                    "ename": type(exc).__name__,
                    "evalue": str(exc),
                    "traceback": tb_text.splitlines(),
                }
            )

        out_text = stdout_buf.getvalue()
        err_text = stderr_buf.getvalue()
        if out_text:
            cell["outputs"].append(
                {"output_type": "stream", "name": "stdout", "text": out_text.splitlines(keepends=True)}
            )
        if err_text:
            cell["outputs"].append(
                {"output_type": "stream", "name": "stderr", "text": err_text.splitlines(keepends=True)}
            )

        if had_error:
            break

    base, _ = os.path.splitext(nb_path)
    out_nb_path = f"{base}_local_output.ipynb"
    with open(out_nb_path, "w", encoding="utf-8") as f:
        json.dump(nb, f, indent=1)

    print(f"\n\033[2m[Local Notebook Runner] Saved executed notebook -> {out_nb_path}\033[0m")
    sys.exit(1 if had_error else 0)


if __name__ == "__main__":
    main()

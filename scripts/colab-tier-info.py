#!/usr/bin/env python3
"""Inspect Google Colab account tier (paid vs free), eligible GPUs/TPUs, and active session age."""

import contextlib
import io
import json
import os
import sys
from datetime import datetime, timezone
from urllib.parse import urljoin


def _emit(kv: dict) -> None:
    for k, v in kv.items():
        print(f"{k}={v}")


def _find_latest_session_start(active_vms: int, fallback_epoch: int) -> int:
    if active_vms <= 0:
        return 0
    if fallback_epoch > 0:
        return fallback_epoch

    history_dir = os.path.expanduser("~/.config/colab-cli/history")
    newest_ts = 0
    if os.path.isdir(history_dir):
        for fname in os.listdir(history_dir):
            if not fname.endswith(".jsonl"):
                continue
            fpath = os.path.join(history_dir, fname)
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    for line in f:
                        try:
                            ev = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if ev.get("event") == "session_created" or ev.get("type") == "session_created":
                            ts_str = ev.get("timestamp") or ev.get("ts") or ""
                            if ts_str:
                                try:
                                    dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                                    ep = int(dt.timestamp())
                                    if ep > newest_ts:
                                        newest_ts = ep
                                except ValueError:
                                    pass
                if newest_ts == 0:
                    mtime = int(os.path.getmtime(fpath))
                    if mtime > newest_ts:
                        newest_ts = mtime
            except OSError:
                continue
    return newest_ts


def _read_existing_state_epoch() -> int:
    state_file = os.path.expanduser("~/.config/colab-cli/vscode-runner-state.env")
    if not os.path.isfile(state_file):
        return 0
    try:
        with open(state_file, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("COLAB_RUNNER_SESSION_START_EPOCH="):
                    val = line.split("=", 1)[1].strip().strip("'\"")
                    return int(val) if val.isdigit() else 0
    except OSError:
        pass
    return 0


def main() -> None:
    simulate_free = os.environ.get("COLAB_RUNNER_SIMULATE_FREE", "0") == "1"
    existing_epoch = _read_existing_state_epoch()

    if simulate_free:
        sim_vms = int(os.environ.get("COLAB_RUNNER_SIMULATE_VMS", "0") or "0")
        sim_epoch = int(os.environ.get("COLAB_RUNNER_SIMULATE_EPOCH", str(existing_epoch)) or "0")
        _emit(
            {
                "SIGNED_IN": "1",
                "EMAIL": os.environ.get("COLAB_RUNNER_SIMULATE_EMAIL", "free-user@gmail.com"),
                "TIER": "free",
                "BALANCE": "0.00",
                "RATE": "0.00/hr",
                "ACTIVE_VMS": str(sim_vms),
                "ELIGIBLE_GPUS": "T4",
                "INELIGIBLE_GPUS": "G4,L4,A100,H100",
                "ELIGIBLE_TPUS": "",
                "SESSION_START_EPOCH": str(sim_epoch if sim_vms > 0 else 0),
            }
        )
        return

    try:
        from colab_cli.common import state
        from colab_cli.client import TUN_ENDPOINT

        # Inspect without noisy OAuth prompts on stderr if unauthenticated
        with contextlib.redirect_stderr(io.StringIO()):
            client = state.client
        url = urljoin(client.colab_domain, f"{TUN_ENDPOINT}/ccu-info")
        resp = client.session.get(
            url,
            params={"authuser": "0"},
            headers={"Accept": "application/json", "X-Colab-Client-Agent": "colab-cli"},
            timeout=15,
        )
        if not resp.ok:
            raise RuntimeError(f"HTTP {resp.status_code}")

        raw = resp.text
        if raw.startswith(")]}'\n"):
            raw = raw[5:]
        data = json.loads(raw)

        if isinstance(data, dict):
            balance = float(data.get("currentBalance", 0.0) or 0.0)
            rate = float(data.get("consumptionRateHourly", 0.0) or 0.0)
            active_vms = int(data.get("assignmentsCount", 0) or 0)
            eligible_gpus = [str(g).upper() for g in (data.get("eligibleGpus") or [])]
            ineligible_gpus = [str(g).upper() for g in (data.get("ineligibleGpus") or [])]
            eligible_tpus = [str(t).upper() for t in (data.get("eligibleTpus") or [])]
        elif isinstance(data, list):
            balance = float(data[0] or 0.0) if len(data) > 0 else 0.0
            rate = float(data[1] or 0.0) if len(data) > 1 else 0.0
            active_vms = int(data[2] or 0) if len(data) > 2 else 0
            eligible_gpus = [str(g).upper() for g in (data[3] or [])] if len(data) > 3 and data[3] else []
            ineligible_gpus = [str(g).upper() for g in (data[4] or [])] if len(data) > 4 and data[4] else []
            eligible_tpus = [str(t).upper() for t in (data[6] or [])] if len(data) > 6 and data[6] else []
        else:
            raise ValueError("Unexpected ccu-info payload")

        tier = "paid" if balance > 0 else "free"
        if tier == "free" and not eligible_gpus:
            eligible_gpus = ["T4"]

        email = ""
        try:
            userinfo = client.session.get("https://www.googleapis.com/oauth2/v2/userinfo", timeout=10)
            if userinfo.ok:
                email = userinfo.json().get("email", "")
        except Exception:
            pass

        sess_epoch = _find_latest_session_start(active_vms, existing_epoch)
        _emit(
            {
                "SIGNED_IN": "1" if email else "0",
                "EMAIL": email,
                "TIER": tier,
                "BALANCE": f"{balance:.2f}",
                "RATE": f"{rate:.2f}/hr",
                "ACTIVE_VMS": str(active_vms),
                "ELIGIBLE_GPUS": ",".join(eligible_gpus),
                "INELIGIBLE_GPUS": ",".join(ineligible_gpus),
                "ELIGIBLE_TPUS": ",".join(eligible_tpus),
                "SESSION_START_EPOCH": str(sess_epoch),
            }
        )
    except Exception:
        _emit(
            {
                "SIGNED_IN": "0",
                "EMAIL": "",
                "TIER": "free",
                "BALANCE": "0.00",
                "RATE": "0.00/hr",
                "ACTIVE_VMS": "0",
                "ELIGIBLE_GPUS": "T4",
                "INELIGIBLE_GPUS": "G4,L4,A100,H100",
                "ELIGIBLE_TPUS": "",
                "SESSION_START_EPOCH": "0",
            }
        )


if __name__ == "__main__":
    main()

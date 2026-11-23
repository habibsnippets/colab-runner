#!/usr/bin/env python3
"""
Hardware Verification & Latency Benchmark Script
Run on Local Machine CPU, Google Colab CPU, or Google Colab GPU (e.g. T4)
to verify active hardware and compare compute latency & throughput.
"""

import os
import platform
import statistics
import subprocess
import sys
import time


def get_cpu_model() -> str:
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or platform.machine()


def get_ram_gb() -> str:
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    kb = int(line.split()[1])
                    return f"{kb / (1024 * 1024):.1f} GB"
    except (OSError, ValueError):
        pass
    return "Unknown"


def get_nvidia_smi_info() -> str:
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.total,driver_version",
                "--format=csv,noheader",
            ],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        ).strip()
        return out or "None"
    except Exception:
        return "None"


def detect_environment() -> str:
    if os.path.exists("/content") or "COLAB_RELEASE_TAG" in os.environ or "COLAB_GPU" in os.environ:
        return "GOOGLE COLAB VM"
    return "LOCAL MACHINE"


def sync_if_cuda(torch_mod, device) -> None:
    if device.type == "cuda":
        torch_mod.cuda.synchronize()


def time_op(torch_mod, device, fn, warmup: int, iters: int) -> list[float]:
    for _ in range(warmup):
        fn()
    sync_if_cuda(torch_mod, device)

    latencies_ms = []
    for _ in range(iters):
        sync_if_cuda(torch_mod, device)
        t0 = time.perf_counter()
        fn()
        sync_if_cuda(torch_mod, device)
        t1 = time.perf_counter()
        latencies_ms.append((t1 - t0) * 1000.0)
    return latencies_ms


def main() -> None:
    try:
        import torch
        import torch.nn as nn
    except ImportError as exc:
        print(f"[ERROR] PyTorch is required for this benchmark: {exc}", file=sys.stderr)
        sys.exit(1)

    env_name = detect_environment()
    cpu_model = get_cpu_model()
    cpu_cores = os.cpu_count() or 1
    ram_gb = get_ram_gb()
    gpu_smi = get_nvidia_smi_info()

    use_cuda = torch.cuda.is_available()
    device = torch.device("cuda" if use_cuda else "cpu")

    if use_cuda:
        gpu_name = torch.cuda.get_device_name(0)
        props = torch.cuda.get_device_properties(0)
        vram_gb = props.total_memory / (1024 ** 3)
        accel_label = f"GPU: {gpu_name} ({vram_gb:.1f} GB VRAM, CUDA {torch.version.cuda})"
        warmup_gemm, iters_gemm = 8, 25
        warmup_mlp, iters_mlp = 8, 30
        warmup_elem, iters_elem = 8, 30
    else:
        accel_label = f"CPU Only ({cpu_cores} logical cores, PyTorch threads={torch.get_num_threads()})"
        warmup_gemm, iters_gemm = 2, 5
        warmup_mlp, iters_mlp = 2, 8
        warmup_elem, iters_elem = 3, 12

    print("=" * 72)
    print(" HARDWARE VERIFICATION")
    print("=" * 72)
    print(f" Environment  : {env_name}")
    print(f" Hostname     : {platform.node()}")
    print(f" OS / Python  : {platform.system()} {platform.release()} | Python {platform.python_version()}")
    print(f" CPU Model    : {cpu_model} ({cpu_cores} cores)")
    print(f" System RAM   : {ram_gb}")
    print(f" nvidia-smi   : {gpu_smi}")
    print(f" PyTorch      : {torch.__version__}")
    print(f" Active Device: {device.type.upper()} — {accel_label}")
    print("=" * 72)
    print("\nRunning latency benchmarks...")

    # 1. Dense Matrix Multiplication: 4096 x 4096 FP32 GEMM
    n = 4096
    a = torch.randn((n, n), device=device, dtype=torch.float32)
    b = torch.randn((n, n), device=device, dtype=torch.float32)
    gemm_ms = time_op(torch_mod=torch, device=device, fn=lambda: torch.matmul(a, b), warmup=warmup_gemm, iters=iters_gemm)
    gemm_mean = statistics.mean(gemm_ms)
    gemm_p50 = statistics.median(gemm_ms)
    gemm_min = min(gemm_ms)
    gemm_gflops = (2.0 * (n ** 3)) / (gemm_mean / 1000.0) / 1e9

    # 2. Neural Net 3-Layer MLP Forward Pass: Batch 2048 x 4096
    mlp = nn.Sequential(
        nn.Linear(4096, 4096),
        nn.GELU(),
        nn.Linear(4096, 4096),
        nn.GELU(),
        nn.Linear(4096, 1024),
    ).to(device)
    mlp.eval()
    x_mlp = torch.randn((2048, 4096), device=device, dtype=torch.float32)
    with torch.no_grad():
        mlp_ms = time_op(torch_mod=torch, device=device, fn=lambda: mlp(x_mlp), warmup=warmup_mlp, iters=iters_mlp)
    mlp_mean = statistics.mean(mlp_ms)
    mlp_p50 = statistics.median(mlp_ms)

    # 3. Elementwise Math Ops: 16,777,216 floats
    elem_n = 16_777_216
    x_elem = torch.randn(elem_n, device=device, dtype=torch.float32)
    elem_ms = time_op(
        torch_mod=torch,
        device=device,
        fn=lambda: torch.sin(x_elem) * torch.cos(x_elem) + torch.tanh(x_elem),
        warmup=warmup_elem,
        iters=iters_elem,
    )
    elem_mean = statistics.mean(elem_ms)
    elem_p50 = statistics.median(elem_ms)

    print("\n" + "=" * 72)
    print(f" BENCHMARK SUMMARY — {env_name} ({accel_label})")
    print("=" * 72)
    print(f" 1) 4096x4096 FP32 MatMul : Mean {gemm_mean:8.2f} ms | P50 {gemm_p50:8.2f} ms | Min {gemm_min:8.2f} ms | {gemm_gflops:8.1f} GFLOPS")
    print(f" 2) 3-Layer MLP (B=2048)  : Mean {mlp_mean:8.2f} ms | P50 {mlp_p50:8.2f} ms")
    print(f" 3) Elementwise (16.7M)   : Mean {elem_mean:8.2f} ms | P50 {elem_p50:8.2f} ms")
    print("=" * 72)


if __name__ == "__main__":
    main()

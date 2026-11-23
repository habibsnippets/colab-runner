import platform
import os

print("Hostname:", platform.node())
print("Processor:", platform.processor() or platform.machine())
print("CPU count:", os.cpu_count())

try:
    import torch
    print("PyTorch CUDA available:", torch.cuda.is_available())
    if torch.cuda.is_available():
        print("GPU Device:", torch.cuda.get_device_name(0))
except ImportError:
    print("PyTorch not installed")

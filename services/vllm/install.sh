#!/usr/bin/env bash
# ── vLLM WSL2 Install Script ─────────────────────────────────────────────────
# Run this ONCE inside Ubuntu WSL2 to set up vLLM.
# Usage:  bash /path/to/install.sh
# ─────────────────────────────────────────────────────────────────────────────
set -e

echo ""
echo "=== vLLM WSL2 Installer ==="
echo ""

# 1. Check GPU is visible
echo "[1/6] Checking GPU..."
if ! command -v nvidia-smi &>/dev/null; then
    echo "ERROR: nvidia-smi not found."
    echo "  - Make sure your NVIDIA driver is up to date on Windows (>= 525)"
    echo "  - WSL2 GPU support requires Windows 11 or Windows 10 21H2+"
    exit 1
fi
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
echo ""

# 2. Install Python 3.11 if needed (vLLM requires 3.9-3.12)
echo "[2/6] Checking Python..."
PYTHON=python3.11
if ! command -v $PYTHON &>/dev/null; then
    echo "Installing Python 3.11..."
    sudo apt-get update -qq
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update -qq
    sudo apt-get install -y python3.11 python3.11-venv python3.11-dev
fi
$PYTHON --version
echo ""

# 3. Create venv
echo "[3/6] Creating virtualenv at ~/.vllm-env..."
$PYTHON -m venv ~/.vllm-env
source ~/.vllm-env/bin/activate
pip install --upgrade pip --quiet
echo ""

# 4. Install vLLM (includes CUDA wheels)
echo "[4/6] Installing vLLM (this downloads ~5GB of CUDA wheels)..."
pip install vllm --quiet
echo "vLLM installed: $(python -c 'import vllm; print(vllm.__version__)')"
echo ""

# 5. Install huggingface_hub for model downloads
echo "[5/6] Installing huggingface_hub..."
pip install huggingface_hub --quiet
echo ""

# 6. Check available VRAM and recommend model
echo "[6/6] VRAM check:"
FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')
echo "  Free VRAM: ${FREE_MIB} MiB"
if [ "$FREE_MIB" -ge 20000 ]; then
    echo "  -> 20GB+ free: google/gemma-3-12b-it (fp16) should fit."
    echo "     (Model download: ~25GB on first run)"
elif [ "$FREE_MIB" -ge 8000 ]; then
    echo "  -> 8-20GB free: use google/gemma-3-4b-it, or quantized 12B."
    echo "     Edit start.sh and set MODEL=google/gemma-3-4b-it"
else
    echo "  -> <8GB free: use google/gemma-3-1b-it or free some VRAM."
fi
echo ""
echo "=== Install complete! ==="
echo "  Start vLLM:  bash $(dirname "$0")/start.sh"
echo ""

#!/usr/bin/env bash
# ── vLLM WSL2 Start Script ───────────────────────────────────────────────────
# Starts the vLLM OpenAI-compatible server on port 8000.
# Accessible from Windows/Docker at: http://host.docker.internal:8000/v1
# Usage:  bash /path/to/start.sh [--background]
# ─────────────────────────────────────────────────────────────────────────────

# ── Model config — edit these if needed ──────────────────────────────────────
# VRAM math for RTX 3090 (24GB):
#   Windows display/apps use ~3GB, leaving ~21GB free in WSL2.
#   Qwen/Qwen2.5-7B-Instruct  fp16 = 14GB weights → fits well (recommended)
#   Qwen/Qwen2.5-3B-Instruct  fp16 =  6GB weights → fits easily (lightweight)
#   google/gemma-3-4b-it       fp16 =  8GB weights → fits (requires HF token)
MODEL="Qwen/Qwen2.5-7B-Instruct"
PORT=8000
MAX_MODEL_LEN=8192          # 7B handles 8K context well with room to spare
GPU_MEMORY_UTIL=0.70        # Use 70% of free VRAM (conservative buffer for stability)
# ─────────────────────────────────────────────────────────────────────────────

set -e

# Activate virtualenv
VENV="$HOME/.vllm-env"
if [ ! -d "$VENV" ]; then
    echo "ERROR: venv not found at $VENV"
    echo "  Run install.sh first."
    exit 1
fi
source "$VENV/bin/activate"

# HuggingFace token (needed for gated models like Gemma)
if [ -n "$HF_TOKEN" ]; then
    export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
elif [ -f "$HOME/.hf_token" ]; then
    export HUGGING_FACE_HUB_TOKEN="$(cat $HOME/.hf_token)"
fi

# Report VRAM before starting
FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')
echo ""
echo "=== Starting vLLM ==="
echo "  Model:  $MODEL"
echo "  Port:   $PORT"
echo "  VRAM free: ${FREE_MIB} MiB"
echo ""

if [ "${1}" = "--background" ]; then
    LOG="$HOME/vllm.log"
    echo "  Logging to $LOG"
    echo "  Stop with: pkill -f 'vllm.entrypoints'"
    nohup python -m vllm.entrypoints.openai.api_server \
        --model "$MODEL" \
        --port "$PORT" \
        --max-model-len "$MAX_MODEL_LEN" \
        --gpu-memory-utilization "$GPU_MEMORY_UTIL" \
        --enforce-eager \
        --dtype half \
        --host 0.0.0.0 \
        > "$LOG" 2>&1 &
    echo "  PID: $!"
    echo ""
    echo "  Waiting for startup (model download may take a while on first run)..."
    sleep 10
    tail -20 "$LOG"
else
    # Foreground — Ctrl+C to stop
    exec python -m vllm.entrypoints.openai.api_server \
        --model "$MODEL" \
        --port "$PORT" \
        --max-model-len "$MAX_MODEL_LEN" \
        --gpu-memory-utilization "$GPU_MEMORY_UTIL" \
        --enforce-eager \
        --dtype half \
        --host 0.0.0.0
fi

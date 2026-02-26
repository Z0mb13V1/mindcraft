#!/usr/bin/env bash
# =============================================================================
# experiments/analyze.sh — Analyze a bot session or experiment run
# =============================================================================
# Usage: bash experiments/analyze.sh [run_dir] [bot_name]
#   run_dir:  path to experiments/runs/<snapshot>/ (or "latest" for most recent)
#   bot_name: specific bot to analyze (default: all bots)
#
# Outputs: JSON summary to stdout + saves to run_dir/analysis.json
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${1:-latest}"
BOT_FILTER="${2:-}"

# Resolve "latest"
if [[ "${RUN_DIR}" == "latest" ]]; then
    RUN_DIR="$(ls -dt "${SCRIPT_DIR}/runs"/*/ 2>/dev/null | head -1)"
    if [[ -z "${RUN_DIR}" ]]; then
        echo "Error: No experiment runs found. Run snapshot.sh first." >&2
        exit 1
    fi
fi

if [[ ! -d "${RUN_DIR}" ]]; then
    echo "Error: Run directory not found: ${RUN_DIR}" >&2
    exit 1
fi

echo "Analyzing: ${RUN_DIR}"
echo "==========================================="

# ── Analyze bot logs ─────────────────────────────────────────────────────────
analyze_bot() {
    local bot_name="$1"
    local bot_dir="${PROJECT_ROOT}/bots/${bot_name}"

    if [[ ! -d "${bot_dir}" ]]; then
        return
    fi

    echo ""
    echo "Bot: ${bot_name}"
    echo "-------------------------------------------"

    # Count chat history entries
    local chat_count=0
    if [[ -f "${bot_dir}/history.json" ]]; then
        chat_count=$(grep -c '"role"' "${bot_dir}/history.json" 2>/dev/null || echo 0)
    fi
    echo "  Chat messages: ${chat_count}"

    # Count action attempts from logs
    local action_count=0
    if ls "${bot_dir}"/*.log &>/dev/null; then
        action_count=$(grep -c '!newAction\|!goTo\|!collectBlocks\|!craftRecipe\|!smeltItem' "${bot_dir}"/*.log 2>/dev/null || echo 0)
    fi
    echo "  Actions attempted: ${action_count}"

    # Count deaths
    local death_count=0
    if ls "${bot_dir}"/*.log &>/dev/null; then
        death_count=$(grep -c 'death\|died\|was slain\|was killed' "${bot_dir}"/*.log 2>/dev/null || echo 0)
    fi
    echo "  Deaths: ${death_count}"

    # Memory size
    local memory_size="N/A"
    if [[ -f "${bot_dir}/memory.json" ]]; then
        memory_size="$(wc -c < "${bot_dir}/memory.json") bytes"
    fi
    echo "  Memory size: ${memory_size}"

    # Ensemble decision logs (if ensemble bot)
    local ensemble_decisions=0
    local judge_calls=0
    if ls "${bot_dir}"/*ensemble*.log "${bot_dir}"/*decision*.log &>/dev/null 2>&1; then
        ensemble_decisions=$(grep -c 'arbiter\|decision\|panel' "${bot_dir}"/*ensemble*.log "${bot_dir}"/*decision*.log 2>/dev/null || echo 0)
        judge_calls=$(grep -c 'judge\|tiebreak' "${bot_dir}"/*ensemble*.log "${bot_dir}"/*decision*.log 2>/dev/null || echo 0)
    fi
    if [[ ${ensemble_decisions} -gt 0 ]]; then
        echo "  Ensemble decisions: ${ensemble_decisions}"
        echo "  Judge tiebreaks: ${judge_calls}"
    fi
}

# Find all bots or filter to specific one
if [[ -n "${BOT_FILTER}" ]]; then
    analyze_bot "${BOT_FILTER}"
else
    for bot_dir in "${PROJECT_ROOT}"/bots/*/; do
        if [[ -d "${bot_dir}" ]]; then
            analyze_bot "$(basename "${bot_dir}")"
        fi
    done
fi

# ── Profile analysis ─────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "Profiles in snapshot:"
if [[ -d "${RUN_DIR}/profiles" ]]; then
    for profile in "${RUN_DIR}/profiles"/*.json; do
        if [[ -f "${profile}" ]]; then
            name=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "${profile}" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
            model=$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "${profile}" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
            mode=$(grep -o '"_active_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "${profile}" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
            echo "  ${name}: model=${model}, mode=${mode}"
        fi
    done
fi

# ── Git state ────────────────────────────────────────────────────────────────
echo ""
if [[ -f "${RUN_DIR}/git-state.json" ]]; then
    echo "Git state:"
    cat "${RUN_DIR}/git-state.json"
fi

echo ""
echo "Analysis complete."

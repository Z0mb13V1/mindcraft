#!/usr/bin/env bash
# =============================================================================
# experiments/compare.sh — Compare two experiment snapshots
# =============================================================================
# Usage: bash experiments/compare.sh <run_a> <run_b>
#   run_a: path to first snapshot  (e.g. experiments/runs/20260226-120000-baseline)
#   run_b: path to second snapshot (e.g. experiments/runs/20260226-140000-andy4-test)
# =============================================================================
set -euo pipefail

RUN_A="${1:?Usage: compare.sh <run_a> <run_b>}"
RUN_B="${2:?Usage: compare.sh <run_a> <run_b>}"

for dir in "${RUN_A}" "${RUN_B}"; do
    if [[ ! -d "${dir}" ]]; then
        echo "Error: Directory not found: ${dir}" >&2
        exit 1
    fi
done

NAME_A="$(basename "${RUN_A}")"
NAME_B="$(basename "${RUN_B}")"

echo "Comparing experiments:"
echo "  A: ${NAME_A}"
echo "  B: ${NAME_B}"
echo "==========================================="

# ── Git state diff ───────────────────────────────────────────────────────────
echo ""
echo "Git state:"
if [[ -f "${RUN_A}/git-state.json" && -f "${RUN_B}/git-state.json" ]]; then
    COMMIT_A=$(grep '"commit"' "${RUN_A}/git-state.json" | sed 's/.*: "\(.*\)".*/\1/' | head -c 8)
    COMMIT_B=$(grep '"commit"' "${RUN_B}/git-state.json" | sed 's/.*: "\(.*\)".*/\1/' | head -c 8)
    echo "  A: ${COMMIT_A}"
    echo "  B: ${COMMIT_B}"
    if [[ "${COMMIT_A}" == "${COMMIT_B}" ]]; then
        echo "  (Same commit)"
    else
        echo "  (Different commits)"
    fi
fi

# ── Profile diff ─────────────────────────────────────────────────────────────
echo ""
echo "Profile changes:"
if [[ -d "${RUN_A}/profiles" && -d "${RUN_B}/profiles" ]]; then
    # List all profiles across both runs
    all_profiles=$(ls "${RUN_A}/profiles/" "${RUN_B}/profiles/" 2>/dev/null | sort -u)
    for profile in ${all_profiles}; do
        file_a="${RUN_A}/profiles/${profile}"
        file_b="${RUN_B}/profiles/${profile}"
        if [[ -f "${file_a}" && -f "${file_b}" ]]; then
            if ! diff -q "${file_a}" "${file_b}" &>/dev/null; then
                echo "  CHANGED: ${profile}"
                diff --unified=2 "${file_a}" "${file_b}" | head -20 | sed 's/^/    /'
            else
                echo "  unchanged: ${profile}"
            fi
        elif [[ -f "${file_a}" && ! -f "${file_b}" ]]; then
            echo "  REMOVED: ${profile}"
        elif [[ ! -f "${file_a}" && -f "${file_b}" ]]; then
            echo "  ADDED: ${profile}"
        fi
    done
else
    echo "  (Profile snapshots not available in both runs)"
fi

# ── Settings diff ────────────────────────────────────────────────────────────
echo ""
echo "Settings changes:"
if [[ -f "${RUN_A}/settings.js" && -f "${RUN_B}/settings.js" ]]; then
    if ! diff -q "${RUN_A}/settings.js" "${RUN_B}/settings.js" &>/dev/null; then
        diff --unified=2 "${RUN_A}/settings.js" "${RUN_B}/settings.js" | head -30 | sed 's/^/  /'
    else
        echo "  (No changes)"
    fi
fi

# ── Memory diff ──────────────────────────────────────────────────────────────
echo ""
echo "Memory changes:"
if [[ -d "${RUN_A}/memories" && -d "${RUN_B}/memories" ]]; then
    for mem in "${RUN_A}/memories"/*-memory.json; do
        if [[ -f "${mem}" ]]; then
            bot=$(basename "${mem}")
            mem_b="${RUN_B}/memories/${bot}"
            size_a=$(wc -c < "${mem}")
            if [[ -f "${mem_b}" ]]; then
                size_b=$(wc -c < "${mem_b}")
                echo "  ${bot}: ${size_a}B → ${size_b}B"
            else
                echo "  ${bot}: ${size_a}B → (not present)"
            fi
        fi
    done
fi

echo ""
echo "Comparison complete."

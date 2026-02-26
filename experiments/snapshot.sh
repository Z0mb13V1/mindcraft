#!/usr/bin/env bash
# =============================================================================
# experiments/snapshot.sh — Capture experiment state before/after a run
# =============================================================================
# Usage: bash experiments/snapshot.sh [label]
#   label: optional tag for this snapshot (e.g. "baseline", "andy4-test")
#
# Creates: experiments/runs/<timestamp>-<label>/
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LABEL="${1:-snapshot}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${SCRIPT_DIR}/runs/${TIMESTAMP}-${LABEL}"

mkdir -p "${RUN_DIR}"

echo "Taking snapshot: ${RUN_DIR}"

# ── Git state ────────────────────────────────────────────────────────────────
echo "  Capturing git state..."
cat > "${RUN_DIR}/git-state.json" <<EOF
{
  "commit": "$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "branch": "$(git -C "${PROJECT_ROOT}" branch --show-current 2>/dev/null || echo 'unknown')",
  "dirty": $(git -C "${PROJECT_ROOT}" diff --quiet 2>/dev/null && echo false || echo true),
  "timestamp": "${TIMESTAMP}"
}
EOF

# ── Active profiles ──────────────────────────────────────────────────────────
echo "  Capturing active profiles..."
if [[ -f "${PROJECT_ROOT}/settings.js" ]]; then
    # Extract profile paths from settings.js (non-commented lines)
    grep -E '^\s+"\.\/profiles\/' "${PROJECT_ROOT}/settings.js" | \
        sed 's/.*"\(\.\/profiles\/[^"]*\)".*/\1/' > "${RUN_DIR}/active-profiles.txt" || true
fi

# Copy active profile JSONs
mkdir -p "${RUN_DIR}/profiles"
while IFS= read -r profile_path; do
    full_path="${PROJECT_ROOT}/${profile_path}"
    if [[ -f "${full_path}" ]]; then
        cp "${full_path}" "${RUN_DIR}/profiles/"
    fi
done < "${RUN_DIR}/active-profiles.txt" 2>/dev/null || true

# ── Settings ─────────────────────────────────────────────────────────────────
echo "  Capturing settings..."
cp "${PROJECT_ROOT}/settings.js" "${RUN_DIR}/settings.js"

# ── Bot memory summaries ─────────────────────────────────────────────────────
echo "  Capturing bot memories..."
mkdir -p "${RUN_DIR}/memories"
for bot_dir in "${PROJECT_ROOT}"/bots/*/; do
    if [[ -d "${bot_dir}" ]]; then
        bot_name="$(basename "${bot_dir}")"
        if [[ -f "${bot_dir}/memory.json" ]]; then
            cp "${bot_dir}/memory.json" "${RUN_DIR}/memories/${bot_name}-memory.json"
        fi
    fi
done

# ── Docker state (if running) ───────────────────────────────────────────────
echo "  Capturing docker state..."
if command -v docker &>/dev/null; then
    docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' \
        > "${RUN_DIR}/docker-state.txt" 2>/dev/null || echo "Docker not available" > "${RUN_DIR}/docker-state.txt"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
FILE_COUNT=$(find "${RUN_DIR}" -type f | wc -l)
echo ""
echo "Snapshot complete: ${RUN_DIR}"
echo "  Files captured: ${FILE_COUNT}"
echo "  To analyze later: bash experiments/analyze.sh ${RUN_DIR}"

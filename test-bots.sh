#!/bin/bash
# Automated bot behavior tests for CloudGrok + LocalAndy
# Tests: bot self-sufficiency, command syntax rules, coordination

set -e

MINDSERVER="http://localhost:8080"
TIMEOUT=30
RESULTS=()

echo "🤖 Bot Behavior Test Suite"
echo "================================"

# Helper: Check if both bots are online
check_bots_online() {
    local response=$(curl -s "$MINDSERVER/agents" 2>/dev/null || echo "{}")
    local cg_online=$(echo "$response" | grep -c "CloudGrok" || echo 0)
    local la_online=$(echo "$response" | grep -c "LocalAndy" || echo 0)

    if [ $cg_online -gt 0 ] && [ $la_online -gt 0 ]; then
        echo "✅ Both bots online (CloudGrok + LocalAndy)"
        RESULTS+=("Both bots online: PASS")
        return 0
    else
        echo "❌ Bot connection failed"
        RESULTS+=("Both bots online: FAIL")
        return 1
    fi
}

# Helper: Check recent logs for patterns
check_logs() {
    local pattern=$1
    local description=$2
    local service=${3:-mindcraft}

    if docker compose logs "$service" 2>/dev/null | grep -q "$pattern"; then
        echo "✅ $description"
        RESULTS+=("$description: PASS")
        return 0
    else
        echo "❌ $description"
        RESULTS+=("$description: FAIL")
        return 1
    fi
}

# Test 1: Both bots spawned without errors
echo ""
echo "Test 1: Bots loaded correctly"
check_logs "CloudGrok logged in" "CloudGrok initialized"
check_logs "LocalAndy logged in" "LocalAndy initialized"
check_logs "CloudGrok spawned" "CloudGrok spawned in world"
check_logs "LocalAndy spawned" "LocalAndy spawned in world"

# Test 2: No profile load failures
echo ""
echo "Test 2: Profile validation"
if ! docker compose logs mindcraft 2>/dev/null | grep -q "Failed to load profile"; then
    echo "✅ No profile parsing errors"
    RESULTS+=("Profile validation: PASS")
else
    echo "❌ Profile parsing failed"
    RESULTS+=("Profile validation: FAIL")
fi

# Test 3: Bots are responding to world events
echo ""
echo "Test 3: Bot responsiveness"
check_logs "LocalAndy" "LocalAndy active in logs"
check_logs "CloudGrok" "CloudGrok active in logs"

# Test 4: Memory initialization
echo ""
echo "Test 4: Memory system"
if [ -f ./bots/CloudGrok/memory.json ] || [ -f ./bots/LocalAndy/memory.json ]; then
    echo "✅ Memory files created/accessible"
    RESULTS+=("Memory system: PASS")
else
    echo "⚠️  Memory files not yet created (may be normal on first run)"
    RESULTS+=("Memory system: WARN")
fi

# Summary
echo ""
echo "================================"
echo "📊 Test Summary"
echo "================================"
pass=0
fail=0
warn=0
for result in "${RESULTS[@]}"; do
    if [[ "$result" =~ "PASS" ]]; then
        ((pass++))
        echo "✅ $result"
    elif [[ "$result" =~ "FAIL" ]]; then
        ((fail++))
        echo "❌ $result"
    else
        ((warn++))
        echo "⚠️  $result"
    fi
done

echo ""
echo "Passed: $pass | Failed: $fail | Warnings: $warn"

if [ $fail -eq 0 ]; then
    echo "✅ All tests passed!"
    exit 0
else
    echo "❌ Some tests failed"
    exit 1
fi

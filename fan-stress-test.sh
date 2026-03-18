#!/bin/bash

# fan-stress-test.sh
# Stresses random CPU cores for random intervals to test fan response.
# Total duration: ~1 minute.

set -euo pipefail

if ! command -v stress-ng &>/dev/null; then
    echo "Error: stress-ng is not installed. Please install it first (e.g., sudo apt install stress-ng)."
    exit 1
fi

TOTAL_DURATION=60
START_TIME=$(date +%s)
END_TIME=$((START_TIME + TOTAL_DURATION))
NUM_CORES=$(nproc)

echo "Starting fan stress test for ${TOTAL_DURATION} seconds..."

while [ "$(date +%s)" -lt "$END_TIME" ]; do
    CORES_TO_STRESS=$(((RANDOM % NUM_CORES) + 1))
    STRESS_SEC=$(((RANDOM % 13) + 3))
    PAUSE_SEC=$(((RANDOM % 13) + 3))

    CURRENT_TIME=$(date +%s)
    REMAINING=$((END_TIME - CURRENT_TIME))
    if [ "$REMAINING" -le 0 ]; then
        break
    fi

    if [ "$STRESS_SEC" -gt "$REMAINING" ]; then
        STRESS_SEC="$REMAINING"
    fi

    echo "Stressing $CORES_TO_STRESS cores for $STRESS_SEC seconds..."
    stress-ng --cpu "$CORES_TO_STRESS" --timeout "${STRESS_SEC}s" --quiet

    CURRENT_TIME=$(date +%s)
    REMAINING=$((END_TIME - CURRENT_TIME))
    if [ "$REMAINING" -le 3 ]; then
        break
    fi

    if [ "$PAUSE_SEC" -gt "$REMAINING" ]; then
        PAUSE_SEC="$REMAINING"
    fi

    echo "Pausing for $PAUSE_SEC seconds..."
    sleep "$PAUSE_SEC"
done

echo "Fan stress test complete."

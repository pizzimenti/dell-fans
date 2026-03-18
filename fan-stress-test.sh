#!/bin/bash

# fan-stress-test.sh
# Runs repeated full-core CPU bursts and captures fan-policy telemetry.

set -euo pipefail

if ! command -v stress-ng &>/dev/null; then
    echo "Error: stress-ng is not installed. Please install it first (e.g., sudo apt install stress-ng)."
    exit 1
fi

if ! command -v journalctl &>/dev/null; then
    echo "Error: journalctl is required."
    exit 1
fi

TOTAL_DURATION="${1:-90}"
if [[ ! "$TOTAL_DURATION" =~ ^[0-9]+$ ]] || [ "$TOTAL_DURATION" -le 0 ]; then
    echo "Usage: $0 [duration-seconds]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$SCRIPT_DIR/fan-stress-runs"
mkdir -p "$RUN_DIR"

START_EPOCH=$(date +%s)
START_STAMP="$(date '+%F %T')"
RUN_ID="$(date '+%Y%m%d-%H%M%S')"
RUN_LOG="$RUN_DIR/${RUN_ID}.log"
JOURNAL_LOG="$RUN_DIR/${RUN_ID}.journal.log"
SUMMARY_LOG="$RUN_DIR/${RUN_ID}.summary.txt"

END_TIME=$((START_EPOCH + TOTAL_DURATION))
NUM_CORES=$(nproc)

echo "Starting fan stress test for ${TOTAL_DURATION} seconds..."
echo "Run log: $RUN_LOG"
echo "Journal log: $JOURNAL_LOG"
echo "Summary: $SUMMARY_LOG"

{
    echo "run_id=$RUN_ID"
    echo "start=$START_STAMP"
    echo "duration_s=$TOTAL_DURATION"
    echo "cores=$NUM_CORES"
} >"$RUN_LOG"

while [ "$(date +%s)" -lt "$END_TIME" ]; do
    STRESS_SEC=$(((RANDOM % 9) + 7))
    PAUSE_SEC=$(((RANDOM % 9) + 7))

    CURRENT_TIME=$(date +%s)
    REMAINING=$((END_TIME - CURRENT_TIME))
    if [ "$REMAINING" -le 0 ]; then
        break
    fi

    if [ "$STRESS_SEC" -gt "$REMAINING" ]; then
        STRESS_SEC="$REMAINING"
    fi

    echo "stress cores=$NUM_CORES seconds=$STRESS_SEC" | tee -a "$RUN_LOG"
    stress-ng --cpu "$NUM_CORES" --timeout "${STRESS_SEC}s" --quiet

    CURRENT_TIME=$(date +%s)
    REMAINING=$((END_TIME - CURRENT_TIME))
    if [ "$REMAINING" -le 5 ]; then
        break
    fi

    if [ "$PAUSE_SEC" -gt "$REMAINING" ]; then
        PAUSE_SEC="$REMAINING"
    fi

    echo "pause seconds=$PAUSE_SEC" | tee -a "$RUN_LOG"
    sleep "$PAUSE_SEC"
done

END_STAMP="$(date '+%F %T')"
echo "end=$END_STAMP" >>"$RUN_LOG"

journalctl -u dell-fan-policy --since "$START_STAMP" --no-pager >"$JOURNAL_LOG"

awk '
BEGIN {
    poll = 0.5
    name[0] = "off"
    name[1] = "low"
    name[2] = "high"
    name[3] = "med"
}
/telemetry / {
    state = ""
    cpu = ""
    gpu = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^state=/) {
            split($i, a, "=")
            state = a[2] + 0
        } else if ($i ~ /^cpu=/) {
            split($i, a, "=")
            sub(/C$/, "", a[2])
            cpu = a[2] + 0
        } else if ($i ~ /^gpu=/) {
            split($i, a, "=")
            sub(/C$/, "", a[2])
            gpu = a[2] + 0
        }
    }

    if (state != "") {
        samples[state]++
        total_samples++
        if (prev_state == "" || prev_state != state) {
            transitions++
            transition_log = transition_log sprintf("%s%s", transition_log ? "," : "", name[state])
        }
        prev_state = state
    }

    if (cpu != "" && cpu > max_cpu) max_cpu = cpu
    if (gpu != "" && gpu > max_gpu) max_gpu = gpu
}
END {
    print "telemetry_samples=" total_samples
    for (s = 0; s <= 3; s++) {
        secs = samples[s] * poll
        printf("%s_samples=%d\n", name[s], samples[s] + 0)
        printf("%s_seconds=%.1f\n", name[s], secs)
    }
    print "transitions=" transitions + 0
    print "transition_sequence=" transition_log
    print "max_cpu_c=" max_cpu + 0
    print "max_gpu_c=" max_gpu + 0
}
' "$JOURNAL_LOG" >"$SUMMARY_LOG"

cat "$SUMMARY_LOG"
echo "Fan stress test complete."

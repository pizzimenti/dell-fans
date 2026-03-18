#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dell-fan-policy.sh"

max_state=2

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL %s expected=%s actual=%s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS %s -> %s\n' "$name" "$actual"
}

run_case() {
    local name="$1"
    local current="$2"
    local cpu="$3"
    local gpu="$4"
    local gpu_w="$5"
    local wifi="$6"
    local on_ac="$7"
    local expected="$8"
    local actual

    actual="$(desired_state "$current" "$cpu" "$gpu" "$gpu_w" "$wifi" "$on_ac" 0 0 "balanced")"
    assert_eq "$name" "$expected" "$actual"
}

run_case_prev() {
    local name="$1"
    local current="$2"
    local cpu="$3"
    local gpu="$4"
    local gpu_w="$5"
    local wifi="$6"
    local on_ac="$7"
    local cpu_prev="$8"
    local gpu_prev="$9"
    local expected="${10}"
    local actual

    actual="$(desired_state "$current" "$cpu" "$gpu" "$gpu_w" "$wifi" "$on_ac" "$cpu_prev" "$gpu_prev" "balanced")"
    assert_eq "$name" "$expected" "$actual"
}

assert_eq "clamp_low" "0" "$(clamp_state -1)"
assert_eq "clamp_mid" "1" "$(clamp_state 1)"
assert_eq "clamp_high" "2" "$(clamp_state 5)"

run_case "battery_idle_stays_off" 0 45 44 5 60 0 0
run_case "battery_warm_cpu_to_state1" 0 60 44 5 60 0 1
run_case "battery_warm_cpu_to_state3" 1 68 44 5 60 0 3
run_case "battery_hot_gpu_to_state1" 0 50 73 5 60 0 1
run_case "ac_gpu_power_to_state1" 0 50 50 24 60 1 1
run_case "state1_holds_without_cooldown" 1 56 55 5 60 0 1
run_case "state3_holds_until_below_66" 3 66 63 5 60 1 3
run_case "state1_drops_when_cool" 1 50 50 5 60 0 0
run_case "state1_prefers_state3_over_state2_when_hot" 1 80 64 5 60 1 3
run_case_prev "state3_escalates_to_state2_on_overshoot" 3 82 64 5 60 1 80 63 2
run_case_prev "state2_drops_to_state3_when_cooling" 2 67 64 5 60 1 72 68 3
run_case "state2_stays_state3_when_hot_band_remains" 2 80 64 5 60 1 3
run_case_prev "state2_returns_to_state1_when_cool" 2 64 63 5 60 1 64 63 1
run_case "wifi_guardrail_forces_max" 0 40 40 5 81 0 2
run_case "cpu_emergency_forces_max" 0 83 40 5 60 0 2

printf 'All policy tests passed.\n'

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
    local wifi="$5"
    local expected="$6"
    local actual

    actual="$(desired_state "$current" "$cpu" "$gpu" "$wifi" 0)"
    assert_eq "$name" "$expected" "$actual"
}

run_case_medium_time() {
    local name="$1"
    local current="$2"
    local cpu="$3"
    local gpu="$4"
    local wifi="$5"
    local medium_elapsed_ms="$6"
    local expected="$7"
    local actual

    actual="$(desired_state "$current" "$cpu" "$gpu" "$wifi" "$medium_elapsed_ms")"
    assert_eq "$name" "$expected" "$actual"
}

assert_eq "clamp_low" "0" "$(clamp_state -1)"
assert_eq "clamp_mid" "1" "$(clamp_state 1)"
assert_eq "clamp_high" "2" "$(clamp_state 5)"

run_case "idle_stays_off" 0 45 44 60 0
run_case "warm_stays_low" 1 55 54 60 1
run_case "sixty_enters_medium" 1 60 44 60 3
run_case "gpu_sixty_enters_medium" 1 50 60 60 3
run_case "medium_holds_in_band" 3 66 63 60 3
run_case_medium_time "seventy_before_hold_stays_medium" 3 70 64 60 4000 3
run_case_medium_time "gpu_seventy_before_hold_stays_medium" 3 63 70 60 4000 3
run_case_medium_time "seventy_after_hold_enters_high" 3 70 64 60 5000 2
run_case_medium_time "gpu_seventy_after_hold_enters_high" 3 63 70 60 5000 2
run_case "high_drops_to_medium_below_seventy" 2 69 64 60 3
run_case "medium_drops_to_low_below_sixty" 3 59 58 60 1
run_case "low_drops_to_off_below_forty_eight" 1 47 46 60 0
run_case "any_temp_guardrail_forces_max" 0 80 40 60 2

printf 'All policy tests passed.\n'

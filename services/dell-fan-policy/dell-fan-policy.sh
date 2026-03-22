#!/usr/bin/env bash
set -euo pipefail

# Dell stepped fan policy daemon.
#
# Targets dell_smm_hwmon systems that expose manual/BIOS mode via pwm1_enable
# and stepped manual fan levels via pwm1 or a thermal cooling_device.
#
# Policy:
# - Fan state is driven only by CPU and GPU temperatures.
# - Wi-Fi temperature is guardrail-only and can still force HIGH.
# - LOW is the warm baseline, MEDIUM covers 60C-69C, and HIGH starts at 70C.
# - HIGH requires 5 seconds already spent in MEDIUM unless the 80C guardrail trips.
# - No AC/battery logic, profile logic, trend detection, or power-based escalation.

readonly POLL_FAST_SECONDS="${POLL_FAST_SECONDS:-1}"
readonly POLL_SLOW_SECONDS="${POLL_SLOW_SECONDS:-3}"
readonly LOW_SETTLED_RPM_MARGIN="${LOW_SETTLED_RPM_MARGIN:-500}"                  # LOW timers start only after RPM is near target
readonly LOW_MISMATCH_RPM_MARGIN="${LOW_MISMATCH_RPM_MARGIN:-1500}"               # LOW mismatch if RPM stays this far above target
readonly MISMATCH_RECOVERY_POLLS="${MISMATCH_RECOVERY_POLLS:-3}"                  # consecutive mismatch polls before corrective action
readonly MISMATCH_RECOVERY_COOLDOWN_SECONDS="${MISMATCH_RECOVERY_COOLDOWN_SECONDS:-20}"
readonly MISMATCH_RECOVERY_SETTLE_SECONDS="${MISMATCH_RECOVERY_SETTLE_SECONDS:-1}"
readonly MEDIUM_HIGH_SLOT_EVERY="${MEDIUM_HIGH_SLOT_EVERY:-1}"
readonly HIGH_AFTER_MEDIUM_SECONDS="${HIGH_AFTER_MEDIUM_SECONDS:-5}"
readonly SUMMARY_INTERVAL_SECONDS="${SUMMARY_INTERVAL_SECONDS:-60}"
readonly ANY_TEMP_GUARDRAIL_C="${ANY_TEMP_GUARDRAIL_C:-80}"
readonly LOW_ON_TEMP_C="${LOW_ON_TEMP_C:-50}"
readonly MEDIUM_ON_TEMP_C="${MEDIUM_ON_TEMP_C:-60}"
readonly HIGH_ON_TEMP_C="${HIGH_ON_TEMP_C:-70}"
# Fan levels: 0=OFF  1=LOW  2=HIGH

readonly CPU_SENSOR_LABEL="${CPU_SENSOR_LABEL:-Tctl}"
readonly GPU_SENSOR_LABEL="${GPU_SENSOR_LABEL:-edge}"
readonly WIFI_SENSOR_GLOB="${WIFI_SENSOR_GLOB:-mt*_phy*-pci-*}"
readonly STATE_DIR="${STATE_DIR:-/run/dell-fan-policy}"
readonly STATE_PATH="${STATE_PATH:-$STATE_DIR/state}"

hwmon_dir=""
control_file=""
max_state=0
log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

now_ms() {
    printf '%s\n' "$(date +%s%3N)"
}

seconds_to_ms() {
    local seconds="$1"
    printf '%s\n' $(( seconds * 1000 ))
}

write_runtime_state() {
    local cpu_c="$1"
    local gpu_c="$2"
    local wifi_c="$3"
    local fan_level="$4"
    local fan_rpm="$5"
    local pwm_pct="$6"
    local policy_rule="$7"
    local medium_elapsed_ms="$8"
    local cmd_state="$9"
    local hw_state="${10}"
    local path="${11:-$STATE_PATH}"
    local tmp

    mkdir -p "$STATE_DIR"
    tmp="${path}.tmp"
    {
        printf 'timestamp=%s\n' "$(date +%s)"
        printf 'cpu_c=%s\n' "$cpu_c"
        printf 'gpu_c=%s\n' "$gpu_c"
        printf 'wifi_c=%s\n' "$wifi_c"
        printf 'fan_level=%s\n' "$fan_level"
        printf 'fan_rpm=%s\n' "$fan_rpm"
        printf 'pwm_pct=%s\n' "$pwm_pct"
        printf 'policy_rule=%s\n' "$policy_rule"
        printf 'medium_elapsed_ms=%s\n' "$medium_elapsed_ms"
        printf 'cmd_state=%s\n' "$cmd_state"
        printf 'hw_level=%s\n' "$hw_state"
    } >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$path"
}

read_first_line() {
    local path="$1"
    [[ -r "$path" ]] || return 1
    IFS= read -r line <"$path" || return 1
    printf '%s\n' "$line"
}

find_dell_hwmon_dir() {
    local dir
    for dir in /sys/class/hwmon/hwmon*; do
        [[ -d "$dir" ]] || continue
        if [[ "$(read_first_line "$dir/name" 2>/dev/null || true)" == "dell_smm" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

find_cooling_control_file() {
    local dev
    for dev in /sys/class/thermal/cooling_device*; do
        [[ -d "$dev" ]] || continue
        if [[ "$(read_first_line "$dev/type" 2>/dev/null || true)" == "dell-smm-fan1" ]]; then
            printf '%s\n' "$dev/cur_state"
            return 0
        fi
    done
    return 1
}

discover_control_path() {
    hwmon_dir="$(find_dell_hwmon_dir)" || {
        log "ERROR: dell_smm hwmon node not found"
        exit 1
    }

    # Prefer the cooling device — it uses the BIOS-defined discrete states
    # (0=off, 1=low, 2=high) which the hardware reliably responds to.
    if control_file="$(find_cooling_control_file)"; then
        max_state="$(read_first_line "${control_file%/*}/max_state" 2>/dev/null || printf '2\n')"
        if [[ ! "$max_state" =~ ^[0-9]+$ ]]; then
            max_state=2
        fi
        return 0
    fi

    if [[ -w "$hwmon_dir/pwm1" ]]; then
        control_file="$hwmon_dir/pwm1"
        max_state=2
        return 0
    fi

    log "ERROR: no writable fan control file found"
    exit 1
}

restore_bios_auto() {
    if [[ -n "$hwmon_dir" && -w "$hwmon_dir/pwm1_enable" ]]; then
        printf '2\n' >"$hwmon_dir/pwm1_enable" || true
        log "Restored BIOS auto fan control"
    fi
}

enable_manual_mode() {
    [[ -n "$hwmon_dir" ]] || return 1
    if [[ ! -w "$hwmon_dir/pwm1_enable" ]]; then
        log "ERROR: $hwmon_dir/pwm1_enable is not writable"
        exit 1
    fi
    printf '1\n' >"$hwmon_dir/pwm1_enable"
    log "Enabled manual fan control via $hwmon_dir/pwm1_enable"
}

clamp_state() {
    local value="$1"
    if (( value < 0 )); then
        printf '0\n'
    elif (( value > max_state )); then
        printf '%s\n' "$max_state"
    else
        printf '%s\n' "$value"
    fi
}

set_fan_state() {
    local requested="$1"
    local clamped
    clamped="$(clamp_state "$requested")"
    printf '%s\n' "$clamped" >"$control_file"
    log "Set fan state to $clamped via $control_file"
}

recover_fan_state_mismatch() {
    local desired_state="$1"
    local before_rpm="$2"
    local before_target="$3"
    local before_hw_state="$4"
    local bounce_state=0

    log "Attempting mismatch recovery desired=${desired_state} hw_state=${before_hw_state} rpm=${before_rpm} target=${before_target}"
    enable_manual_mode

    if (( desired_state == 1 )); then
        bounce_state=0
    elif (( desired_state >= 2 )); then
        bounce_state=1
    fi

    if (( bounce_state != desired_state )); then
        set_fan_state "$bounce_state"
        sleep "$MISMATCH_RECOVERY_SETTLE_SECONDS"
    fi
    set_fan_state "$desired_state"
}

read_sensor_value_millideg() {
    local sensor_name="$1"
    local label="$2"
    local dir label_path input_path

    for dir in /sys/class/hwmon/hwmon*; do
        [[ -d "$dir" ]] || continue
        if [[ "$(read_first_line "$dir/name" 2>/dev/null || true)" != "$sensor_name" ]]; then
            continue
        fi
        for label_path in "$dir"/temp*_label; do
            [[ -e "$label_path" ]] || continue
            if [[ "$(read_first_line "$label_path" 2>/dev/null || true)" == "$label" ]]; then
                input_path="${label_path%_label}_input"
                read_first_line "$input_path" 2>/dev/null && return 0
            fi
        done
    done
    return 1
}

read_wifi_temp_millideg() {
    local dir
    for dir in /sys/class/hwmon/hwmon*; do
        [[ -d "$dir" ]] || continue
        case "$(read_first_line "$dir/name" 2>/dev/null || true)" in
            $WIFI_SENSOR_GLOB)
                read_first_line "$dir/temp1_input" 2>/dev/null && return 0
                ;;
        esac
    done
    return 1
}

to_celsius_int() {
    local raw="$1"
    printf '%s\n' $(( raw / 1000 ))
}

read_fan_rpm() {
    read_first_line "$hwmon_dir/fan1_input" 2>/dev/null || printf '0\n'
}

read_fan_target() {
    read_first_line "$hwmon_dir/fan1_target" 2>/dev/null || printf '0\n'
}

read_pwm_value() {
    read_first_line "$hwmon_dir/pwm1" 2>/dev/null || printf '0\n'
}

read_hw_fan_state() {
    if [[ "$control_file" == /sys/class/thermal/cooling_device* ]]; then
        read_first_line "$control_file" 2>/dev/null || printf '%s\n' "$current_state"
    else
        printf '%s\n' "$current_state"
    fi
}

is_low_fan_mismatch() {
    local rpm="$1"
    local target="$2"
    local hw_state="$3"
    (( hw_state == 1 && target > 0 && rpm > target + LOW_MISMATCH_RPM_MARGIN ))
}

desired_state() {
    local current_state="$1"
    local cpu_c="$2"
    local gpu_c="$3"
    local wifi_c="$4"
    local medium_elapsed_ms="${5:-0}"
    local hottest_temp
    local hottest_guardrail_temp

    hottest_temp="$cpu_c"
    if (( gpu_c > hottest_temp )); then
        hottest_temp="$gpu_c"
    fi
    hottest_guardrail_temp="$hottest_temp"
    if (( wifi_c > hottest_guardrail_temp )); then
        hottest_guardrail_temp="$wifi_c"
    fi

    # Guardrail: any reported temperature at or above the hard limit forces HIGH.
    if (( hottest_guardrail_temp >= ANY_TEMP_GUARDRAIL_C )); then
        printf '%s\n' "$max_state"
        return 0
    fi

    # Temperature bands:
    # - 70C and up: enter HIGH only after 5s in MEDIUM, then stay HIGH while >= 70C
    # - 60C to 69C: MEDIUM
    # - 50C to 59C: LOW
    # - below 50C: OFF
    if (( current_state == 2 && hottest_temp >= HIGH_ON_TEMP_C )); then
        printf '%s\n' "$(clamp_state 2)"
    elif (( hottest_temp >= HIGH_ON_TEMP_C && medium_elapsed_ms >= HIGH_AFTER_MEDIUM_SECONDS * 1000 )); then
        printf '%s\n' "$(clamp_state 2)"
    elif (( hottest_temp >= MEDIUM_ON_TEMP_C )); then
        printf '3\n'
    elif (( hottest_temp >= LOW_ON_TEMP_C )); then
        printf '1\n'
    else
        printf '0\n'
    fi
}

policy_rule_label() {
    local logical_state="$1"
    local cpu_c="$2"
    local gpu_c="$3"
    local wifi_c="$4"
    local medium_elapsed_ms="${5:-0}"
    local hottest_temp="$cpu_c"
    local hottest_guardrail_temp="$cpu_c"

    if (( gpu_c > hottest_temp )); then
        hottest_temp="$gpu_c"
    fi
    hottest_guardrail_temp="$hottest_temp"
    if (( wifi_c > hottest_guardrail_temp )); then
        hottest_guardrail_temp="$wifi_c"
    fi

    if (( hottest_guardrail_temp >= ANY_TEMP_GUARDRAIL_C )); then
        printf 'guardrail_high\n'
    elif (( logical_state == 2 )); then
        printf 'high_band\n'
    elif (( logical_state == 3 && hottest_temp >= HIGH_ON_TEMP_C && medium_elapsed_ms < HIGH_AFTER_MEDIUM_SECONDS * 1000 )); then
        printf 'high_wait_in_medium\n'
    elif (( logical_state == 3 )); then
        printf 'medium_band\n'
    elif (( logical_state == 1 )); then
        printf 'low_band\n'
    else
        printf 'off_band\n'
    fi
}

temp_threshold_bucket() {
    local temp="$1"
    if (( temp >= ANY_TEMP_GUARDRAIL_C )); then
        printf '80+\n'
    elif (( temp >= HIGH_ON_TEMP_C )); then
        printf '70-79\n'
    elif (( temp >= MEDIUM_ON_TEMP_C )); then
        printf '60-69\n'
    elif (( temp >= LOW_ON_TEMP_C )); then
        printf '50-59\n'
    else
        printf '<50\n'
    fi
}

requires_fast_poll() {
    local cpu_c="$1"
    local gpu_c="$2"
    local wifi_c="$3"
    local temp

    for temp in "$cpu_c" "$gpu_c" "$wifi_c"; do
        if (( temp >= ANY_TEMP_GUARDRAIL_C - 3 )); then
            return 0
        fi
        if (( temp >= LOW_ON_TEMP_C - 3 && temp <= LOW_ON_TEMP_C + 3 )); then
            return 0
        fi
        if (( temp >= MEDIUM_ON_TEMP_C - 3 && temp <= MEDIUM_ON_TEMP_C + 3 )); then
            return 0
        fi
        if (( temp >= HIGH_ON_TEMP_C - 3 && temp <= HIGH_ON_TEMP_C + 3 )); then
            return 0
        fi
    done
    return 1
}

highest_guardrail_temp() {
    local cpu_c="$1"
    local gpu_c="$2"
    local wifi_c="$3"
    local hottest="$cpu_c"

    if (( gpu_c > hottest )); then
        hottest="$gpu_c"
    fi
    if (( wifi_c > hottest )); then
        hottest="$wifi_c"
    fi
    printf '%s\n' "$hottest"
}

commanded_hw_state() {
    local logical_state="$1"
    local medium_phase="$2"
    case "$logical_state" in
        3)
            # The hardware exposes only OFF/LOW/HIGH, so MEDIUM is synthesized
            # as a repeating HIGH/LOW cadence.
            if (( medium_phase == 0 )); then
                printf '%s\n' "$(clamp_state 2)"
            else
                printf '1\n'
            fi
            ;;
        *)
            printf '%s\n' "$(clamp_state "$logical_state")"
            ;;
    esac
}

main() {
    discover_control_path
    trap 'restore_bios_auto' EXIT INT TERM HUP
    enable_manual_mode

    local cpu_raw gpu_raw wifi_raw cpu_c gpu_c wifi_c
    local fan_rpm fan_target pwm_value hw_fan_state cmd_state last_cmd_state=-1 low_fan_mismatch=0
    local mismatch_polls=0 last_recovery_epoch=0 medium_phase=0
    local current_state next_state now medium_entered_epoch=0 medium_elapsed_ms=0
    local mismatch_recovery_cooldown_ms summary_interval_ms poll_sleep_seconds
    local last_summary_epoch=0 summary_samples=0 recovery_events=0 mismatch_events=0
    local sum_cpu=0 sum_gpu=0 sum_rpm=0 state0_samples=0 state1_samples=0 state2_samples=0 state3_samples=0
    local policy_rule threshold_bucket prev_threshold_bucket="" telemetry_due=0 trigger_temp
    local last_telemetry_epoch=0 prev_logged_state=-1 prev_logged_cmd_state=-1 prev_policy_rule=""

    mismatch_recovery_cooldown_ms="$(seconds_to_ms "$MISMATCH_RECOVERY_COOLDOWN_SECONDS")"
    summary_interval_ms="$(seconds_to_ms "$SUMMARY_INTERVAL_SECONDS")"

    current_state=0
    set_fan_state "$current_state"

    while true; do
        if ! cpu_raw="$(read_sensor_value_millideg "k10temp" "$CPU_SENSOR_LABEL" 2>/dev/null)"; then
            log "WARNING: CPU sensor unavailable; forcing max fan state"
            current_state="$(clamp_state "$max_state")"
            set_fan_state "$current_state"
            sleep "$POLL_FAST_SECONDS"
            continue
        fi

        if ! gpu_raw="$(read_sensor_value_millideg "amdgpu" "$GPU_SENSOR_LABEL" 2>/dev/null)"; then
            log "WARNING: GPU sensor unavailable; forcing max fan state"
            current_state="$(clamp_state "$max_state")"
            set_fan_state "$current_state"
            sleep "$POLL_FAST_SECONDS"
            continue
        fi

        wifi_raw="$(read_wifi_temp_millideg 2>/dev/null || printf '0\n')"

        cpu_c="$(to_celsius_int "$cpu_raw")"
        gpu_c="$(to_celsius_int "$gpu_raw")"
        wifi_c="$(to_celsius_int "$wifi_raw")"

        fan_rpm="$(read_fan_rpm)"
        fan_target="$(read_fan_target)"
        pwm_value="$(read_pwm_value)"
        hw_fan_state="$(read_hw_fan_state)"

        now="$(now_ms)"

        if (( current_state == 1 )); then
            if is_low_fan_mismatch "$fan_rpm" "$fan_target" "$hw_fan_state"; then
                low_fan_mismatch=1
                mismatch_polls=$(( mismatch_polls + 1 ))
            else
                low_fan_mismatch=0
                mismatch_polls=0
            fi
        else
            low_fan_mismatch=0
            mismatch_polls=0
        fi

        if (( current_state == 3 )); then
            if (( medium_entered_epoch == 0 )); then
                medium_entered_epoch="$now"
            fi
            medium_elapsed_ms=$(( now - medium_entered_epoch ))
        else
            medium_entered_epoch=0
            medium_elapsed_ms=0
        fi

        next_state="$(desired_state "$current_state" "$cpu_c" "$gpu_c" "$wifi_c" "$medium_elapsed_ms")"

        if (( next_state != current_state )); then
            current_state="$next_state"
            medium_phase=0
            if (( current_state == 3 )); then
                medium_entered_epoch="$now"
                medium_elapsed_ms=0
            else
                medium_entered_epoch=0
                medium_elapsed_ms=0
            fi
        fi

        cmd_state="$(commanded_hw_state "$current_state" "$medium_phase")"
        if (( current_state == 3 || cmd_state != last_cmd_state )); then
            set_fan_state "$cmd_state"
            last_cmd_state="$cmd_state"
        fi
        if (( current_state == 3 )); then
            medium_phase=$(( (medium_phase + 1) % MEDIUM_HIGH_SLOT_EVERY ))
        else
            medium_phase=0
        fi

        if (( current_state == 1 && low_fan_mismatch )); then
            if (( mismatch_polls >= MISMATCH_RECOVERY_POLLS \
               && now - last_recovery_epoch >= mismatch_recovery_cooldown_ms )); then
                recover_fan_state_mismatch "$current_state" "$fan_rpm" "$fan_target" "$hw_fan_state"
                last_recovery_epoch="$now"
                mismatch_polls=0
                recovery_events=$(( recovery_events + 1 ))
                fan_rpm="$(read_fan_rpm)"
                fan_target="$(read_fan_target)"
                pwm_value="$(read_pwm_value)"
                hw_fan_state="$(read_hw_fan_state)"
                if is_low_fan_mismatch "$fan_rpm" "$fan_target" "$hw_fan_state"; then
                    low_fan_mismatch=1
                fi
            fi
        fi

        policy_rule="$(policy_rule_label "$current_state" "$cpu_c" "$gpu_c" "$wifi_c" "$medium_elapsed_ms")"
        trigger_temp="$(highest_guardrail_temp "$cpu_c" "$gpu_c" "$wifi_c")"
        threshold_bucket="$(temp_threshold_bucket "$trigger_temp")"
        if (( last_telemetry_epoch == 0 || now - last_telemetry_epoch >= summary_interval_ms )); then
            telemetry_due=1
        else
            telemetry_due=0
        fi
        if [[ "$threshold_bucket" != "$prev_threshold_bucket" ]]; then
            telemetry_due=1
            prev_threshold_bucket="$threshold_bucket"
        fi
        if (( current_state != prev_logged_state || cmd_state != prev_logged_cmd_state )) || [[ "$policy_rule" != "$prev_policy_rule" ]]; then
            telemetry_due=1
        fi
        if (( telemetry_due )); then
            log "telemetry cpu=${cpu_c}C gpu=${gpu_c}C wifi=${wifi_c}C state=${current_state} cmd_state=${cmd_state} hw_state=${hw_fan_state} rpm=${fan_rpm} target=${fan_target} pwm=${pwm_value} medium_elapsed_ms=${medium_elapsed_ms} low_mismatch=${low_fan_mismatch} mismatch_polls=${mismatch_polls} policy_rule=${policy_rule} threshold_bucket=${threshold_bucket}"
            last_telemetry_epoch="$now"
            prev_logged_state="$current_state"
            prev_logged_cmd_state="$cmd_state"
            prev_policy_rule="$policy_rule"
        fi
        if (( low_fan_mismatch )); then
            log "WARNING: LOW mismatch hw_state=${hw_fan_state} rpm=${fan_rpm} target=${fan_target} pwm=${pwm_value}"
            mismatch_events=$(( mismatch_events + 1 ))
        fi
        write_runtime_state \
            "$cpu_c" \
            "$gpu_c" \
            "$wifi_c" \
            "$current_state" \
            "$fan_rpm" \
            "$(( pwm_value * 100 / 255 ))" \
            "$policy_rule" \
            "$medium_elapsed_ms" \
            "$cmd_state" \
            "$hw_fan_state"
        summary_samples=$(( summary_samples + 1 ))
        sum_cpu=$(( sum_cpu + cpu_c ))
        sum_gpu=$(( sum_gpu + gpu_c ))
        sum_rpm=$(( sum_rpm + fan_rpm ))
        case "$current_state" in
            0) state0_samples=$(( state0_samples + 1 )) ;;
            1) state1_samples=$(( state1_samples + 1 )) ;;
            2) state2_samples=$(( state2_samples + 1 )) ;;
            3) state3_samples=$(( state3_samples + 1 )) ;;
        esac
        if (( last_summary_epoch == 0 )); then
            last_summary_epoch="$now"
        elif (( now - last_summary_epoch >= summary_interval_ms )); then
            if (( summary_samples > 0 )); then
                log "summary samples=${summary_samples} avg_cpu=$(( sum_cpu / summary_samples ))C avg_gpu=$(( sum_gpu / summary_samples ))C avg_rpm=$(( sum_rpm / summary_samples )) states=off:${state0_samples},low:${state1_samples},high:${state2_samples},med:${state3_samples} mismatch_events=${mismatch_events} recoveries=${recovery_events}"
            fi
            last_summary_epoch="$now"
            summary_samples=0
            sum_cpu=0
            sum_gpu=0
            sum_rpm=0
            state0_samples=0
            state1_samples=0
            state2_samples=0
            state3_samples=0
            mismatch_events=0
            recovery_events=0
        fi
        if requires_fast_poll "$cpu_c" "$gpu_c" "$wifi_c"; then
            poll_sleep_seconds="$POLL_FAST_SECONDS"
        else
            poll_sleep_seconds="$POLL_SLOW_SECONDS"
        fi
        sleep "$poll_sleep_seconds"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

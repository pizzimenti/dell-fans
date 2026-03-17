#!/usr/bin/env bash
set -euo pipefail

# Dell stepped fan policy daemon.
#
# Targets dell_smm_hwmon systems that expose manual/BIOS mode via pwm1_enable
# and stepped manual fan levels via pwm1 or a thermal cooling_device.
#
# Policy:
# - CPU and GPU temperatures are primary inputs.
# - GPU package power can force a higher state on AC.
# - Wi-Fi temperature is guardrail-only and does not affect normal fan states.
# - Fan ramps up quickly and ramps down slowly via hysteresis + dwell time.

readonly POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-0.5}"
readonly HIGH_HOLD_SECONDS="${HIGH_HOLD_SECONDS:-30}"  # HIGH must run this long before stepping to LOW
readonly LOW_HOLD_SECONDS="${LOW_HOLD_SECONDS:-30}"    # LOW must run this long before stepping to OFF
readonly LOW_DWELL_SECONDS="${LOW_DWELL_SECONDS:-20}"  # LOW must run this long before HIGH is allowed
readonly EARLY_HIGH_TO_LOW_HOLD_SECONDS="${EARLY_HIGH_TO_LOW_HOLD_SECONDS:-12}"  # minimum HIGH time before predictive step-down
readonly EARLY_HIGH_TO_LOW_MARGIN_C="${EARLY_HIGH_TO_LOW_MARGIN_C:-5}"            # allow early LOW this close to normal thresholds
readonly EARLY_HIGH_TO_LOW_DROP_C="${EARLY_HIGH_TO_LOW_DROP_C:-2}"                # require a meaningful cooling trend
readonly EARLY_HIGH_TO_MEDIUM_HOLD_SECONDS="${EARLY_HIGH_TO_MEDIUM_HOLD_SECONDS:-6}"
readonly EARLY_HIGH_TO_MEDIUM_MARGIN_C="${EARLY_HIGH_TO_MEDIUM_MARGIN_C:-12}"
readonly LOW_SETTLED_RPM_MARGIN="${LOW_SETTLED_RPM_MARGIN:-500}"                  # LOW timers start only after RPM is near target
readonly LOW_MISMATCH_RPM_MARGIN="${LOW_MISMATCH_RPM_MARGIN:-1500}"               # LOW mismatch if RPM stays this far above target
readonly MISMATCH_RECOVERY_POLLS="${MISMATCH_RECOVERY_POLLS:-3}"                  # consecutive mismatch polls before corrective action
readonly MISMATCH_RECOVERY_COOLDOWN_SECONDS="${MISMATCH_RECOVERY_COOLDOWN_SECONDS:-20}"
readonly MISMATCH_RECOVERY_SETTLE_SECONDS="${MISMATCH_RECOVERY_SETTLE_SECONDS:-1}"
readonly MEDIUM_UP_CPU_C="${MEDIUM_UP_CPU_C:-63}"        # performance-mode synthetic medium
readonly MEDIUM_UP_GPU_C="${MEDIUM_UP_GPU_C:-60}"
readonly MEDIUM_UP_GPU_W="${MEDIUM_UP_GPU_W:-15}"
readonly MEDIUM_DOWN_CPU_C="${MEDIUM_DOWN_CPU_C:-58}"
readonly MEDIUM_DOWN_GPU_C="${MEDIUM_DOWN_GPU_C:-56}"
readonly MEDIUM_DOWN_GPU_W="${MEDIUM_DOWN_GPU_W:-12}"
readonly MEDIUM_HIGH_SLOT_EVERY="${MEDIUM_HIGH_SLOT_EVERY:-3}"  # 1 HIGH slot every N polls, rest LOW
readonly SUMMARY_INTERVAL_SECONDS="${SUMMARY_INTERVAL_SECONDS:-60}"
readonly WIFI_GUARDRAIL_C="${WIFI_GUARDRAIL_C:-80}"
readonly CPU_EMERGENCY_C="${CPU_EMERGENCY_C:-82}"
readonly GPU_EMERGENCY_C="${GPU_EMERGENCY_C:-80}"
# Fan levels: 0=OFF  1=LOW  2=HIGH
readonly GPU_POWER_MAX_ON_AC_W="${GPU_POWER_MAX_ON_AC_W:-30}"   # → high, AC only

readonly AC_UP_STATE1_CPU_C="${AC_UP_STATE1_CPU_C:-55}"   # → low
readonly AC_UP_STATE1_GPU_C="${AC_UP_STATE1_GPU_C:-55}"
readonly AC_UP_STATE2_CPU_C="${AC_UP_STATE2_CPU_C:-75}"   # → high
readonly AC_UP_STATE2_GPU_C="${AC_UP_STATE2_GPU_C:-72}"
readonly AC_DOWN_STATE0_CPU_C="${AC_DOWN_STATE0_CPU_C:-50}"  # low→off
readonly AC_DOWN_STATE0_GPU_C="${AC_DOWN_STATE0_GPU_C:-50}"
readonly AC_DOWN_STATE1_CPU_C="${AC_DOWN_STATE1_CPU_C:-70}"  # high→low
readonly AC_DOWN_STATE1_GPU_C="${AC_DOWN_STATE1_GPU_C:-67}"

readonly BAT_UP_STATE1_CPU_C="${BAT_UP_STATE1_CPU_C:-58}"  # → low
readonly BAT_UP_STATE1_GPU_C="${BAT_UP_STATE1_GPU_C:-58}"
readonly BAT_UP_STATE2_CPU_C="${BAT_UP_STATE2_CPU_C:-75}"  # → high
readonly BAT_UP_STATE2_GPU_C="${BAT_UP_STATE2_GPU_C:-72}"
readonly BAT_DOWN_STATE0_CPU_C="${BAT_DOWN_STATE0_CPU_C:-52}"  # low→off
readonly BAT_DOWN_STATE0_GPU_C="${BAT_DOWN_STATE0_GPU_C:-52}"
readonly BAT_DOWN_STATE1_CPU_C="${BAT_DOWN_STATE1_CPU_C:-70}"  # high→low
readonly BAT_DOWN_STATE1_GPU_C="${BAT_DOWN_STATE1_GPU_C:-67}"

readonly CPU_SENSOR_LABEL="${CPU_SENSOR_LABEL:-Tctl}"
readonly GPU_SENSOR_LABEL="${GPU_SENSOR_LABEL:-edge}"
readonly GPU_POWER_LABEL="${GPU_POWER_LABEL:-PPT}"
readonly WIFI_SENSOR_GLOB="${WIFI_SENSOR_GLOB:-mt*_phy*-pci-*}"

hwmon_dir=""
control_file=""
max_state=0
platform_profile_path="/sys/firmware/acpi/platform_profile"

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

format_tenths_s() {
    local ms="$1"
    printf '%d.%01d' $(( ms / 1000 )) $(( (ms % 1000) / 100 ))
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

read_power_value_microwatts() {
    local sensor_name="$1"
    local label="$2"
    local dir label_path input_path avg_path

    for dir in /sys/class/hwmon/hwmon*; do
        [[ -d "$dir" ]] || continue
        if [[ "$(read_first_line "$dir/name" 2>/dev/null || true)" != "$sensor_name" ]]; then
            continue
        fi
        for label_path in "$dir"/power*_label; do
            [[ -e "$label_path" ]] || continue
            if [[ "$(read_first_line "$label_path" 2>/dev/null || true)" == "$label" ]]; then
                input_path="${label_path%_label}_input"
                avg_path="${label_path%_label}_average"
                if [[ -r "$avg_path" ]]; then
                    read_first_line "$avg_path" 2>/dev/null && return 0
                fi
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

is_on_ac_power() {
    local battery_dir battery_status
    for battery_dir in /sys/class/power_supply/*; do
        [[ -d "$battery_dir" ]] || continue
        [[ "$(read_first_line "$battery_dir/type" 2>/dev/null || true)" == "Battery" ]] || continue
        battery_status="$(read_first_line "$battery_dir/status" 2>/dev/null || true)"
        case "$battery_status" in
            Charging|Full|Not\ charging)
                return 0
                ;;
            Discharging)
                return 1
                ;;
        esac
    done

    local ps
    for ps in /sys/class/power_supply/*; do
        [[ -d "$ps" ]] || continue
        case "$(read_first_line "$ps/type" 2>/dev/null || true)" in
            Mains)
                [[ "$(read_first_line "$ps/online" 2>/dev/null || true)" == "1" ]] && return 0
                ;;
            USB)
                [[ "$(read_first_line "$ps/online" 2>/dev/null || true)" == "1" ]] && return 0
                ;;
        esac
    done
    return 1
}

to_celsius_int() {
    local raw="$1"
    printf '%s\n' $(( raw / 1000 ))
}

to_watts_int() {
    local raw="$1"
    printf '%s\n' $(( raw / 1000000 ))
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

read_platform_profile() {
    read_first_line "$platform_profile_path" 2>/dev/null || printf 'balanced\n'
}

is_low_fan_settled() {
    local rpm="$1"
    local target="$2"
    local hw_state="$3"
    (( hw_state == 1 && target > 0 && rpm <= target + LOW_SETTLED_RPM_MARGIN ))
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
    local gpu_w="$4"
    local wifi_c="$5"
    local on_ac="$6"
    local low_dwell_met="$7"   # 1 if LOW has been held long enough to allow HIGH
    local cpu_prev_c="$8"
    local gpu_prev_c="$9"
    local platform_profile="${10}"
    local low_ready="${11}"

    # Emergency: always max, bypasses dwell and step-through
    if (( cpu_c >= CPU_EMERGENCY_C || gpu_c >= GPU_EMERGENCY_C || wifi_c >= WIFI_GUARDRAIL_C )); then
        printf '%s\n' "$max_state"
        return 0
    fi

    local up1_cpu up1_gpu up2_cpu up2_gpu down0_cpu down0_gpu down1_cpu down1_gpu
    if (( on_ac == 1 )); then
        up1_cpu="$AC_UP_STATE1_CPU_C";   up1_gpu="$AC_UP_STATE1_GPU_C"
        up2_cpu="$AC_UP_STATE2_CPU_C";   up2_gpu="$AC_UP_STATE2_GPU_C"
        down0_cpu="$AC_DOWN_STATE0_CPU_C"; down0_gpu="$AC_DOWN_STATE0_GPU_C"
        down1_cpu="$AC_DOWN_STATE1_CPU_C"; down1_gpu="$AC_DOWN_STATE1_GPU_C"
    else
        up1_cpu="$BAT_UP_STATE1_CPU_C";  up1_gpu="$BAT_UP_STATE1_GPU_C"
        up2_cpu="$BAT_UP_STATE2_CPU_C";  up2_gpu="$BAT_UP_STATE2_GPU_C"
        down0_cpu="$BAT_DOWN_STATE0_CPU_C"; down0_gpu="$BAT_DOWN_STATE0_GPU_C"
        down1_cpu="$BAT_DOWN_STATE1_CPU_C"; down1_gpu="$BAT_DOWN_STATE1_GPU_C"
    fi

    local wants_high=0 wants_low=0 wants_medium=0 early_low_ok=0 early_medium_ok=0
    if (( cpu_c >= up2_cpu || gpu_c >= up2_gpu || (on_ac == 1 && gpu_w >= GPU_POWER_MAX_ON_AC_W) )); then
        wants_high=1
    fi
    if (( cpu_c >= up1_cpu || gpu_c >= up1_gpu )); then
        wants_low=1
    fi
    if [[ "$platform_profile" == "performance" ]]; then
        if (( cpu_c >= MEDIUM_UP_CPU_C || gpu_c >= MEDIUM_UP_GPU_C || gpu_w >= MEDIUM_UP_GPU_W )); then
            wants_medium=1
        elif (( current_state == 3 )) && (( cpu_c >= MEDIUM_DOWN_CPU_C || gpu_c >= MEDIUM_DOWN_GPU_C || gpu_w >= MEDIUM_DOWN_GPU_W )); then
            wants_medium=1
        fi
    fi
    if (( cpu_prev_c > 0 || gpu_prev_c > 0 )); then
        if (( cpu_c <= down1_cpu + EARLY_HIGH_TO_LOW_MARGIN_C \
           && gpu_c <= down1_gpu + EARLY_HIGH_TO_LOW_MARGIN_C \
           && cpu_prev_c - cpu_c >= EARLY_HIGH_TO_LOW_DROP_C \
           && gpu_prev_c - gpu_c >= 0 \
           && (on_ac == 0 || gpu_w < GPU_POWER_MAX_ON_AC_W) )); then
            early_low_ok=1
        elif (( cpu_c <= down1_cpu + EARLY_HIGH_TO_LOW_MARGIN_C \
             && gpu_c <= down1_gpu + EARLY_HIGH_TO_LOW_MARGIN_C \
             && gpu_prev_c - gpu_c >= EARLY_HIGH_TO_LOW_DROP_C \
             && cpu_prev_c - cpu_c >= 0 \
             && (on_ac == 0 || gpu_w < GPU_POWER_MAX_ON_AC_W) )); then
            early_low_ok=1
        fi
        if (( wants_medium && ! wants_high \
           && cpu_c <= down1_cpu + EARLY_HIGH_TO_MEDIUM_MARGIN_C \
           && gpu_c <= down1_gpu + EARLY_HIGH_TO_MEDIUM_MARGIN_C \
           && cpu_prev_c >= cpu_c && gpu_prev_c >= gpu_c \
           && (cpu_prev_c - cpu_c >= 1 || gpu_prev_c - gpu_c >= 1) \
           && (on_ac == 0 || gpu_w < GPU_POWER_MAX_ON_AC_W) )); then
            early_medium_ok=1
        fi
    fi

    case "$current_state" in
        0)  # OFF: step-through — can only go to LOW, never skip to HIGH
            if (( wants_low || wants_high )); then
                printf '1\n'
            else
                printf '0\n'
            fi
            ;;
        1)  # LOW: can go to HIGH only after dwell period
            if (( wants_high && low_dwell_met )); then
                printf '%s\n' "$(clamp_state 2)"
            elif (( wants_medium && low_ready )); then
                printf '3\n'
            elif (( cpu_c <= down0_cpu && gpu_c <= down0_gpu )); then
                printf '0\n'
            else
                printf '1\n'
            fi
            ;;
        3)  # MED: synthetic medium using a LOW/HIGH duty cycle
            if (( wants_high )); then
                printf '%s\n' "$(clamp_state 2)"
            elif (( wants_medium )); then
                printf '3\n'
            else
                printf '1\n'
            fi
            ;;
        *)  # HIGH: cool down when temps drop
            if (( cpu_c <= down1_cpu && gpu_c <= down1_gpu && (on_ac == 0 || gpu_w < GPU_POWER_MAX_ON_AC_W) )); then
                if (( wants_medium )); then
                    printf '3\n'
                else
                    printf '1\n'
                fi
            elif (( early_medium_ok )); then
                printf '3\n'
            elif (( early_low_ok )); then
                if (( wants_medium )); then
                    printf '3\n'
                else
                    printf '1\n'
                fi
            else
                printf '%s\n' "$(clamp_state 2)"
            fi
            ;;
    esac
}

commanded_hw_state() {
    local logical_state="$1"
    local medium_phase="$2"
    case "$logical_state" in
        3)
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

    local cpu_raw gpu_raw gpu_power_raw wifi_raw cpu_c gpu_c gpu_w wifi_c platform_profile
    local prev_cpu_c=0 prev_gpu_c=0
    local fan_rpm fan_target pwm_value hw_fan_state cmd_state last_cmd_state=-1 low_fan_settled=0 low_fan_mismatch=0
    local mismatch_polls=0 last_recovery_epoch=0 medium_phase=0
    local on_ac current_state next_state low_dwell_met step_down_hold_seconds
    local last_change_epoch=0 low_entered_epoch=0 now low_dwell_elapsed=0
    local high_hold_ms low_hold_ms low_dwell_ms early_high_to_low_hold_ms early_high_to_medium_hold_ms mismatch_recovery_cooldown_ms summary_interval_ms
    local last_summary_epoch=0 summary_samples=0 recovery_events=0 mismatch_events=0
    local sum_cpu=0 sum_gpu=0 sum_gpu_w=0 sum_rpm=0 state0_samples=0 state1_samples=0 state2_samples=0 state3_samples=0

    high_hold_ms="$(seconds_to_ms "$HIGH_HOLD_SECONDS")"
    low_hold_ms="$(seconds_to_ms "$LOW_HOLD_SECONDS")"
    low_dwell_ms="$(seconds_to_ms "$LOW_DWELL_SECONDS")"
    early_high_to_low_hold_ms="$(seconds_to_ms "$EARLY_HIGH_TO_LOW_HOLD_SECONDS")"
    early_high_to_medium_hold_ms="$(seconds_to_ms "$EARLY_HIGH_TO_MEDIUM_HOLD_SECONDS")"
    mismatch_recovery_cooldown_ms="$(seconds_to_ms "$MISMATCH_RECOVERY_COOLDOWN_SECONDS")"
    summary_interval_ms="$(seconds_to_ms "$SUMMARY_INTERVAL_SECONDS")"

    current_state=0
    set_fan_state "$current_state"

    while true; do
        if ! cpu_raw="$(read_sensor_value_millideg "k10temp" "$CPU_SENSOR_LABEL" 2>/dev/null)"; then
            log "WARNING: CPU sensor unavailable; forcing max fan state"
            current_state="$(clamp_state "$max_state")"
            set_fan_state "$current_state"
            sleep "$POLL_INTERVAL_SECONDS"
            continue
        fi

        if ! gpu_raw="$(read_sensor_value_millideg "amdgpu" "$GPU_SENSOR_LABEL" 2>/dev/null)"; then
            log "WARNING: GPU sensor unavailable; forcing max fan state"
            current_state="$(clamp_state "$max_state")"
            set_fan_state "$current_state"
            sleep "$POLL_INTERVAL_SECONDS"
            continue
        fi

        gpu_power_raw="$(read_power_value_microwatts "amdgpu" "$GPU_POWER_LABEL" 2>/dev/null || printf '0\n')"
        wifi_raw="$(read_wifi_temp_millideg 2>/dev/null || printf '0\n')"

        cpu_c="$(to_celsius_int "$cpu_raw")"
        gpu_c="$(to_celsius_int "$gpu_raw")"
        gpu_w="$(to_watts_int "$gpu_power_raw")"
        wifi_c="$(to_celsius_int "$wifi_raw")"

        if is_on_ac_power; then
            on_ac=1
        else
            on_ac=0
        fi
        platform_profile="$(read_platform_profile)"

        fan_rpm="$(read_fan_rpm)"
        fan_target="$(read_fan_target)"
        pwm_value="$(read_pwm_value)"
        hw_fan_state="$(read_hw_fan_state)"

        now="$(now_ms)"

        # LOW dwell: track how long we've been at LOW and physically near the LOW target.
        if (( current_state == 1 )); then
            if is_low_fan_mismatch "$fan_rpm" "$fan_target" "$hw_fan_state"; then
                low_fan_mismatch=1
                mismatch_polls=$(( mismatch_polls + 1 ))
            else
                low_fan_mismatch=0
                mismatch_polls=0
            fi
            if is_low_fan_settled "$fan_rpm" "$fan_target" "$hw_fan_state"; then
                low_fan_settled=1
                if (( low_entered_epoch == 0 )); then
                    low_entered_epoch="$now"
                fi
                low_dwell_elapsed=$(( now - low_entered_epoch ))
                if (( low_dwell_elapsed >= low_dwell_ms )); then
                    low_dwell_met=1
                else
                    low_dwell_met=0
                fi
            else
                low_fan_settled=0
                low_entered_epoch=0
                low_dwell_elapsed=0
                low_dwell_met=0
            fi
        else
            low_fan_settled=0
            low_fan_mismatch=0
            mismatch_polls=0
            low_entered_epoch=0
            low_dwell_elapsed=0
            low_dwell_met=0
        fi

        next_state="$(desired_state "$current_state" "$cpu_c" "$gpu_c" "$gpu_w" "$wifi_c" "$on_ac" "$low_dwell_met" "$prev_cpu_c" "$prev_gpu_c" "$platform_profile" "$low_fan_settled")"

        if (( next_state > current_state )); then
            current_state="$next_state"
            last_change_epoch="$now"
            low_entered_epoch=0
            low_dwell_elapsed=0
            medium_phase=0
        elif (( next_state < current_state )); then
            if (( current_state == 2 )); then
                step_down_hold_seconds="$high_hold_ms"
                if (( next_state == 3 )); then
                    step_down_hold_seconds="$early_high_to_medium_hold_ms"
                elif (( next_state == 1 )); then
                    step_down_hold_seconds="$early_high_to_low_hold_ms"
                fi
            elif (( current_state == 3 && next_state == 2 )); then
                # MED→HIGH is urgency escalation, not a cool-down; allow immediately
                step_down_hold_seconds=0
            else
                step_down_hold_seconds="$low_hold_ms"
            fi
            if (( now - last_change_epoch >= step_down_hold_seconds )); then
                current_state="$next_state"
                last_change_epoch="$now"
                low_entered_epoch=0
                low_dwell_elapsed=0
                medium_phase=0
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
                    low_fan_settled=0
                    low_entered_epoch=0
                    low_dwell_elapsed=0
                    low_dwell_met=0
                fi
            fi
        fi

        log "telemetry ac=${on_ac} profile=${platform_profile} cpu=${cpu_c}C gpu=${gpu_c}C gpu_ppt=${gpu_w}W wifi=${wifi_c}C state=${current_state} cmd_state=${cmd_state} hw_state=${hw_fan_state} rpm=${fan_rpm} target=${fan_target} pwm=${pwm_value} low_ready=${low_fan_settled} low_mismatch=${low_fan_mismatch} mismatch_polls=${mismatch_polls} low_dwell=$(format_tenths_s "$low_dwell_elapsed")s/${LOW_DWELL_SECONDS}s"
        if (( low_fan_mismatch )); then
            log "WARNING: LOW mismatch hw_state=${hw_fan_state} rpm=${fan_rpm} target=${fan_target} pwm=${pwm_value}"
            mismatch_events=$(( mismatch_events + 1 ))
        fi
        summary_samples=$(( summary_samples + 1 ))
        sum_cpu=$(( sum_cpu + cpu_c ))
        sum_gpu=$(( sum_gpu + gpu_c ))
        sum_gpu_w=$(( sum_gpu_w + gpu_w ))
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
            log "summary samples=${summary_samples} avg_cpu=$(( sum_cpu / summary_samples ))C avg_gpu=$(( sum_gpu / summary_samples ))C avg_gpu_ppt=$(( sum_gpu_w / summary_samples ))W avg_rpm=$(( sum_rpm / summary_samples )) states=off:${state0_samples},low:${state1_samples},high:${state2_samples},med:${state3_samples} mismatch_events=${mismatch_events} recoveries=${recovery_events}"
            last_summary_epoch="$now"
            summary_samples=0
            sum_cpu=0
            sum_gpu=0
            sum_gpu_w=0
            sum_rpm=0
            state0_samples=0
            state1_samples=0
            state2_samples=0
            state3_samples=0
            mismatch_events=0
            recovery_events=0
        fi
        prev_cpu_c="$cpu_c"
        prev_gpu_c="$gpu_c"
        sleep "$POLL_INTERVAL_SECONDS"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

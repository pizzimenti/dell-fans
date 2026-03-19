#!/usr/bin/env python3
"""
fanmon-plasmoid-source.py — Outputs current fan/temp state as key=value lines.

Called by the org.kde.plasma.dell-fans plasmoid on each poll cycle.
Reads directly from sysfs (world-readable) and journalctl; no root needed.
"""

import os
import subprocess
import time

HWMON_BASE = "/sys/class/hwmon"
THERMAL_BASE = "/sys/class/thermal"
PWM_ENABLE_NAMES = {0: "off", 1: "manual", 2: "auto (native)", 3: "auto (BIOS)"}


def _read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default


def _read_int(path, default=0):
    v = _read(path)
    try:
        return int(v)
    except ValueError:
        return default


def find_hwmon(name):
    try:
        for entry in sorted(os.listdir(HWMON_BASE)):
            path = os.path.join(HWMON_BASE, entry)
            if _read(os.path.join(path, "name")) == name:
                return path
    except Exception:
        pass
    return None


def find_cooling_device(dev_type):
    try:
        for entry in sorted(os.listdir(THERMAL_BASE)):
            if not entry.startswith("cooling_device"):
                continue
            path = os.path.join(THERMAL_BASE, entry)
            if _read(os.path.join(path, "type")) == dev_type:
                return path
    except Exception:
        pass
    return None


def read_policy_telemetry():
    try:
        result = subprocess.run(
            ["journalctl", "-u", "dell-fan-policy.service", "-n", "5",
             "--no-pager", "--output=cat"],
            capture_output=True, text=True, timeout=1,
        )
        for line in reversed(result.stdout.splitlines()):
            if "telemetry " in line:
                parsed = {}
                for part in line.split():
                    if "=" not in part:
                        continue
                    key, value = part.split("=", 1)
                    parsed[key] = value
                return parsed
    except Exception:
        pass
    return {}


def collect():
    lines = [f"timestamp={int(time.time())}"]

    # ── dell_smm (fan + named temps) ─────────────────────────────────────
    dell = find_hwmon("dell_smm")
    if dell:
        fan_rpm    = _read_int(f"{dell}/fan1_input")
        fan_target = _read_int(f"{dell}/fan1_target")
        fan_max    = _read_int(f"{dell}/fan1_max") or 1
        fan_min    = _read_int(f"{dell}/fan1_min")
        pwm_raw    = _read_int(f"{dell}/pwm1")
        pwm_enable = _read_int(f"{dell}/pwm1_enable")
        lines += [
            f"fan_rpm={fan_rpm}",
            f"fan_target={fan_target}",
            f"fan_max={fan_max}",
            f"fan_min={fan_min}",
            f"pwm_raw={pwm_raw}",
            f"pwm_pct={round(pwm_raw / 255 * 100)}",
            f"pwm_enable={pwm_enable}",
            f"pwm_mode={PWM_ENABLE_NAMES.get(pwm_enable, str(pwm_enable))}",
        ]

        dell_temps = []
        label_counts: dict[str, int] = {}
        for i in range(1, 11):
            input_path = f"{dell}/temp{i}_input"
            label_path = f"{dell}/temp{i}_label"
            if not os.path.exists(input_path):
                continue
            raw = _read_int(input_path)
            if raw == 0 or not os.path.exists(label_path):
                continue
            label = _read(label_path, f"temp{i}")
            if label.startswith("Other"):
                continue
            label_counts[label] = label_counts.get(label, 0) + 1
            if label_counts[label] > 1:
                label = f"{label} {label_counts[label]}"
            dell_temps.append((label, raw / 1000.0))
    else:
        fan_rpm = fan_target = fan_min = pwm_raw = pwm_enable = 0
        fan_max = 1
        lines += ["fan_rpm=0", "fan_target=0", "fan_max=1", "fan_min=0",
                  "pwm_raw=0", "pwm_pct=0", "pwm_enable=0", "pwm_mode=unknown"]
        dell_temps = []

    # ── policy telemetry ──────────────────────────────────────────────────
    telemetry = read_policy_telemetry()

    cd = find_cooling_device("dell-smm-fan1")
    if cd:
        hw_level      = _read_int(f"{cd}/cur_state")
        fan_level_max = _read_int(f"{cd}/max_state")
    else:
        hw_level      = -1
        fan_level_max = 2

    fan_level        = int(telemetry.get("state",              hw_level))
    cmd_state        = int(telemetry.get("cmd_state",          hw_level))
    medium_elapsed_ms = int(telemetry.get("medium_elapsed_ms", "0") or 0)
    lines += [
        f"fan_level={fan_level}",
        f"fan_level_max={fan_level_max}",
        f"hw_level={hw_level}",
        f"cmd_state={cmd_state}",
        f"medium_elapsed_ms={medium_elapsed_ms}",
    ]

    # ── policy sensor inputs ──────────────────────────────────────────────
    k10    = find_hwmon("k10temp")
    amdgpu = find_hwmon("amdgpu")
    wifi   = find_hwmon("mt7925_phy0")

    cpu_c  = _read_int(f"{k10}/temp1_input")    / 1000.0 if k10    else 0.0
    gpu_c  = _read_int(f"{amdgpu}/temp1_input") / 1000.0 if amdgpu else 0.0
    wifi_c = _read_int(f"{wifi}/temp1_input")   / 1000.0 if wifi   else 0.0
    lines += [f"cpu_c={cpu_c:.1f}", f"gpu_c={gpu_c:.1f}", f"wifi_c={wifi_c:.1f}"]

    # ── all temps for display ─────────────────────────────────────────────
    extra_temps = []
    if k10:
        extra_temps.append((f"CPU ({_read(f'{k10}/temp1_label', 'Tctl')})", cpu_c))
    if amdgpu:
        extra_temps.append((f"GPU ({_read(f'{amdgpu}/temp1_label', 'edge')})", gpu_c))
    nvme = find_hwmon("nvme")
    if nvme:
        extra_temps.append(("NVMe", _read_int(f"{nvme}/temp1_input") / 1000.0))
    if wifi_c:
        extra_temps.append(("WiFi", wifi_c))
    acpitz = find_hwmon("acpitz")
    if acpitz:
        t = _read_int(f"{acpitz}/temp1_input") / 1000.0
        if t:
            extra_temps.append(("ACPI Zone", t))

    seen: set[str] = set()
    deduped: list[tuple[str, float]] = []
    for lbl, tc in dell_temps + extra_temps:
        if lbl not in seen:
            seen.add(lbl)
            deduped.append((lbl, tc))
    deduped.sort(key=lambda x: x[1], reverse=True)

    lines.append(f"temp_count={len(deduped)}")
    for i, (lbl, tc) in enumerate(deduped):
        lines += [f"temp_{i}_label={lbl}", f"temp_{i}_c={tc:.1f}"]

    # ── discrepancies ─────────────────────────────────────────────────────
    discrepancies = []
    if dell and pwm_enable != 1:
        discrepancies.append(
            f"PWM mode is '{PWM_ENABLE_NAMES.get(pwm_enable, str(pwm_enable))}' — policy may not be running"
        )
    if fan_target > 200 and fan_rpm < fan_target * 0.6:
        discrepancies.append(f"RPM lag: {fan_rpm:,} vs target {fan_target:,}")

    lines.append(f"discrepancy_count={len(discrepancies)}")
    for i, msg in enumerate(discrepancies):
        lines.append(f"discrepancy_{i}={msg}")

    print("\n".join(lines))


if __name__ == "__main__":
    collect()

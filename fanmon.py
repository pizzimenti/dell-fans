#!/usr/bin/env python3
"""
fanmon.py — Terminal fan monitor for Dell systems (dell_smm)
Shows fan RPM, level, PWM, all temps, and a live boolean checklist of the
exact criteria used by dell-fan-policy to set the current fan level.
"""

import curses
import os
import sys
import time


# ── sysfs paths ──────────────────────────────────────────────────────────────

HWMON_BASE = "/sys/class/hwmon"
THERMAL_BASE = "/sys/class/thermal"

def _read(path: str, default="") -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default


def _read_int(path: str, default: int = 0) -> int:
    v = _read(path)
    try:
        return int(v)
    except ValueError:
        return default


def find_hwmon(name: str) -> str | None:
    for entry in sorted(os.listdir(HWMON_BASE)):
        path = os.path.join(HWMON_BASE, entry)
        if _read(os.path.join(path, "name")) == name:
            return path
    return None


def find_cooling_device(dev_type: str) -> str | None:
    for entry in sorted(os.listdir(THERMAL_BASE)):
        if not entry.startswith("cooling_device"):
            continue
        path = os.path.join(THERMAL_BASE, entry)
        if _read(os.path.join(path, "type")) == dev_type:
            return path
    return None


# ── dell-fan-policy thresholds (mirrors dell-fan-policy.sh defaults) ─────────
#
# These must stay in sync with services/dell-fan-policy/dell-fan-policy.sh

# Fan levels: 0=OFF  1=LOW  2=HIGH
# Must stay in sync with dell-fan-policy.sh
LOW_ON_TEMP_C   = 50
LOW_OFF_TEMP_C  = 48
MEDIUM_ON_TEMP_C = 60
HIGH_ON_TEMP_C   = 70
HIGH_AFTER_MEDIUM_MS = 5_000
ANY_TEMP_GUARDRAIL_C = 80
LOW_SETTLED_RPM_MARGIN = 500
LOW_MISMATCH_RPM_MARGIN = 1500

FAN_LEVEL_NAMES  = {0: "OFF", 1: "LOW", 2: "HIGH", 3: "MED"}
FAN_LEVEL_DOTS   = {
    0: "○○○",
    1: "●○○",
    3: "●●○",
    2: "●●●",
}
PWM_ENABLE_NAMES = {0: "off", 1: "manual", 2: "auto (native)", 3: "auto (BIOS)"}


def ensure_root_or_reexec() -> None:
    if os.geteuid() == 0 or os.environ.get("FANMON_ELEVATED") == "1":
        return

    argv = [
        "sudo",
        "--preserve-env=TERM,COLORTERM,FANMON_ELEVATED",
        "FANMON_ELEVATED=1",
        sys.executable,
        os.path.abspath(__file__),
        *sys.argv[1:],
    ]
    os.execvp("sudo", argv)


# ── policy telemetry reader (parses last telemetry line from journal) ───────

def _read_policy_telemetry() -> dict[str, str]:
    """Parse the last policy telemetry line from the journal into key/value pairs."""
    try:
        import subprocess
        result = subprocess.run(
            ["journalctl", "-u", "dell-fan-policy.service", "-n", "5",
             "--no-pager", "--output=cat"],
            capture_output=True, text=True, timeout=1
        )
        for line in reversed(result.stdout.splitlines()):
            if "telemetry " in line:
                parsed: dict[str, str] = {}
                for part in line.split():
                    if "=" not in part:
                        continue
                    key, value = part.split("=", 1)
                    parsed[key] = value
                return parsed
    except Exception:
        pass
    return {}


# ── data collection ───────────────────────────────────────────────────────────

def collect() -> dict:
    data = {}

    # ── dell_smm (fan + named temps) ──────────────────────────────────────
    dell = find_hwmon("dell_smm")
    if dell:
        data["fan_rpm"]    = _read_int(f"{dell}/fan1_input")
        data["fan_target"] = _read_int(f"{dell}/fan1_target")
        data["fan_max"]    = _read_int(f"{dell}/fan1_max") or 1
        data["fan_min"]    = _read_int(f"{dell}/fan1_min")
        data["fan_label"]  = _read(f"{dell}/fan1_label", "Fan")
        pwm_raw            = _read_int(f"{dell}/pwm1")
        data["pwm_raw"]    = pwm_raw
        data["pwm_pct"]    = round(pwm_raw / 255 * 100)
        pwm_enable         = _read_int(f"{dell}/pwm1_enable")
        data["pwm_enable"] = pwm_enable
        data["pwm_mode"]   = PWM_ENABLE_NAMES.get(pwm_enable, str(pwm_enable))

        dell_temps = []
        label_counts: dict[str, int] = {}
        for i in range(1, 11):
            input_path  = f"{dell}/temp{i}_input"
            label_path  = f"{dell}/temp{i}_label"
            if not os.path.exists(input_path):
                continue
            raw = _read_int(input_path)
            if raw == 0:
                continue
            # Skip sensors with no label file — on this system temp6-10 have no
            # label because the SMM BIOS returns an unknown/unimplemented type for
            # those indices; they all mirror the CPU/ambient reading and add no info.
            if not os.path.exists(label_path):
                continue
            label = _read(label_path, f"temp{i}")
            # Skip generic "Other" entries — BIOS type 4, identity unknown
            if label.startswith("Other"):
                continue
            label_counts[label] = label_counts.get(label, 0) + 1
            if label_counts[label] > 1:
                label = f"{label} {label_counts[label]}"
            dell_temps.append({"label": label, "temp_c": raw / 1000.0, "source": "dell_smm"})
        data["dell_temps"] = dell_temps
    else:
        data.update(fan_rpm=0, fan_target=0, fan_max=1, fan_min=0,
                    fan_label="Fan", pwm_pct=0, pwm_mode="unknown", dell_temps=[])

    telemetry = _read_policy_telemetry()

    # ── fan level from cooling device ──────────────────────────────────────
    cd = find_cooling_device("dell-smm-fan1")
    if cd:
        hw_level = _read_int(f"{cd}/cur_state")
        data["fan_level"]     = int(telemetry.get("state", hw_level))
        data["fan_level_max"] = _read_int(f"{cd}/max_state")
        data["hw_level"]      = hw_level
    else:
        data["fan_level"]     = -1
        data["fan_level_max"] = 2
        data["hw_level"]      = -1
    data["cmd_state"] = int(telemetry.get("cmd_state", data["hw_level"]))
    data["medium_elapsed_ms"] = int(telemetry.get("medium_elapsed_ms", "0") or 0)

    # ── discrepancy detection ───────────────────────────────────────────────
    discrepancies = []
    # Policy not in control
    if data.get("pwm_enable", 1) != 1:
        discrepancies.append(
            f"PWM control mode is '{data['pwm_mode']}' — policy may not be running"
        )
    # Hardware RPM vs target (only meaningful when fan should be spinning)
    rpm    = data.get("fan_rpm", 0)
    target = data.get("fan_target", 0)
    if target > 200 and rpm < target * 0.6:
        discrepancies.append(
            f"RPM lag: hardware reports {rpm:,} but target is {target:,}"
        )
    if data["fan_level"] == 1 and target > 200 and rpm > target + LOW_MISMATCH_RPM_MARGIN:
        discrepancies.append(
            f"LOW mismatch: controller says LOW but RPM is {rpm:,} vs target {target:,}"
        )
    elif data["fan_level"] == 1 and target > 200 and rpm > target + LOW_SETTLED_RPM_MARGIN:
        discrepancies.append(
            f"LOW commanded but fan is still spinning down: {rpm:,} vs target {target:,}"
        )
    # Sanity: cooling device state should match fan_level
    hw = data.get("hw_level", -1)
    cmd = data.get("cmd_state", hw)
    pl = data["fan_level"]
    if hw >= 0 and cmd >= 0 and hw != cmd:
        discrepancies.append(
            f"Cooling device reports state {hw} ({FAN_LEVEL_NAMES.get(hw, '?')}) "
            f"but command is {cmd} ({FAN_LEVEL_NAMES.get(cmd, '?')})"
        )
    data["discrepancies"] = discrepancies

    # ── policy sensor inputs (same sources as dell-fan-policy.sh) ─────────
    k10 = find_hwmon("k10temp")
    data["cpu_c"] = _read_int(f"{k10}/temp1_input") / 1000.0 if k10 else 0.0

    amdgpu = find_hwmon("amdgpu")
    if amdgpu:
        data["gpu_c"] = _read_int(f"{amdgpu}/temp1_input") / 1000.0
    else:
        data["gpu_c"] = 0.0

    wifi = find_hwmon("mt7925_phy0")
    data["wifi_c"] = _read_int(f"{wifi}/temp1_input") / 1000.0 if wifi else 0.0

    # ── display temps (all sensors, for the Temperatures panel) ───────────
    extra_temps = []
    if k10:
        label = _read(f"{k10}/temp1_label", "Tctl")
        extra_temps.append({"label": f"CPU ({label})", "temp_c": data["cpu_c"], "source": "k10temp"})
    if amdgpu:
        label = _read(f"{amdgpu}/temp1_label", "edge")
        extra_temps.append({"label": f"GPU ({label})", "temp_c": data["gpu_c"], "source": "amdgpu"})
    nvme = find_hwmon("nvme")
    if nvme:
        t = _read_int(f"{nvme}/temp1_input")
        extra_temps.append({"label": "NVMe", "temp_c": t / 1000.0, "source": "nvme"})
    if wifi and data["wifi_c"]:
        extra_temps.append({"label": "WiFi", "temp_c": data["wifi_c"], "source": "wifi"})
    acpitz = find_hwmon("acpitz")
    if acpitz:
        t = _read_int(f"{acpitz}/temp1_input")
        if t:
            extra_temps.append({"label": "ACPI Zone", "temp_c": t / 1000.0, "source": "acpitz"})
    data["extra_temps"] = extra_temps

    return data


# ── policy criteria builder ───────────────────────────────────────────────────
#
# Returns a list of sections.  Each section:
#   { "header": str, "logic": "any"|"all"|"info", "rows": [ {...}, ... ] }
# Each row:
#   { "met": bool, "label": str, "value": float|None, "threshold": float|None,
#     "unit": str, "note": str, "blocking": bool }

def _row(met, label, value, threshold, unit, note="", cool=False):
    return {"met": met, "label": label, "value": value,
            "threshold": threshold, "unit": unit, "note": note, "cool": cool}


def build_criteria(data: dict) -> list[dict]:
    cpu_c      = data["cpu_c"]
    gpu_c      = data["gpu_c"]
    wifi_c     = data["wifi_c"]
    medium_elapsed_ms = data.get("medium_elapsed_ms", 0)
    hottest    = max(cpu_c, gpu_c)
    hottest_guardrail = max(cpu_c, gpu_c, wifi_c)

    sections = []

    # ── 0. Emergency ───────────────────────────────────────────────────────
    sections.append({
        "header": "Guardrail → HIGH",
        "logic": "all",
        "rows": [
            _row(hottest_guardrail >= ANY_TEMP_GUARDRAIL_C,
                 "Any temp", hottest_guardrail, ANY_TEMP_GUARDRAIL_C, "°C"),
        ],
    })

    # ── 1. OFF/LOW band ────────────────────────────────────────────────────
    sections.append({
        "header": "LOW band (50C-59C)",
        "logic": "any",
        "rows": [
            _row(hottest >= LOW_ON_TEMP_C, "Hottest temp", hottest, LOW_ON_TEMP_C, "°C"),
        ],
    })

    sections.append({
        "header": "MEDIUM band (60C-69C)",
        "logic": "all",
        "rows": [
            _row(hottest >= MEDIUM_ON_TEMP_C, "Hottest temp", hottest, MEDIUM_ON_TEMP_C, "°C"),
            _row(hottest < HIGH_ON_TEMP_C, "Hottest temp", hottest, HIGH_ON_TEMP_C, "°C", cool=True),
        ],
    })

    sections.append({
        "header": "HIGH band (70C+ after 5s in MEDIUM)",
        "logic": "all",
        "rows": [
            _row(hottest >= HIGH_ON_TEMP_C, "Hottest temp", hottest, HIGH_ON_TEMP_C, "°C"),
            _row(medium_elapsed_ms >= HIGH_AFTER_MEDIUM_MS,
                 "Medium hold", medium_elapsed_ms / 1000.0, HIGH_AFTER_MEDIUM_MS / 1000.0, "s"),
        ],
    })

    sections.append({
        "header": "LOW → OFF cooldown",
        "logic": "all",
        "rows": [
            _row(hottest <= LOW_OFF_TEMP_C, "Hottest temp", hottest, LOW_OFF_TEMP_C, "°C", cool=True),
        ],
    })

    return sections


def active_rule_indexes(data: dict, sections: list[dict]) -> list[int]:
    """Return the minimal set of rule sections that explain the current state."""
    level = data["fan_level"]
    cpu_c = data["cpu_c"]
    gpu_c = data["gpu_c"]
    wifi_c = data["wifi_c"]
    medium_elapsed_ms = data.get("medium_elapsed_ms", 0)
    hottest = max(cpu_c, gpu_c)
    hottest_guardrail = max(cpu_c, gpu_c, wifi_c)

    if hottest_guardrail >= ANY_TEMP_GUARDRAIL_C:
        return [0]
    if level == 2:
        return [3]
    if level == 3:
        if hottest >= HIGH_ON_TEMP_C and medium_elapsed_ms < HIGH_AFTER_MEDIUM_MS:
            return [3]
        return [2]
    if level == 1:
        if hottest <= LOW_OFF_TEMP_C:
            return [4]
        return [1]
    return [4]


# ── curses rendering ──────────────────────────────────────────────────────────

COLOR_HEADER = 1
COLOR_GOOD   = 2
COLOR_WARN   = 3
COLOR_HOT    = 4
COLOR_CRIT   = 5
COLOR_DIM    = 6
COLOR_TITLE  = 7

TEMP_WARN = 60.0
TEMP_HOT  = 75.0
TEMP_CRIT = 90.0


def init_colors():
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COLOR_HEADER, curses.COLOR_CYAN,  -1)
    curses.init_pair(COLOR_GOOD,   curses.COLOR_GREEN, -1)
    curses.init_pair(COLOR_WARN,   curses.COLOR_YELLOW,-1)
    curses.init_pair(COLOR_HOT,    curses.COLOR_RED,   -1)
    curses.init_pair(COLOR_CRIT,   curses.COLOR_WHITE,  curses.COLOR_RED)
    curses.init_pair(COLOR_DIM,    curses.COLOR_WHITE, -1)
    curses.init_pair(COLOR_TITLE,  curses.COLOR_BLACK,  curses.COLOR_CYAN)


def safe_addstr(win, y, x, text, attr=0):
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass


def temp_color(tc: float) -> int:
    if tc >= TEMP_CRIT: return curses.color_pair(COLOR_CRIT) | curses.A_BOLD
    if tc >= TEMP_HOT:  return curses.color_pair(COLOR_HOT)  | curses.A_BOLD
    if tc >= TEMP_WARN: return curses.color_pair(COLOR_WARN)
    return curses.color_pair(COLOR_GOOD)


def draw_bar(win, y, x, width, fraction, label=""):
    filled  = max(0, min(width, round(fraction * width)))
    empty   = width - filled
    bar_str = "█" * filled + "░" * empty
    color   = curses.color_pair(COLOR_GOOD)
    if fraction > 0.75: color = curses.color_pair(COLOR_WARN)
    if fraction > 0.90: color = curses.color_pair(COLOR_HOT)
    try:
        win.addstr(y, x, bar_str, color)
        if label:
            win.addstr(y, x + width + 1, label, curses.color_pair(COLOR_DIM))
    except curses.error:
        pass


def draw(stdscr, data: dict, interval: float):
    max_y, max_x = stdscr.getmaxyx()
    stdscr.erase()
    row = 0

    level      = data["fan_level"]
    level_max  = max(data["fan_level_max"], 3 if level == 3 else data["fan_level_max"])
    level_name = FAN_LEVEL_NAMES.get(level, f"L{level}")
    fan_rpm    = data["fan_rpm"]
    fan_max    = data["fan_max"]

    # ── title ─────────────────────────────────────────────────────────────
    safe_addstr(stdscr, row, 0,
                " FANMON — Dell Fan Monitor ".center(max_x),
                curses.color_pair(COLOR_TITLE) | curses.A_BOLD)
    row += 1
    safe_addstr(stdscr, row, 0,
                f" {time.strftime('%H:%M:%S')}  refresh {interval:.0f}s"
                f"   q quit  +/- interval  r refresh now",
                curses.color_pair(COLOR_DIM))
    row += 2

    # ── fan (compact: speed bar + level/pwm/target on one line) ───────────
    safe_addstr(stdscr, row, 0, "  FAN", curses.color_pair(COLOR_HEADER) | curses.A_BOLD)
    row += 1

    bar_width = min(36, max_x - 22)
    safe_addstr(stdscr, row, 4, "Speed ", curses.color_pair(COLOR_DIM))
    draw_bar(stdscr, row, 10, bar_width, fan_rpm / fan_max,
             f" {fan_rpm:,} / {fan_max:,} RPM")
    row += 1

    visual_level = 2 if level == 3 else level
    if visual_level >= 2:    level_attr = curses.color_pair(COLOR_HOT)  | curses.A_BOLD
    elif visual_level > 0:   level_attr = curses.color_pair(COLOR_WARN)
    else:                    level_attr = curses.color_pair(COLOR_GOOD)
    dots = FAN_LEVEL_DOTS.get(level, "?")

    safe_addstr(stdscr, row, 4, "Level ", curses.color_pair(COLOR_DIM))
    safe_addstr(stdscr, row, 10, f"{dots} {level_name}", level_attr)
    hw = data.get("hw_level", -1)
    cmd = data.get("cmd_state", -1)
    extras = []
    if cmd >= 0 and cmd != level:
        extras.append(f"cmd:{cmd}")
    if hw >= 0 and hw != cmd:
        extras.append(f"hw:{hw}")
    hw_str = f"  {' '.join(extras)}" if extras else ""
    safe_addstr(stdscr, row, 20,
                f"  PWM {data['pwm_pct']}% [{data['pwm_mode']}]"
                f"  target {data['fan_target']:,} RPM{hw_str}",
                curses.color_pair(COLOR_DIM))
    row += 1

    # discrepancies
    for msg in data.get("discrepancies", []):
        if row >= max_y - 3:
            break
        safe_addstr(stdscr, row, 4, f"⚠  {msg}",
                    curses.color_pair(COLOR_WARN) | curses.A_BOLD)
        row += 1

    row += 1

    # ── policy bands ──────────────────────────────────────────────────────
    safe_addstr(stdscr, row, 0, "  POLICY BANDS", curses.color_pair(COLOR_HEADER) | curses.A_BOLD)
    safe_addstr(stdscr, row, 0, "  " + "─" * min(max_x - 4, 62), curses.color_pair(COLOR_DIM))
    row += 1

    all_sections = build_criteria(data)
    show_idxs = active_rule_indexes(data, all_sections)

    for idx in show_idxs:
        if row >= max_y - 5:
            break
        sec     = all_sections[idx]
        logic   = sec["logic"]
        rows    = sec["rows"]
        any_met = any(r["met"] for r in rows)
        all_met = all(r["met"] for r in rows)

        if logic == "any":
            active = any_met
        else:
            active = all_met

        if active:
            hdr_attr = curses.color_pair(COLOR_WARN) | curses.A_BOLD
        else:
            hdr_attr = curses.color_pair(COLOR_DIM)

        safe_addstr(stdscr, row, 4, sec["header"], hdr_attr)
        row += 1

        for r in rows:
            if row >= max_y - 5:
                break
            met  = r["met"]
            val  = r["value"]
            thr  = r["threshold"]
            unit = r["unit"]
            note = r["note"]
            cool = r["cool"]

            icon      = "✓" if met else "✗"
            icon_attr = (curses.color_pair(COLOR_WARN) | curses.A_BOLD) if met else curses.color_pair(COLOR_GOOD)
            safe_addstr(stdscr, row, 6, icon, icon_attr)

            if thr is not None and val is not None:
                op      = "≤" if cool else "≥"
                u       = unit
                val_str = f"{val:.1f}{u}"
                thr_str = f"{thr}{u}"
                if cool:
                    diff = thr - val
                    delta_str = f"↓ {diff:.1f}{u} below" if diff >= 0 else f"↑ {-diff:.1f}{u} above ← blocking"
                else:
                    diff = thr - val
                    delta_str = f"↑ {-diff:.1f}{u} over" if diff <= 0 else f"{diff:.1f}{u} headroom"
                line = f"  {r['label']:<10} {op} {thr_str:<8}  now {val_str:<10}  {delta_str}"
                if note and note not in ("must drop below",):
                    line += f"  [{note}]"
            else:
                line = f"  {r['label']}"
                if note:
                    line += f"  {note}"

            row_attr = (curses.color_pair(COLOR_WARN) | curses.A_BOLD) if met else curses.color_pair(COLOR_DIM)
            safe_addstr(stdscr, row, 7, line, row_attr)
            row += 1

        row += 1  # blank between sections

    # ── temperatures ──────────────────────────────────────────────────────
    if row < max_y - 3:
        safe_addstr(stdscr, row, 0, "  TEMPERATURES", curses.color_pair(COLOR_HEADER) | curses.A_BOLD)
        row += 1
        safe_addstr(stdscr, row, 0, "  " + "─" * min(max_x - 4, 62), curses.color_pair(COLOR_DIM))
        row += 1

        all_temps = data.get("dell_temps", []) + data.get("extra_temps", [])
        seen, deduped = set(), []
        for t in all_temps:
            if t["label"] not in seen:
                seen.add(t["label"])
                deduped.append(t)
        deduped.sort(key=lambda t: t["temp_c"], reverse=True)

        # label(16) + value(8) + bar(rest, min 10)
        val_col = 20
        bar_col = 30
        bar_w   = max(10, min(25, max_x - bar_col - 2))

        for t in deduped:
            if row >= max_y - 2:
                break
            tc = t["temp_c"]
            safe_addstr(stdscr, row, 4,       f"{t['label']:<16}", curses.color_pair(COLOR_DIM))
            safe_addstr(stdscr, row, val_col, f"{tc:5.1f}°C", temp_color(tc))
            draw_bar(stdscr, row, bar_col, bar_w, min(1.0, tc / 100.0))
            row += 1

    # ── footer ────────────────────────────────────────────────────────────
    safe_addstr(stdscr, max_y - 1, 0,
                " q quit | +/- interval | r refresh now ".ljust(max_x - 1),
                curses.color_pair(COLOR_TITLE))
    stdscr.refresh()


# ── main loop ─────────────────────────────────────────────────────────────────

def main(stdscr):
    curses.curs_set(0)
    stdscr.nodelay(True)
    stdscr.timeout(200)
    init_colors()

    interval        = 2.0
    last_update     = 0.0
    data            = {}

    while True:
        now = time.monotonic()
        if now - last_update >= interval:
            data = collect()
            last_update = now

        if data:
            draw(stdscr, data, interval)

        key = stdscr.getch()
        if key in (ord("q"), ord("Q")):
            break
        elif key == ord("+"):
            interval = min(30.0, interval + 1.0)
        elif key == ord("-"):
            interval = max(0.5, interval - 0.5)
        elif key in (ord("r"), ord("R")):
            last_update = 0


if __name__ == "__main__":
    try:
        ensure_root_or_reexec()
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass

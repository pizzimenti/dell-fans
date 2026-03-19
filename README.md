# dell-fans

Userspace fan control and monitoring for Dell laptops using `dell_smm_hwmon`.

Includes a stepped fan policy daemon, a terminal monitor, and a KDE Plasma 6 panel widget.

## Requirements

- Dell laptop with `dell_smm_hwmon` kernel module (most Dell laptops with `i8k` support)
- `stress-ng` (optional, for fan stress testing)
- KDE Plasma 6 (optional, for the panel widget)
- Python 3

## Install

```bash
git clone <this-repo> && cd dell-fans
sudo bash install-dell-fan-policy.sh
sudo systemctl enable --now dell-fan-policy.service
```

This installs:

| File | Purpose |
|------|---------|
| `/usr/local/sbin/dell-fan-policy` | Fan policy daemon |
| `/etc/systemd/system/dell-fan-policy.service` | Systemd unit |
| `/usr/lib/systemd/system-sleep/dell-fan-policy-resume` | Resume hook (restarts daemon after suspend) |
| `/usr/local/bin/fanmonitor` | Terminal monitor launcher |
| `/usr/local/bin/fanmon-plasmoid-source` | Data source for the Plasma widget |

If KDE Plasma 6 is detected, the installer also upgrades/installs the panel widget.

## Fan Policy

The daemon (`dell-fan-policy.sh`) drives a stepped fan policy from CPU and GPU temperatures:

| Band | Temp Range | Fan Level |
|------|-----------|-----------|
| OFF | < 50 C | 0 |
| LOW | 50-59 C | 1 |
| MED | 60-69 C | 3 (synthetic) |
| HIGH | 70 C+ | 2 |

- **MED** is a synthetic state — the hardware only supports LOW and HIGH. MED duty-cycles between them.
- HIGH requires 5 seconds already in MED (prevents fan thrashing on brief spikes).
- Wi-Fi temperature acts as a guardrail only — it can force HIGH at 80 C+ but doesn't drive normal transitions.
- BIOS auto mode is restored on daemon exit.
- The daemon restarts automatically after suspend/resume.

## Terminal Monitor

```bash
fanmonitor
```

Curses TUI showing fan RPM, level, PWM mode, all sensor temperatures, and active policy rule. Auto-elevates via `sudo`.

| Key | Action |
|-----|--------|
| `q` | Quit |
| `+` / `-` | Increase / decrease refresh interval |
| `r` | Force refresh |
| `p` | Cycle power profile |

## Plasma Widget

A KDE Plasma 6 panel widget that shows fan state at a glance.

- **Panel icon**: hottest trigger temperature in colored text (blue/green/yellow/orange/red by temp band)
- **Tooltip**: fan level, RPM, and trigger temp in Fahrenheit
- **Popup**: fan RPM bar, level dots, PWM mode, active policy rule, and all sensor temperatures with colored bars

To add it to your panel after install: right-click panel > Add Widgets > search "dell-fans".

To manually install/upgrade the widget:

```bash
kpackagetool6 -t Plasma/Applet --upgrade plasmoid/org.kde.plasma.dell-fans
```

## Stress Testing

```bash
./fan-stress-test.sh [duration-seconds]
```

Runs randomized CPU bursts via `stress-ng` and captures fan policy telemetry from `journalctl`. Results are saved to `fan-stress-runs/` (git-ignored).

## Data Sources

- `/sys/class/hwmon/` — `dell_smm`, `k10temp`, `amdgpu`, `nvme`, `mt7925_phy0`
- `/sys/class/thermal/cooling_device*` — `dell-smm-fan1` fan level state
- `/sys/firmware/acpi/platform_profile` — active power profile
- `journalctl -u dell-fan-policy.service` — policy telemetry

## License

MIT

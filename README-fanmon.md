# fanmon.py

Terminal fan monitor for Dell systems using `dell_smm_hwmon`.

## Usage

```bash
fanmonitor
```

The monitor re-execs through `sudo` on launch, so auth happens in the
terminal instead of a desktop PolicyKit dialog.

Direct path still works:

```bash
python3 /home/bradley/Code/scripts/dell-fans/fanmon.py
```

## Controls

| Key | Action |
|-----|--------|
| `q` | Quit |
| `+` / `-` | Increase / decrease refresh interval |
| `r` | Force refresh now |
| `p` | Cycle power profile |

## What it shows

- **Fan** — RPM bar, PWM%, control mode, level (OFF/LOW/HIGH), target RPM
- **Power Profile** — cool / quiet / balanced / performance with current highlighted
- **Temperatures** — all sensors sorted hottest-first, color-coded
- **Fan Driver** — infers what is causing current fan activity (hot sensors, GPU power draw, performance profile)

## Data sources

- `/sys/class/hwmon/` — `dell_smm`, `k10temp`, `amdgpu`, `nvme`, `mt7925_phy0`
- `/sys/class/thermal/cooling_device*` — `dell-smm-fan1` fan level state
- `/sys/firmware/acpi/platform_profile` — active power profile

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
sudo ./setup.sh
sudo systemctl enable --now dell-fan-policy.service
```

(`./setup.sh` is a symlink to the real installer at
`services/dell-fan-policy/setup.sh`. The older `install-dell-fan-policy.sh`
wrapper still works and calls the same script.)

This installs:

| File | Purpose |
|------|---------|
| `/usr/local/sbin/dell-fan-policy` | Fan policy daemon |
| `/etc/systemd/system/dell-fan-policy.service` | Systemd unit |
| `/usr/lib/systemd/system-sleep/dell-fan-policy-resume` | Resume hook (restarts daemon after suspend) |
| `/usr/local/bin/fanmonitor` | Terminal monitor launcher |
| `/usr/local/bin/fanmon-plasmoid-source` | Data source for the Plasma widget |

If KDE Plasma 6 is detected, the installer also upgrades/installs the panel widget.

## Deploying changes to an existing install

After editing files in this checkout, re-run the installer to push everything
to `/usr/local/...` and restart the daemon:

```bash
sudo ./setup.sh
```

Notes:

- The installer must be invoked with `sudo bash …` (or with the script marked
  executable). Running `sudo services/.../setup.sh` against an un-executable
  script fails with a confusing "command not found" from sudo.
- If you only changed plasmoid files (`plasmoid/org.kde.plasma.dell-fans/**`),
  you can skip the full installer and upgrade just the widget as **your own
  user** (no sudo — it's a per-user install):

  ```bash
  kpackagetool6 -t Plasma/Applet --upgrade plasmoid/org.kde.plasma.dell-fans
  ```

  Then remove the widget from the panel and re-add it, restart plasmashell
  (`systemctl --user restart plasma-plasmashell.service`), or log out and
  back in so Plasma picks up the new QML. Plasma 6 has no per-widget
  "Reload" action — see the note further down.
- If you only changed the daemon or Python scripts, a `sudo systemctl restart
  dell-fan-policy.service` is enough after the installer copies the new files
  into place.
- After a successful plasmoid upgrade, setup.sh automatically restarts
  plasmashell in the target user's session so the new QML actually loads.
  Set `AUTO_RESTART_PLASMA=0` in the environment to skip that step
  (e.g. `sudo AUTO_RESTART_PLASMA=0 bash services/dell-fan-policy/setup.sh`).
- Setup.sh also checks whether `fanmon-plasmoid-source` on the target user's
  PATH resolves to the system install or to a shadow copy earlier in PATH.
  Dev symlinks pointing at your checkout are flagged as "Note" and allowed;
  stale frozen copies get a loud WARNING. See the next section for why this
  matters.

### Dev shortcut: symlink the plasmoid source into `~/.local/bin`

Running the full installer requires sudo; for iterating on the plasmoid data
source (`fanmon-plasmoid-source.py`) you can instead symlink it into a
per-user PATH entry:

```bash
python3 fanmon-plasmoid-source.py install
```

This creates `~/.local/bin/fanmon-plasmoid-source` as a **symlink** back at
your working checkout, so edits are live on the next plasmoid poll with no
reinstall needed.

**Watch out for PATH shadowing.** `~/.local/bin` typically sits earlier in
`PATH` than `/usr/local/bin`, so if `~/.local/bin/fanmon-plasmoid-source`
exists as a stale *copy* (not a symlink), it will silently override the
version `setup.sh` installs system-wide. If the plasmoid looks wrong after a
deploy, check `which fanmon-plasmoid-source` and `ls -la` that path — if it's
a regular file, delete it or re-run the `install` subcommand to replace it
with a fresh symlink.

### Plasma 6 doesn't have a per-widget "Reload"

`kpackagetool6 --upgrade` updates the plasmoid files on disk but **does not**
reload the running widget instance — plasmashell keeps the old QML in memory
until the widget is recreated. Plasma 5's right-click "Reload" was dropped in
Plasma 6. To pick up QML changes you need one of:

```bash
# Fastest: remove the widget from the panel and add it back (no shell restart).
# Or restart plasmashell in place:
kquitapp6 plasmashell && kstart plasmashell &
```

`setup.sh` does this restart automatically when it upgrades the plasmoid, so
running the full installer is the path of least resistance if you've changed
QML. The Python data source script is re-invoked on every poll, so changes
to `fanmon-plasmoid-source.py` land without any reload — this only applies to
`main.qml` and other files inside the plasmoid package.

### Why this project keeps getting bitten by stale code

Three failure modes, all the same shape — disk state and runtime state drift
apart — have caused real confusion during development:

1. **PATH shadowing.** A stale copy (not symlink) of `fanmon-plasmoid-source`
   at `~/.local/bin/` silently overrode the system install at `/usr/local/bin/`
   for weeks, because `~/.local/bin/` sits earlier in PATH. The `install`
   subcommand now creates a symlink instead of a copy, and setup.sh warns if
   it finds any non-symlink shadow on PATH.
2. **Plasmoid QML cached in memory.** plasmashell loads `main.qml` once at
   startup and won't reload it without being restarted. setup.sh now auto-
   restarts plasmashell when the widget is upgraded.
3. **Sudo-resolving paths wrong.** An earlier version of setup.sh checked
   `$HOME/.local/share/plasma/plasmoids/<id>` to decide between `--install`
   and `--upgrade`, but `$HOME` under sudo is `/root`. That silently broke
   upgrades on every run. setup.sh now resolves the target user's real home
   via `getent passwd`.

The common lesson: any time a file is "installed" somewhere other than where
it's being read from, or something loads a file once and caches it, there's
a footgun. The defenses above make each one self-correct or loudly
self-report; they don't eliminate the underlying pattern.

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
- Polling runs at 1s near band boundaries and guardrail temperatures, otherwise 3s.
- Runtime state is written to `/run/dell-fan-policy/state` for consumers.
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
- `/run/dell-fan-policy/state` — daemon runtime state for the plasmoid
- `journalctl -u dell-fan-policy.service` — transition and summary telemetry

## License

MIT

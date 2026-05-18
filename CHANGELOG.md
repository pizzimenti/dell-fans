# Changelog

All notable changes to this project are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.3] — 2026-05-18

### Added

- **OFF-state fan mismatch detection in the daemon, with a coast-down
  grace window.** Until this release the daemon only watched for LOW
  mismatches (commit 356ab16). On this hardware the Dell SMM firmware
  occasionally spins the fan up to ~3 k RPM for a poll or two even when
  the daemon has commanded OFF (`pwm1=0`, `cooling_device cur_state=0`,
  `fan1_target=0`), producing a TUI screenshot that looked broken but
  carried no warning. The daemon now tracks `off_entered_epoch` /
  `off_elapsed_ms`, ignores any RPM above `OFF_MISMATCH_RPM_MARGIN`
  (1500) for the first `OFF_COAST_DOWN_SECONDS` (30 s) after a
  transition into OFF — so a fan spinning down from HIGH/LOW doesn't
  trip false positives — and flags `off_mismatch=1` once we're past
  that window and the RPM still sits above the threshold. After three
  consecutive flagged polls (with the same exponential cooldown the
  LOW path uses, 20 s → 5 min cap) it re-asserts `pwm1=0` directly via
  the `recover_fan_off_mismatch` routine. Recovery deliberately does
  **not** bounce through LOW (which would briefly drive the fan up,
  defeating the point).
- **`pwm1_enable` is now logged every poll and persisted to the state
  file.** The screenshot incident was investigated with no way to tell
  whether the SMM firmware was overriding us while `pwm1_enable=1`
  (real EC quirk) or whether `pwm1_enable` had transiently flipped to
  `2`/`3` (something stripping manual mode). The new
  `pwm_enable=<n>` field in telemetry and `pwm_enable=<n>` key in
  `/run/dell-fan-policy/state` make that distinction visible the next
  time an event occurs. The existing `pwm1_enable != 1` discrepancy in
  fanmon and the plasmoid already surfaces non-manual mode to the user.
- **`off_elapsed_ms` in telemetry**, parallel to `medium_elapsed_ms`,
  so the coast-down gating is auditable from the journal.

### Changed

- **fanmon and the plasmoid prefer the daemon's gated `off_mismatch`
  flag over a local RPM threshold.** Both now read `off_mismatch` from
  the state file; when present, they trust the daemon's coast-down-aware
  decision. A local fallback (`fan_level == 0 && rpm > 1500`) remains
  for compatibility with older daemons but is no longer the primary
  signal. Result: no more spurious "fan spinning despite OFF"
  discrepancies during normal LOW→OFF transitions.

## [0.2.2] — 2026-05-15

### Changed

- **NVMe row now reports the hottest on-drive sensor as a single line.**
  Previously fanmon and the plasmoid showed only `temp1_input` (Composite),
  which on this hardware tracks the cooler PCB-side sensor; the hotter
  controller die (`Sensor 1`) is what actually trips NVMe thermal
  throttling. An earlier internal iteration tried emitting one row per
  sensor (`Composite`, `Sensor 1`, `Sensor 2`), but the extra rows pushed
  `SODIMM` off the bottom of the TUI on shorter terminals and most rows
  duplicated cooler PCB-side readings. Both `fanmon.py` and
  `fanmon-plasmoid-source.py` now scan all `temp*_input` files under the
  NVMe hwmon, take the maximum, and emit a single row labelled
  `NVMe (SSD core)` — the only number that actually matters for
  throttling. Sysfs enumeration is guarded against transient hwmon races
  (suspend/resume, hotplug) so the poll degrades gracefully instead of
  crashing. The plasmoid's canonical ranking treats any `NVMe (…)` label
  as a single rank slot so ordering is unchanged.

## [0.2.0] — 2026-04-21

### Added

- **Compact-mode polling.** When the popup is closed, the plasmoid now
  invokes `fanmon-plasmoid-source --compact`, which emits only the 7
  fields the tray view actually consumes. Per-poll work drops from
  ~53 ms to ~20 ms (~62% reduction). The QML parser merges results so
  the popup's last-known sensor list survives across collapsed polls.
- **Top-level `./setup.sh`** — a symlink into `services/dell-fan-policy/setup.sh`
  so the natural command "`./setup.sh`" works from the repo root.
- **Auto-restart plasmashell** after a successful plasmoid upgrade.
  setup.sh now runs `systemctl --user restart plasma-plasmashell.service`
  in the target user's graphical session so QML changes land immediately.
  Opt out with `AUTO_RESTART_PLASMA=0`.
- **PATH-shadow sanity check** in setup.sh. Warns if the target user's
  `PATH` resolves `fanmon-plasmoid-source` to anything other than the
  system install (excluding dev symlinks pointing at the checkout).
- Diagnostics scaffolding (`[fanmon]` journal logging, off by default)
  in the plasmoid QML. Flip `diagnosticsEnabled` to `true` and redeploy
  to surface per-poll timing and parse state.

### Changed

- **Polling cadence:** 1 s expanded / 5 s collapsed (was 30 s collapsed).
  The 15 s stale threshold previously fired between every collapsed
  poll; 5 s keeps the tray number accurate.
- **Canonical temperature order** in the popup so the list stops
  reshuffling each poll: CPU (Tctl), GPU (edge), WiFi, ACPI Zone,
  Ambient, CPU, NVMe, SODIMM. Rows hold their slot regardless of value
  or read state.
- **`fanmon-plasmoid-source.py install`** now creates a symlink to the
  checkout rather than a frozen copy. A copy-based dev install silently
  went stale on every source edit and shadowed the system install for
  weeks before we noticed.
- setup.sh resolves `BASH_SOURCE[0]` via `readlink -f` before deriving
  `SCRIPT_DIR`/`ROOT_DIR`, so invocation through the new top-level
  symlink works correctly.
- setup.sh `run_as_user` unified around `target_uid()` / `target_user_home()`
  helpers; eliminated the inconsistent PKEXEC/SUDO branches.

### Fixed

- **WiFi row no longer flickers in and out of the popup.** The mt7925
  hwmon path intermittently fails reads with ELOOP during firmware
  transitions. We now detect the hardware via `/sys/module` and
  `/sys/class/ieee80211` independently of the flaky hwmon, and render
  the row in place as "N/A" when a read fails — no stale caching.
- `parseState` in the plasmoid no longer wipes the popup's sensor list
  when a poll returns an empty or failed result. Last-known data stays
  visible until a successful poll replaces it.

### Documentation

- README gained a "Deploying changes" section and a "Why this project
  keeps getting bitten by stale code" retrospective naming each of the
  three recurring footgun patterns (PATH shadowing, QML caching,
  `$HOME` under sudo) and the defense against each.

## [0.1.0]

Initial release: userspace fan policy daemon, terminal monitor, and
KDE Plasma 6 panel widget.

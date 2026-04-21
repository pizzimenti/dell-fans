# Changelog

All notable changes to this project are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

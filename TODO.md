# TODO

- Verify the latest `dell-fan-policy` deployment and inspect recent `journalctl` data.
- Confirm periodic summary telemetry is live.
- Confirm `HIGH -> MED` now happens earlier on falling temperatures instead of waiting for the old `HIGH -> LOW` gate.
- Continue tuning with local evidence only; keep changes incremental.

## Claude Handoff

You are picking up ongoing work on a Dell fan-control project in this workspace.

Repo / machine context:
- Working directory: `/home/bradley/Code/scripts/dell-fans`
- Main service source: `/home/bradley/Code/scripts/dell-fans/services/dell-fan-policy/dell-fan-policy.sh`
- Installer entrypoint: `/home/bradley/Code/scripts/dell-fans/install-dell-fan-policy.sh`
- Service setup script: `/home/bradley/Code/scripts/dell-fans/services/dell-fan-policy/setup.sh`
- Monitor UI: `/home/bradley/Code/scripts/dell-fans/fanmon.py`
- Docs: `/home/bradley/Code/scripts/dell-fans/README-fanmon.md` and `/home/bradley/Code/scripts/dell-fans/README-install-dell-fan-policy.md`

Goal:
- Continue improving the custom Dell stepped/synthetic fan policy.
- Preserve recent behavior improvements.
- Focus on correctness of the policy and tuning, not on rewriting the whole system.

Important machine facts already established:
- This Dell controller does NOT expose a real analog middle PWM setting.
- Direct `pwm1` probe showed:
  - `pwm1=160` snapped to low behavior: `pwm=128`, `target=2808`, `cur_state=1`
  - `pwm1=192` snapped to high behavior: `pwm=255`, `target=5342`, `cur_state=2`
  - `pwm1=224` also snapped to high
- So the hardware is effectively discrete:
  - LOW: about `2808 RPM` target, `pwm 128`
  - HIGH: about `5342` target, but actual RPM often around `6200+`
- Because of that, the project now implements a synthetic `MED` state in software.

What has already been implemented:

1. Ownership / install / launcher
- Root-owned files under `/home/bradley` were fixed.
- Fan monitor auto-elevates through terminal `sudo`, not `pkexec`.
- Global command installed: `/usr/local/bin/fanmonitor`
- Installer lives in `setup.sh` and `install-dell-fan-policy.sh`.

2. Fan policy hysteresis / dwell
- LOW dwell for `LOW -> HIGH` was extended from `10s` to `20s`.
- `HIGH_HOLD_SECONDS` and `LOW_HOLD_SECONDS` were wired correctly.
- `LOW_HOLD_SECONDS` was increased to `30s`.
- Telemetry bug with absurd `low_dwell` values was fixed.

3. Mismatch detection / recovery
- We observed a real controller mismatch:
  - service could report `state=1`, `hw_state=1`, `target=2808`, `pwm=128`
  - but actual RPM could stay around `6200` for a long time
- This is not just audible spin-down.
- Service now logs:
  - `low_ready`
  - `low_mismatch`
  - `mismatch_polls`
- Monitor shows discrepancy warnings for:
  - `LOW mismatch: controller says LOW but RPM remains far above target`
  - separate weaker warning for ordinary spin-down
- Recovery logic was added:
  - after several consecutive LOW mismatch polls, daemon reasserts manual mode and bounces state `0 -> 1` to force the controller to re-latch low
  - that recovery has already been seen working in logs

4. Synthetic MED state
- Logical `MED` state is encoded as policy state `3`.
- Hardware still only receives LOW or HIGH.
- `commanded_hw_state()` turns MED into a duty cycle:
  - currently `HIGH, LOW, LOW` via `MEDIUM_HIGH_SLOT_EVERY=3`
- MED only engages in `performance` profile.
- `fanmon.py` was updated so logical MED is shown distinctly from hardware state.
- UI dot rendering was fixed:
  - OFF: `○○○`
  - LOW: `●○○`
  - MED: `●●○`
  - HIGH: `●●●`
- UI now distinguishes policy/logical state from commanded hardware state and actual hardware state more cleanly.

5. Faster loop
- Policy loop was changed from `2.0s` to `0.5s` polling.
- Timing was converted to millisecond-based logic for:
  - dwell
  - holds
  - mismatch recovery cooldown
- This made MED sound more constant and appeared to stabilize RPM better.

6. Latest local patch
- Added periodic summary telemetry:
  - `SUMMARY_INTERVAL_SECONDS=60`
  - summary line includes average CPU/GPU temp, average GPU power, average RPM, state sample counts, mismatch count, and recovery count
- Added earlier `HIGH -> MED` transition logic:
  - `EARLY_HIGH_TO_MEDIUM_HOLD_SECONDS=6`
  - `EARLY_HIGH_TO_MEDIUM_MARGIN_C=12`
  - intent is to enter MED earlier on falling temperatures instead of waiting for the stricter `HIGH -> LOW` path and skipping MED

Current requested task:
1. Inspect the current local code and confirm the latest patch is deployed and working.
2. Review logs after the summary/early-MED patch to verify:
   - summary lines are appearing
   - HIGH now transitions into MED earlier on falling temperature trajectories
   - MED is not being skipped on the way down
3. Keep using local evidence from `journalctl` and current `hwmon` / `thermal` state.
4. If tuning is needed, do the smallest coherent tuning change rather than a redesign.
5. Be careful not to regress:
   - mismatch detection
   - mismatch recovery
   - synthetic MED behavior
   - `0.5s` timing logic
   - monitor UI meaning

Useful commands:
- `systemctl status dell-fan-policy.service --no-pager`
- `journalctl -u dell-fan-policy.service -n 200 --no-pager --output=cat`
- `journalctl -u dell-fan-policy.service --since '10 minutes ago' --no-pager --output=cat`
- `cat /sys/class/hwmon/hwmon6/fan1_input`
- `cat /sys/class/hwmon/hwmon6/fan1_target`
- `cat /sys/class/hwmon/hwmon6/pwm1`
- `cat /sys/class/thermal/cooling_device12/cur_state`
- `cat /sys/firmware/acpi/platform_profile`

Important observed log patterns from earlier work:
- Real LOW mismatch example:
  - `state=1 hw_state=1 target=2808 pwm=128` but `rpm ~6200` for an extended period
- Recovery example:
  - `Attempting mismatch recovery desired=1 ...`
  - then reassert manual mode and `0 -> 1` bounce
  - then RPM falls back toward low target
- Good MED examples:
  - `state=3` with `cmd_state` alternating `1/2`
  - RPM spending meaningful time around `~3400-4000`

Constraints / preferences:
- Do not redesign from scratch.
- Do not remove the synthetic MED state unless the data proves it is bad.
- Prefer small, evidence-based tuning.
- Use `apply_patch` for file edits.
- Avoid destructive git commands.
- Report findings first if you discover bugs or regressions.

Please start by:
- reading the current service script and recent journal,
- confirming whether the summary patch is live,
- confirming whether `HIGH -> MED` is now occurring earlier on falling temps,
- and then continue from there.

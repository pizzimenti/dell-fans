# Service Installers

Top-level entrypoints for local machine services that are kept under `Code/services`.

## Dell Fan Policy

Userspace stepped fan policy for Dell systems using `dell_smm_hwmon`.

What it installs:

- `/usr/local/sbin/dell-fan-policy`
- `/etc/systemd/system/dell-fan-policy.service`
- `/usr/lib/systemd/system-sleep/dell-fan-policy-resume`
- `/usr/local/bin/fanmonitor`

Install or update:

```bash
sudo bash /home/bradley/Code/scripts/dell-fans/install-dell-fan-policy.sh
sudo systemctl daemon-reload
sudo systemctl enable --now dell-fan-policy.service
```

Useful commands:

```bash
fanmonitor
systemctl status dell-fan-policy.service --no-pager
journalctl -u dell-fan-policy.service -f
sudo systemctl restart dell-fan-policy.service
sudo systemctl stop dell-fan-policy.service
```

Behavior summary:

- enables manual Dell fan control
- drives stepped fan states from CPU/GPU temperatures and GPU package power
- installs `fanmonitor`, which auto-elevates through terminal `sudo` on launch
- treats Wi-Fi as a guardrail-only sensor
- restarts after resume via a system-sleep hook
- restores BIOS auto mode on daemon exit and on `ExecStopPost`

Source files:

- `/home/bradley/Code/scripts/dell-fans/services/dell-fan-policy/dell-fan-policy.sh`
- `/home/bradley/Code/scripts/dell-fans/services/dell-fan-policy/dell-fan-policy.service`
- `/home/bradley/Code/scripts/dell-fans/services/dell-fan-policy/dell-fan-policy-resume.sh`
- `/home/bradley/Code/scripts/dell-fans/services/dell-fan-policy/setup.sh`

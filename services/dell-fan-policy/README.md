# Dell Fan Policy

Userspace stepped fan-control daemon for Dell systems exposing `dell_smm_hwmon`.

Current policy:

- CPU and GPU temperatures are primary inputs.
- GPU package power can force a higher fan state on AC.
- Wi-Fi temperature is ignored during normal control and only acts as an emergency guardrail.
- BIOS automatic fan mode is restored when the daemon exits.

Files:

- `dell-fan-policy.sh`: root daemon
- `dell-fan-policy.service`: systemd unit
- `dell-fan-policy-resume.sh`: systemd sleep hook that restarts the daemon after resume
- `setup.sh`: installs the daemon and unit without enabling the service

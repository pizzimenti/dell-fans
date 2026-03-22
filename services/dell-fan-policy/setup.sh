#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="/usr/local/sbin/dell-fan-policy"
TARGET_SERVICE="/etc/systemd/system/dell-fan-policy.service"
TARGET_SLEEP_HOOK="/usr/lib/systemd/system-sleep/dell-fan-policy-resume"
TARGET_LIB_DIR="/usr/local/lib/dell-fans"
TARGET_MONITOR="/usr/local/bin/fanmonitor"
TARGET_PLASMOID_SOURCE="/usr/local/bin/fanmon-plasmoid-source"
PLASMOID_PLUGIN_ID="org.kde.plasma.dell-fans"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [[ $EUID -ne 0 ]]; then
    exec pkexec bash "$SELF" "$@"
fi

run_as_user() {
    if [[ -n "${PKEXEC_UID:-}" ]]; then
        sudo -u "#${PKEXEC_UID}" XDG_RUNTIME_DIR="/run/user/${PKEXEC_UID}" HOME="$HOME" "$@"
    elif [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

upgrade_or_install_plasmoid() {
    local plasmoid_dir="$1"
    local plugin_id="$2"
    local canonical_dir
    local show_output
    local installed_path
    local canonical_installed
    canonical_dir="$(realpath "$plasmoid_dir")"
    show_output="$(run_as_user kpackagetool6 -t Plasma/Applet --show "$plugin_id" 2>/dev/null || true)"
    installed_path="$(printf '%s\n' "$show_output" | sed -n 's/^[[:space:]]*Path[[:space:]]*:[[:space:]]*//p' | head -n1)"
    if [[ -n "$installed_path" && -e "$installed_path" ]]; then
        canonical_installed="$(realpath "$installed_path")"
        if [[ "$canonical_installed" == "$canonical_dir" ]]; then
            echo "Plasma widget already installed from source path: $canonical_dir"
            return 0
        fi
    fi
    if [[ -n "$installed_path" ]]; then
        run_as_user kpackagetool6 -t Plasma/Applet --upgrade "$canonical_dir"
    else
        run_as_user kpackagetool6 -t Plasma/Applet --install "$canonical_dir"
    fi
}

if [[ -n "${PKEXEC_UID:-}" ]]; then
    HOME="$(getent passwd "$PKEXEC_UID" | cut -d: -f6)"
    export HOME
    export XDG_DATA_HOME="${HOME}/.local/share"
fi

install -Dm755 "$SCRIPT_DIR/dell-fan-policy.sh" "$TARGET_SCRIPT"
install -Dm644 "$SCRIPT_DIR/dell-fan-policy.service" "$TARGET_SERVICE"
install -Dm755 "$SCRIPT_DIR/dell-fan-policy-resume.sh" "$TARGET_SLEEP_HOOK"
install -d -m755 "$TARGET_LIB_DIR"
install -Dm755 "$ROOT_DIR/fanmon.py"                  "$TARGET_LIB_DIR/fanmon.py"
install -Dm755 "$ROOT_DIR/fanmon-plasmoid-source.py"  "$TARGET_LIB_DIR/fanmon-plasmoid-source.py"

install -Dm755 /dev/stdin "$TARGET_MONITOR" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec python3 "/usr/local/lib/dell-fans/fanmon.py" "$@"
EOF
install -Dm755 /dev/stdin "$TARGET_PLASMOID_SOURCE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec python3 "/usr/local/lib/dell-fans/fanmon-plasmoid-source.py" "$@"
EOF

# Install/upgrade KDE Plasma widget if kpackagetool6 is available
PLASMOID_DIR="$ROOT_DIR/plasmoid/org.kde.plasma.dell-fans"
if command -v kpackagetool6 &>/dev/null && [[ -d "$PLASMOID_DIR" ]]; then
    upgrade_or_install_plasmoid "$PLASMOID_DIR" "$PLASMOID_PLUGIN_ID" \
        || echo "Note: Plasma widget install/upgrade skipped (may need manual add)"
fi

systemctl daemon-reload

echo "Installed:"
echo "  $TARGET_SCRIPT"
echo "  $TARGET_SERVICE"
echo "  $TARGET_SLEEP_HOOK"
echo "  $TARGET_LIB_DIR/"
echo "  $TARGET_MONITOR"
echo "  $TARGET_PLASMOID_SOURCE"
echo
echo "Next steps:"
echo "  systemctl enable --now dell-fan-policy.service"
echo "  journalctl -u dell-fan-policy.service -f"

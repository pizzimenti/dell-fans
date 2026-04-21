#!/usr/bin/env bash
set -euo pipefail

# Resolve the real path of this script before computing anything derived from
# it — the repo ships a top-level ./setup.sh symlink at the checkout root, so
# BASH_SOURCE[0] is often the unresolved symlink and dirname on that gives the
# wrong parent (the repo root, not services/dell-fan-policy/).
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="/usr/local/sbin/dell-fan-policy"
TARGET_SERVICE="/etc/systemd/system/dell-fan-policy.service"
TARGET_SLEEP_HOOK="/usr/lib/systemd/system-sleep/dell-fan-policy-resume"
TARGET_LIB_DIR="/usr/local/lib/dell-fans"
TARGET_MONITOR="/usr/local/bin/fanmonitor"
TARGET_PLASMOID_SOURCE="/usr/local/bin/fanmon-plasmoid-source"
PLASMOID_PLUGIN_ID="org.kde.plasma.dell-fans"

# Set to 0 to skip the post-install plasmashell restart (e.g. if you want to
# inspect the packaged widget state before it loads, or you're running in a
# non-graphical session where no restart is meaningful).
AUTO_RESTART_PLASMA="${AUTO_RESTART_PLASMA:-1}"

if [[ $EUID -ne 0 ]]; then
    exec pkexec bash "$SELF" "$@"
fi

target_uid() {
    if [[ -n "${PKEXEC_UID:-}" ]]; then printf '%s' "$PKEXEC_UID"
    elif [[ -n "${SUDO_UID:-}" ]]; then printf '%s' "$SUDO_UID"
    else id -u
    fi
}

# Home directory of the user the plasmoid will actually be installed for —
# NOT $HOME, which under sudo/pkexec is /root and would cause the -d check
# below to miss the real per-user install and wrongly fall through to
# --install instead of --upgrade.
target_user_home() {
    getent passwd "$(target_uid)" | cut -d: -f6
}

run_as_user() {
    local uid
    uid="$(target_uid)"
    if [[ "$uid" == "$(id -u)" ]]; then
        "$@"
    else
        sudo -u "#${uid}" \
            HOME="$(target_user_home)" \
            XDG_RUNTIME_DIR="/run/user/${uid}" \
            "$@"
    fi
}

# Read an environment variable out of a running process's /proc/<pid>/environ.
# Used to hand sudo'd graphical commands the exact session env the target user
# is already using — DBUS_SESSION_BUS_ADDRESS, WAYLAND_DISPLAY, etc. aren't
# preserved across sudo, and without them kquitapp6 can't find plasmashell.
proc_env_value() {
    local pid="$1" var="$2"
    [[ -r "/proc/$pid/environ" ]] || return 1
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null \
        | awk -F= -v v="$var" '$1==v { print substr($0, length(v)+2); exit }'
}

run_as_user_in_session() {
    # Like run_as_user, but also injects the graphical session env from a
    # reference PID (plasmashell). Callers pass the pid as $1, command as $2+.
    local ref_pid="$1"; shift
    local uid
    uid="$(target_uid)"
    local -a env_args=("HOME=$(target_user_home)" "XDG_RUNTIME_DIR=/run/user/${uid}")
    local var val
    for var in DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS \
               XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_DATA_DIRS PATH; do
        val="$(proc_env_value "$ref_pid" "$var")" || continue
        [[ -n "$val" ]] && env_args+=("$var=$val")
    done
    sudo -u "#${uid}" env "${env_args[@]}" "$@"
}

upgrade_or_install_plasmoid() {
    local plasmoid_dir="$1"
    local plugin_id="$2"
    local canonical_dir
    local user_plasmoid_dir="$(target_user_home)/.local/share/plasma/plasmoids/$plugin_id"
    canonical_dir="$(realpath "$plasmoid_dir")"

    # If a dev symlink at ~/.local/share/plasma/plasmoids/<id> points back at
    # *this* checkout, remove the symlink itself before invoking kpackagetool6.
    # Otherwise `kpackagetool6 --upgrade` follows the symlink and rm -rf's the
    # source repo. We only touch links pointing at this checkout — an unrelated
    # symlinked install (e.g. another working tree) is left alone and we bail
    # out so the user can resolve it manually.
    if [[ -L "$user_plasmoid_dir" ]]; then
        local installed_target
        installed_target="$(realpath "$user_plasmoid_dir")"
        if [[ "$installed_target" == "$canonical_dir" ]]; then
            echo "Removing dev symlink $user_plasmoid_dir -> $(readlink "$user_plasmoid_dir")"
            run_as_user rm -f -- "$user_plasmoid_dir"
        else
            echo "Refusing to remove unrelated symlink $user_plasmoid_dir -> $(readlink "$user_plasmoid_dir")" >&2
            echo "Resolved target ($installed_target) does not match this checkout ($canonical_dir)." >&2
            return 1
        fi
    fi

    if [[ -d "$user_plasmoid_dir" ]]; then
        run_as_user kpackagetool6 -t Plasma/Applet --upgrade "$canonical_dir"
    else
        run_as_user kpackagetool6 -t Plasma/Applet --install "$canonical_dir"
    fi
}

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

# Install/upgrade KDE Plasma widget if kpackagetool6 is available. We track
# whether the upgrade actually succeeded so we know whether to restart
# plasmashell afterwards — plasmashell caches QML in memory and won't pick
# up new files on its own.
plasmoid_changed=0
PLASMOID_DIR="$ROOT_DIR/plasmoid/org.kde.plasma.dell-fans"
if command -v kpackagetool6 &>/dev/null && [[ -d "$PLASMOID_DIR" ]]; then
    if upgrade_or_install_plasmoid "$PLASMOID_DIR" "$PLASMOID_PLUGIN_ID"; then
        plasmoid_changed=1
    else
        echo "Note: Plasma widget install/upgrade skipped (may need manual add)"
    fi
fi

systemctl daemon-reload
systemctl enable dell-fan-policy.service
systemctl restart dell-fan-policy.service

# ── PATH-shadow sanity check ─────────────────────────────────────────────────
# The plasmoid invokes `fanmon-plasmoid-source` by name. If the target user
# has anything earlier on their PATH than /usr/local/bin (notably ~/.local/bin),
# a stale copy there will silently override the version we just installed.
# Dev symlinks pointing at this checkout are fine; anything else is a risk.
check_path_shadow() {
    local uid resolved
    uid="$(target_uid)"
    resolved="$(sudo -u "#$uid" HOME="$(target_user_home)" \
                bash -lc 'command -v fanmon-plasmoid-source' 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
        echo "Warning: fanmon-plasmoid-source not on the target user's PATH." >&2
        echo "         Plasmoid will fail to poll. Check that /usr/local/bin is in PATH." >&2
        return
    fi
    if [[ "$resolved" == "$TARGET_PLASMOID_SOURCE" ]]; then
        return
    fi
    local dev_source
    dev_source="$(readlink -f "$ROOT_DIR/fanmon-plasmoid-source.py" 2>/dev/null || true)"
    if [[ -L "$resolved" ]] && [[ "$(readlink -f "$resolved")" == "$dev_source" ]]; then
        echo "Note: fanmon-plasmoid-source on PATH is a dev symlink at $resolved"
        echo "      pointing at this checkout. That shadows the system install but"
        echo "      tracks live edits, which is usually the intent."
        return
    fi
    echo "WARNING: fanmon-plasmoid-source on PATH resolves to $resolved," >&2
    echo "         NOT $TARGET_PLASMOID_SOURCE. This will shadow the system install" >&2
    echo "         with whatever code was at $resolved when it was written." >&2
    echo "         Delete it (or replace with a symlink) to avoid stale-code bugs." >&2
}
check_path_shadow

# ── Auto-restart plasmashell to load new QML ────────────────────────────────
# kpackagetool6 --upgrade only writes files; the running widget keeps its
# old QML in memory until plasmashell is recreated. We've hit this footgun
# repeatedly, so after a successful widget upgrade we restart plasmashell.
#
# Prefer the systemd user unit (plasma-plasmashell.service) when it's
# enabled — that's how modern Plasma 6 manages plasmashell, and systemctl
# handles session attachment, dependencies, and restart correctly. A plain
# `kstart plasmashell` launched via `sudo -u` gets orphaned outside the
# user's systemd session and dies shortly after starting, leaving the panel
# empty (this happened to us once; the systemd-unit path is the fix).
restart_plasmashell_if_running() {
    local uid ref_pid
    uid="$(target_uid)"
    ref_pid="$(pgrep -u "$uid" -x plasmashell 2>/dev/null | head -1 || true)"
    if [[ -z "$ref_pid" ]]; then
        echo "  plasmashell not running for uid=$uid; new QML will load on next login."
        return
    fi

    if run_as_user systemctl --user list-unit-files plasma-plasmashell.service \
            2>/dev/null | grep -q '^plasma-plasmashell\.service'; then
        echo "Restarting plasmashell via systemd user unit (plasma-plasmashell.service)…"
        if run_as_user systemctl --user restart plasma-plasmashell.service; then
            # Wait up to 5s for plasmashell to actually come back, so we can
            # report honestly and so the user doesn't see an empty panel while
            # wondering whether setup.sh succeeded.
            local i
            for i in $(seq 1 25); do
                if pgrep -u "$uid" -x plasmashell >/dev/null 2>&1; then
                    echo "  plasmashell restarted."
                    return 0
                fi
                sleep 0.2
            done
            echo "  systemctl --user restart returned but plasmashell didn't" >&2
            echo "  come back within 5s. Check 'systemctl --user status" >&2
            echo "  plasma-plasmashell.service' for details." >&2
            return 1
        fi
        echo "  systemctl --user restart failed — falling back to kstart." >&2
    fi

    # Fallback path for setups without the systemd user unit (older Plasma,
    # manually-started plasmashell, etc.). Pull session env from the running
    # plasmashell's /proc/<pid>/environ so the relaunched process lands in
    # the user's graphical session.
    echo "Restarting plasmashell via kquitapp6 + kstart…"
    run_as_user_in_session "$ref_pid" kquitapp6 plasmashell 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -u "$uid" -x plasmashell >/dev/null 2>&1 || break
        sleep 0.2
    done
    # setsid --fork so the new plasmashell isn't in our process group and
    # won't get taken down when setup.sh exits.
    run_as_user_in_session "$ref_pid" setsid --fork kstart plasmashell \
        >/dev/null 2>&1 || true
    # Verify the new process actually survived — kstart can return success
    # after forking even if the child immediately dies.
    sleep 1
    if ! pgrep -u "$uid" -x plasmashell >/dev/null 2>&1; then
        echo "  plasmashell did not come back. Restart manually:" >&2
        echo "    systemctl --user restart plasma-plasmashell.service" >&2
        echo "  or:" >&2
        echo "    kquitapp6 plasmashell && kstart plasmashell &" >&2
        return 1
    fi
    echo "  plasmashell restarted."
}

if [[ "$plasmoid_changed" -eq 1 && "$AUTO_RESTART_PLASMA" -eq 1 ]]; then
    restart_plasmashell_if_running
elif [[ "$plasmoid_changed" -eq 1 ]]; then
    echo "Plasma widget upgraded. Run the following to load the new QML now:"
    echo "  kquitapp6 plasmashell && kstart plasmashell &"
fi

echo "Installed:"
echo "  $TARGET_SCRIPT"
echo "  $TARGET_SERVICE"
echo "  $TARGET_SLEEP_HOOK"
echo "  $TARGET_LIB_DIR/"
echo "  $TARGET_MONITOR"
echo "  $TARGET_PLASMOID_SOURCE"
echo
echo "Service status:"
systemctl --no-pager --full status dell-fan-policy.service || true
echo
echo "View logs:"
echo "  journalctl -u dell-fan-policy.service -f"

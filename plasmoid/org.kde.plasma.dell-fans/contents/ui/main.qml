pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    readonly property string fullCommand: "fanmon-plasmoid-source"
    readonly property string compactCommand: "fanmon-plasmoid-source --compact"
    readonly property string currentCommand: root.expanded ? fullCommand : compactCommand
    property int refreshMs: 1000
    property int collapsedRefreshMs: 5000
    // Flip to true to emit a "[fanmon]" diagnostic stream to the journal:
    //   journalctl --user -f -o cat | grep fanmon
    property bool diagnosticsEnabled: false
    property double lastPollStartedMs: 0
    property string monospaceFamily: "monospace"

    property var data: ({
        timestamp: 0,
        fan_rpm: 0, fan_target: 0, fan_max: 5000, fan_min: 0,
        pwm_pct: 0, pwm_enable: 0, pwm_raw: 0, pwm_mode: "unknown",
        fan_level: -1, fan_level_max: 2, hw_level: -1, cmd_state: -1,
        policy_rule: "",
        medium_elapsed_ms: 0,
        cpu_c: 0.0, gpu_c: 0.0, wifi_c: 0.0,
        temp_count: 0,
        discrepancy_count: 0
    })

    property var temps: []
    property var discrepancies: []

    readonly property bool stale: !data || !data.timestamp ||
        (Math.floor(Date.now() / 1000) - data.timestamp) > 15
    readonly property real hottestC: Math.max(data.cpu_c || 0, data.gpu_c || 0)
    readonly property real hottestGuardrailC: Math.max(hottestC, data.wifi_c || 0)
    readonly property real triggerTempC: hottestGuardrailC >= 80 ? hottestGuardrailC : hottestC

    function toF(c) { return c * 9 / 5 + 32; }

    // ── helpers ────────────────────────────────────────────────────────────

    function levelDots(level) {
        if (level === 0) return "○○○";
        if (level === 1) return "●○○";
        if (level === 2) return "●●●";
        if (level === 3) return "●●○";
        return "···";
    }

    function levelName(level) {
        if (level === 0) return "OFF";
        if (level === 1) return "LOW";
        if (level === 2) return "HIGH";
        if (level === 3) return "MED";
        return "?";
    }

    function levelColor(level) {
        if (level === 2) return Kirigami.Theme.negativeTextColor;
        if (level === 3) return Kirigami.Theme.neutralTextColor;
        if (level === 1) return Kirigami.Theme.positiveTextColor;
        return Kirigami.Theme.disabledTextColor;
    }

    function tempColor(tc) {
        if (tc >= 90) return "#8b0000";   // dark red
        if (tc >= 80) return "#cc0000";   // red
        if (tc >= 70) return "#ff6600";   // orange
        if (tc >= 60) return "#ccaa00";   // yellow
        if (tc >= 50) return "#44aa44";   // green
        return "#4488cc";                  // blue
    }

    function tempFraction(tc) {
        return Math.max(0, Math.min(1, tc / 100.0));
    }

    function activeRuleLabel() {
        const medMs = data.medium_elapsed_ms || 0;
        switch (data.policy_rule) {
        case "guardrail_high":
            return "Guardrail → HIGH (≥ 80°C)";
        case "high_band":
            return "HIGH band (70°C+, held for 5s in MED)";
        case "high_wait_in_medium":
            return "HIGH band (waiting " + ((5000 - medMs) / 1000).toFixed(1) + "s more in MED)";
        case "medium_band":
            return "MEDIUM band (60°C–69°C)";
        case "low_band":
            return "LOW band (50°C–59°C)";
        case "off_band":
            return "OFF band (<50°C)";
        }
        return "No policy data";
    }

    function log(...args) {
        if (!root.diagnosticsEnabled) return;
        console.log("[fanmon]", ...args);
    }

    function pollNow() {
        // Drop any in-flight source so the next connectSource runs fresh at
        // the new cadence/mode (e.g. on an expanded→collapsed transition).
        executableSource.disconnectSource(fullCommand);
        executableSource.disconnectSource(compactCommand);
        root.lastPollStartedMs = Date.now();
        root.log("pollNow expanded=" + root.expanded
            + " cmd=" + currentCommand
            + " intervalMs=" + pollTimer.interval);
        executableSource.connectSource(currentCommand);
    }

    // Lifted out of parseState so we don't rebuild Sets or recompile regexes
    // on every poll. parseState runs 1 Hz while expanded; keeping these at
    // component scope drops the hot-loop allocation.
    readonly property var _intKeys: new Set([
        "timestamp", "fan_rpm", "fan_target", "fan_max", "fan_min",
        "pwm_pct", "pwm_enable", "pwm_raw",
        "fan_level", "fan_level_max", "hw_level", "cmd_state",
        "medium_elapsed_ms", "temp_count", "discrepancy_count"
    ])
    readonly property var _floatKeys: new Set(["cpu_c", "gpu_c", "wifi_c"])
    readonly property var _tempLabelRe: /^temp_(\d+)_label$/
    readonly property var _tempCRe: /^temp_(\d+)_c$/
    readonly property var _tempOkRe: /^temp_(\d+)_ok$/
    readonly property var _discrepancyRe: /^discrepancy_\d+$/
    readonly property var _newlineRe: /\r?\n/

    function parseState(rawText) {
        // Merge semantics: start from the existing data so fields not present
        // in the current output (e.g. compact polls that only emit a handful
        // of keys) keep their last-known value from the previous full poll.
        const next = Object.assign({}, data);
        const nextTemps = [];
        const nextDiscrepancies = [];
        let mode = "full";

        for (const line of (rawText || "").split(_newlineRe)) {
            if (!line || !line.includes("=")) continue;
            const idx = line.indexOf("=");
            const key = line.slice(0, idx);
            const value = line.slice(idx + 1);

            if (key === "mode") {
                mode = value;
            } else if (_intKeys.has(key)) {
                next[key] = parseInt(value, 10) || 0;
            } else if (_floatKeys.has(key)) {
                next[key] = parseFloat(value) || 0.0;
            } else if (key === "pwm_mode") {
                next.pwm_mode = value;
            } else if (key === "policy_rule") {
                next.policy_rule = value;
            } else {
                let m;
                if ((m = _tempLabelRe.exec(key))) {
                    const i = parseInt(m[1], 10);
                    if (!nextTemps[i]) nextTemps[i] = { label: "", c: 0, ok: true };
                    nextTemps[i].label = value;
                } else if ((m = _tempCRe.exec(key))) {
                    const i = parseInt(m[1], 10);
                    if (!nextTemps[i]) nextTemps[i] = { label: "", c: 0, ok: true };
                    nextTemps[i].c = parseFloat(value) || 0.0;
                } else if ((m = _tempOkRe.exec(key))) {
                    const i = parseInt(m[1], 10);
                    if (!nextTemps[i]) nextTemps[i] = { label: "", c: 0, ok: true };
                    nextTemps[i].ok = parseInt(value, 10) !== 0;
                } else if (_discrepancyRe.test(key)) {
                    nextDiscrepancies.push(value);
                }
            }
        }

        data = next;
        // Only replace the temp list and discrepancies on a full poll. Compact
        // polls don't emit them and would otherwise blow away the popup's
        // table mid-session.
        if (mode === "full") {
            temps = nextTemps.filter(t => t && t.label);
            discrepancies = nextDiscrepancies;
        }
        const ageS = data.timestamp > 0 ? (Math.floor(Date.now() / 1000) - data.timestamp) : -1;
        root.log("parseState mode=" + mode
            + " ts=" + data.timestamp
            + " age=" + ageS + "s"
            + " fan_rpm=" + data.fan_rpm
            + " fan_level=" + data.fan_level
            + " cpu=" + data.cpu_c
            + " gpu=" + data.gpu_c
            + " wifi=" + data.wifi_c);
    }

    // ── compact: dots + hottest temp ──────────────────────────────────────

    compactRepresentation: MouseArea {
        acceptedButtons: Qt.LeftButton
        implicitWidth: compactLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
        implicitHeight: Kirigami.Units.iconSizes.smallMedium
        onClicked: root.expanded = !root.expanded

        PlasmaComponents3.Label {
            id: compactLabel
            anchors.centerIn: parent
            text: root.triggerTempC > 0 ? root.triggerTempC.toFixed(0) + "°" : "--"
            color: root.stale ? Kirigami.Theme.disabledTextColor : root.tempColor(root.triggerTempC)
            font.family: root.monospaceFamily
            font.bold: true
            font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
        }
    }

    // ── full popup ────────────────────────────────────────────────────────

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth:  Kirigami.Units.gridUnit * 36
        Layout.minimumHeight: 400
        Layout.maximumWidth:  Kirigami.Units.gridUnit * 36
        Layout.maximumHeight: 400
        collapseMarginsHint: true

        ColumnLayout {
            anchors {
                fill: parent
                margins: Kirigami.Units.smallSpacing
            }
            spacing: 1

                // ── title ───────────────────────────────────────────────
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: "FANMON — Dell Fan Monitor"
                    font.bold: true
                    font.family: root.monospaceFamily
                    horizontalAlignment: Text.AlignHCenter
                }

                // ── FAN ─────────────────────────────────────────────────

                // RPM bar
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing / 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        PlasmaComponents3.Label {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                            text: "Speed"
                            color: Kirigami.Theme.disabledTextColor
                            font.family: root.monospaceFamily
                        }

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: (root.data.fan_rpm ?? 0).toLocaleString() + " / " + (root.data.fan_max ?? 0).toLocaleString() + " RPM"
                            font.family: root.monospaceFamily
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 10
                        Layout.minimumHeight: 10
                        Layout.maximumHeight: 10

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: Math.max(6, parent.width * Math.max(0, Math.min(1,
                                root.data.fan_rpm / Math.max(1, root.data.fan_max))))
                            radius: height / 2
                            color: root.levelColor(root.data.fan_level)
                        }
                    }
                }

                // Level + PWM row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    PlasmaComponents3.Label {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                        text: "Level"
                        color: Kirigami.Theme.disabledTextColor
                        font.family: root.monospaceFamily
                    }

                    PlasmaComponents3.Label {
                        text: root.levelDots(root.data.fan_level) + "  " + root.levelName(root.data.fan_level)
                        color: root.levelColor(root.data.fan_level)
                        font.bold: true
                        font.family: root.monospaceFamily
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: "PWM " + root.data.pwm_pct + "%  [" + root.data.pwm_mode + "]"
                        color: Kirigami.Theme.disabledTextColor
                        font.family: root.monospaceFamily
                        horizontalAlignment: Text.AlignRight
                    }
                }

                // Target RPM row (always present, text hidden when no target)
                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents3.Label {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                        text: "Target"
                        color: Kirigami.Theme.disabledTextColor
                        font.family: root.monospaceFamily
                        opacity: root.data.fan_target > 0 ? 1 : 0
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.data.fan_target > 0 ? root.data.fan_target.toLocaleString() + " RPM" : ""
                        color: Kirigami.Theme.disabledTextColor
                        font.family: root.monospaceFamily
                    }
                }

                // Discrepancy (fixed single slot, text fades in/out)
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: root.discrepancies.length > 0 ? ("⚠  " + root.discrepancies.join("  ·  ")) : ""
                    color: Kirigami.Theme.neutralTextColor
                    font.family: root.monospaceFamily
                    wrapMode: Text.Wrap
                    opacity: root.discrepancies.length > 0 ? 1 : 0
                }

                // ── POLICY ──────────────────────────────────────────────

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    PlasmaComponents3.Label {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                        text: "Active"
                        color: Kirigami.Theme.disabledTextColor
                        font.family: root.monospaceFamily
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.activeRuleLabel()
                        font.bold: true
                        font.family: root.monospaceFamily
                        wrapMode: Text.Wrap
                    }
                }


                // ── TEMPERATURES ─────────────────────────────────────────

                Repeater {
                    model: root.temps

                    delegate: ColumnLayout {
                        id: tempBlock
                        required property var modelData
                        readonly property bool tempOk: tempBlock.modelData.ok !== false
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing / 2

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.largeSpacing

                            PlasmaComponents3.Label {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                                text: tempBlock.modelData.label
                                color: Kirigami.Theme.disabledTextColor
                                font.family: root.monospaceFamily
                                elide: Text.ElideRight
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: tempBlock.tempOk
                                    ? Number(tempBlock.modelData.c).toFixed(1) + "°C / " + root.toF(tempBlock.modelData.c).toFixed(0) + "°F"
                                    : "N/A"
                                color: tempBlock.tempOk ? root.tempColor(tempBlock.modelData.c) : Kirigami.Theme.disabledTextColor
                                font.family: root.monospaceFamily
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 8
                            Layout.minimumHeight: 8
                            Layout.maximumHeight: 8

                            Rectangle {
                                anchors.fill: parent
                                radius: height / 2
                                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
                            }

                            Rectangle {
                                visible: tempBlock.tempOk
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: Math.max(4, parent.width * root.tempFraction(tempBlock.modelData.c))
                                radius: height / 2
                                color: root.tempColor(tempBlock.modelData.c)
                            }
                        }
                    }
                }

        }
    }

    // ── data source ───────────────────────────────────────────────────────

    Plasma5Support.DataSource {
        id: executableSource
        engine: "executable"
        interval: 0
        onNewData: (sourceName, sourceData) => {
            // Accept results from either command — currentCommand can switch
            // (expanded ↔ collapsed) while a poll is still in flight, and we
            // don't want to drop a freshly-computed result just because the
            // UI mode changed mid-fetch.
            if (sourceName !== root.fullCommand && sourceName !== root.compactCommand) return;
            const elapsed = root.lastPollStartedMs > 0
                ? (Date.now() - root.lastPollStartedMs) : -1;
            const stdout = sourceData.stdout || "";
            const stderr = sourceData.stderr || "";
            const exitCode = sourceData.exitCode !== undefined ? sourceData.exitCode : "?";
            root.log("onNewData src=" + sourceName
                + " elapsed=" + elapsed + "ms"
                + " exit=" + exitCode
                + " stdout.len=" + stdout.length
                + (stderr ? " stderr=" + JSON.stringify(stderr.slice(0, 200)) : ""));
            // Guard against failed polls: an empty or non-zero-exit stdout
            // would otherwise default mode="full" inside parseState() and
            // wipe the popup's last-known temps/discrepancies. Keep the
            // previous data visible instead — a single failed poll is far
            // less confusing than a blanked-out table.
            if ((exitCode !== 0 && exitCode !== "?") || stdout.length === 0) {
                executableSource.disconnectSource(sourceName);
                return;
            }
            root.parseState(stdout);
            executableSource.disconnectSource(sourceName);
        }
    }

    Timer {
        id: pollTimer
        interval: root.expanded ? root.refreshMs : root.collapsedRefreshMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.pollNow()
    }

    onExpandedChanged: function() {
        // Whether expanding or collapsing, trigger a fresh poll so the new
        // mode (full ↔ compact) takes effect immediately instead of waiting
        // for the next timer tick. pollNow() disconnects both sources first,
        // so no stale in-flight source lingers.
        root.log("expandedChanged -> " + root.expanded);
        root.pollNow();
    }

    Component.onCompleted: pollNow()

    Plasmoid.status: root.stale
        ? PlasmaCore.Types.PassiveStatus
        : (root.data.fan_level >= 2
            ? PlasmaCore.Types.NeedsAttentionStatus
            : PlasmaCore.Types.ActiveStatus)

    Plasmoid.icon: "temperature-normal"

    toolTipMainText: "dell-fans  " + levelDots(data.fan_level) + "  " + levelName(data.fan_level)
    toolTipSubText: root.stale || root.data.fan_level < 0
        ? "No recent fan data"
        : data.fan_rpm.toLocaleString() + " RPM"
          + "\n" + toF(triggerTempC).toFixed(0) + "°F"
    toolTipTextFormat: Text.PlainText
}

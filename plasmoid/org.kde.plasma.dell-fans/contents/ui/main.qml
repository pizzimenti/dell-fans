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

    property string liveScript: "fanmon-plasmoid-source"
    property string currentCommand: ""
    property int refreshMs: 2000
    property string monospaceFamily: "monospace"

    property var data: ({
        timestamp: 0,
        fan_rpm: 0, fan_target: 0, fan_max: 5000, fan_min: 0,
        pwm_pct: 0, pwm_enable: 0, pwm_raw: 0, pwm_mode: "unknown",
        fan_level: -1, fan_level_max: 2, hw_level: -1, cmd_state: -1,
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
        const level  = data.fan_level;
        const hottest = hottestC;
        const guard   = hottestGuardrailC;
        const medMs   = data.medium_elapsed_ms || 0;
        if (guard  >= 80) return "Guardrail → HIGH (≥ 80°C)";
        if (level  === 2) return "HIGH band (70°C+, held for 5s in MED)";
        if (level  === 3) {
            if (hottest >= 70 && medMs < 5000) {
                return "HIGH band (waiting " + ((5000 - medMs) / 1000).toFixed(1) + "s more in MED)";
            }
            return "MEDIUM band (60°C–69°C)";
        }
        if (level  === 1) return "LOW band (50°C–59°C)";
        if (level  === 0) return "OFF band (<50°C)";
        return "No policy data";
    }

    function shellEscape(value) {
        return value.replace(/'/g, "'\\''");
    }

    function pollNow() {
        const next = "bash -lc '" + shellEscape(liveScript) + "; echo __poll=" + Date.now() + "'";
        if (currentCommand) {
            executableSource.disconnectSource(currentCommand);
        }
        currentCommand = next;
        executableSource.connectSource(currentCommand);
    }

    function parseState(rawText) {
        const next = {
            timestamp: 0,
            fan_rpm: 0, fan_target: 0, fan_max: 5000, fan_min: 0,
            pwm_pct: 0, pwm_enable: 0, pwm_raw: 0, pwm_mode: "unknown",
            fan_level: -1, fan_level_max: 2, hw_level: -1, cmd_state: -1,
            medium_elapsed_ms: 0,
            cpu_c: 0.0, gpu_c: 0.0, wifi_c: 0.0,
            temp_count: 0,
            discrepancy_count: 0
        };
        const nextTemps = [];
        const nextDiscrepancies = [];

        const intKeys = new Set([
            "timestamp", "fan_rpm", "fan_target", "fan_max", "fan_min",
            "pwm_pct", "pwm_enable", "pwm_raw",
            "fan_level", "fan_level_max", "hw_level", "cmd_state",
            "medium_elapsed_ms", "temp_count", "discrepancy_count"
        ]);
        const floatKeys = new Set(["cpu_c", "gpu_c", "wifi_c"]);

        for (const line of (rawText || "").split(/\r?\n/)) {
            if (!line || !line.includes("=")) continue;
            const idx = line.indexOf("=");
            const key = line.slice(0, idx);
            const value = line.slice(idx + 1);

            if (intKeys.has(key)) {
                next[key] = parseInt(value, 10) || 0;
            } else if (floatKeys.has(key)) {
                next[key] = parseFloat(value) || 0.0;
            } else if (key === "pwm_mode") {
                next.pwm_mode = value;
            } else {
                const tempLabel = key.match(/^temp_(\d+)_label$/);
                if (tempLabel) {
                    const i = parseInt(tempLabel[1], 10);
                    if (!nextTemps[i]) nextTemps[i] = { label: "", c: 0 };
                    nextTemps[i].label = value;
                    continue;
                }
                const tempC = key.match(/^temp_(\d+)_c$/);
                if (tempC) {
                    const i = parseInt(tempC[1], 10);
                    if (!nextTemps[i]) nextTemps[i] = { label: "", c: 0 };
                    nextTemps[i].c = parseFloat(value) || 0.0;
                    continue;
                }
                const disc = key.match(/^discrepancy_\d+$/);
                if (disc) {
                    nextDiscrepancies.push(value);
                }
            }
        }

        data = next;
        temps = nextTemps.filter(t => t && t.label);
        discrepancies = nextDiscrepancies;
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
                            text: root.data.fan_rpm.toLocaleString() + " / " + root.data.fan_max.toLocaleString() + " RPM"
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
                                text: Number(tempBlock.modelData.c).toFixed(1) + "°C / " + root.toF(tempBlock.modelData.c).toFixed(0) + "°F"
                                color: root.tempColor(tempBlock.modelData.c)
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
            if (sourceName !== root.currentCommand) return;
            root.parseState(sourceData.stdout || "");
            executableSource.disconnectSource(sourceName);
        }
    }

    Timer {
        id: pollTimer
        interval: root.refreshMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.pollNow()
    }

    onExpandedChanged: function() {
        if (root.expanded) {
            root.pollNow();
        } else if (root.currentCommand) {
            executableSource.disconnectSource(root.currentCommand);
        }
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

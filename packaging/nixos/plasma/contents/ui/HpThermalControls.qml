import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support

ColumnLayout {
    id: root

    required property bool monitoring
    readonly property string helper: "@THERMAL_HELPER@"
    readonly property string chargeHelper: "@CHARGE_HELPER@"
    readonly property string statusCommand: helper + " status"
    readonly property string chargeStatusCommand: chargeHelper + " status"
    readonly property string editorCommand: helper.substring(0, helper.lastIndexOf("/")) + "/open-curve-editor"
    property string activeMode: ""
    property var hpModes: []
    property string fanRpm: ""
    property var temperatures: []
    property bool boostActive: false
    property string activeCurve: "unavailable"
    property string pendingCommand: ""
    property string message: ""
    property var charge: ({})
    property bool chargeEdited: false
    property bool pendingChargeSave: false
    readonly property bool chargeAvailable: typeof charge.online === "boolean"
    readonly property var modes: [
        { key: "cool", label: i18n("Cool") },
        { key: "quiet", label: i18n("Quiet") },
        { key: "balanced", label: i18n("Balanced") },
        { key: "performance", label: i18n("Performance") }
    ]

    spacing: Kirigami.Units.smallSpacing

    function refresh() {
        runner.connectSource(statusCommand);
        runner.connectSource(chargeStatusCommand);
    }

    function runRequest(request, commandHelper, saveCharge) {
        if (pendingCommand)
            return;
        message = "";
        pendingChargeSave = saveCharge === true;
        pendingCommand = (commandHelper || helper) + " " + request;
        runner.connectSource(pendingCommand);
    }

    function sensorName(sensor) {
        const names = {
            cpu: i18n("CPU"),
            gpu: i18n("GPU"),
            ssd: i18n("SSD"),
            system: i18n("System"),
            wifi: i18n("Wi-Fi")
        };
        const name = names[sensor.kind];
        return name && sensor.label ? i18n("%1 (%2)", name, sensor.label) : name || sensor.label;
    }

    onMonitoringChanged: if (monitoring) refresh()
    Component.onCompleted: if (monitoring) refresh()

    Timer {
        interval: 2500
        running: root.monitoring
        repeat: true
        onTriggered: if (!root.pendingCommand) root.refresh()
    }

    Plasma5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source);
            if (source === root.statusCommand) {
                const result = String(data.stdout || "").trim().split("\n");
                root.activeMode = result[0] === "unavailable" ? "" : result[0];
                root.fanRpm = /^[0-9]+$/.test(result[1] || "") ? result[1] : "";
                root.boostActive = result[2] === "Y";
                root.activeCurve = result[3] || "unavailable";
                try {
                    root.temperatures = JSON.parse(result[4] || "[]");
                    root.hpModes = JSON.parse(result[5] || "[]");
                } catch (error) {
                    root.temperatures = [];
                    root.hpModes = [];
                }
            } else if (source === root.chargeStatusCommand) {
                try {
                    root.charge = JSON.parse(String(data.stdout || "{}"));
                    if (root.chargeAvailable && !root.chargeEdited) {
                        chargeLimit.value = root.charge.limit;
                        chargeHysteresis.value = root.charge.hysteresis;
                    }
                } catch (error) {
                    root.charge = {};
                }
            } else if (source === root.pendingCommand) {
                if (data["exit code"] !== 0) {
                    root.message = String(data.stderr || "").trim() || i18n("Could not apply the setting.");
                } else if (root.pendingChargeSave) {
                    root.chargeEdited = false;
                }
                root.pendingChargeSave = false;
                root.pendingCommand = "";
                root.refresh();
            }
        }
    }

    PlasmaComponents.Label {
        text: i18n("HP Thermal Mode")
        font.bold: true
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2

        Repeater {
            model: root.modes
            delegate: PlasmaComponents.Button {
                required property var modelData
                Layout.fillWidth: true
                text: modelData.label
                enabled: !root.pendingCommand && root.hpModes.includes(modelData.key)
                highlighted: modelData.key === root.activeMode
                onClicked: if (modelData.key !== root.activeMode) root.runRequest("set " + modelData.key)
            }
        }
    }

    PlasmaComponents.Button {
        Layout.fillWidth: true
        enabled: !root.pendingCommand
        highlighted: root.boostActive
        text: root.boostActive ? i18n("End Fan Boost") : i18n("Fan Boost (30 seconds)")
        onClicked: root.runRequest(root.boostActive ? "auto" : "boost")
    }

    PlasmaComponents.Label {
        text: i18n("Custom Fan Curves")
        font.bold: true
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2

        Repeater {
            model: root.modes
            delegate: PlasmaComponents.Button {
                required property var modelData
                Layout.fillWidth: true
                text: modelData.label
                enabled: !root.pendingCommand && root.activeCurve !== "unavailable"
                highlighted: modelData.key === root.activeCurve
                onClicked: if (modelData.key !== root.activeCurve) root.runRequest("curve " + modelData.key)
            }
        }

        PlasmaComponents.Button {
            Layout.fillWidth: true
            enabled: !root.pendingCommand && root.activeCurve !== "unavailable"
            highlighted: root.activeCurve === "auto"
            text: i18n("Automatic")
            onClicked: if (root.activeCurve !== "auto") root.runRequest("curve auto")
        }

        PlasmaComponents.Button {
            Layout.fillWidth: true
            text: i18n("Edit Curves…")
            onClicked: runner.connectSource(root.editorCommand)
        }
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.pendingCommand ? i18n("Applying setting…")
            : root.message || (root.fanRpm ? i18n("Fan speed: %1 RPM", root.fanRpm) : i18n("Fan speed unavailable"))
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: root.chargeAvailable
        enabled: !root.pendingCommand

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.Label {
                text: i18n("Battery Charging")
                font.bold: true
                Layout.fillWidth: true
            }
            PlasmaComponents.Button {
                text: root.charge.enabled ? i18n("Disable Limit") : i18n("Enable Limit")
                onClicked: root.runRequest(root.charge.enabled ? "disable" : "enable", root.chargeHelper)
            }
        }

        GridLayout {
            columns: 2
            Layout.fillWidth: true

            PlasmaComponents.Label { text: i18n("Stop at (%)") }
            QQC2.SpinBox {
                id: chargeLimit
                Layout.fillWidth: true
                from: 2
                to: 100
                value: 80
                editable: true
                Accessible.name: i18n("Stop charging percentage")
                onValueModified: root.chargeEdited = true
            }

            PlasmaComponents.Label { text: i18n("Hysteresis (points)") }
            QQC2.SpinBox {
                id: chargeHysteresis
                Layout.fillWidth: true
                from: 1
                to: chargeLimit.value - 1
                value: 5
                editable: true
                Accessible.name: i18n("Charge hysteresis in percentage points")
                onValueModified: root.chargeEdited = true
            }
        }

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: i18n("Resume at %1%", chargeLimit.value - chargeHysteresis.value)
            }
            PlasmaComponents.Button {
                text: i18n("Save")
                enabled: root.chargeEdited
                onClicked: root.runRequest("set " + chargeLimit.value + " " + chargeHysteresis.value,
                                           root.chargeHelper, true)
            }
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.charge.state || ""
        }
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        visible: root.temperatures.length > 0

        Repeater {
            model: root.temperatures

            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: root.sensorName(modelData)
                }

                PlasmaComponents.Label {
                    text: i18n("%1 °C", Math.round(modelData.temperature).toLocaleString(Qt.locale(), "f", 0))
                }
            }
        }
    }
}

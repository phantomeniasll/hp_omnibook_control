import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support

ColumnLayout {
    id: root

    required property bool monitoring
    readonly property string helper: "@THERMAL_HELPER@"
    readonly property string statusCommand: helper + " status"
    readonly property string editorCommand: helper.substring(0, helper.lastIndexOf("/")) + "/open-curve-editor"
    property string activeMode: ""
    property var hpModes: []
    property string fanRpm: ""
    property var temperatures: []
    property bool boostActive: false
    property string activeCurve: "unavailable"
    property string pendingCommand: ""
    property string message: ""
    readonly property var modes: [
        { key: "cool", label: i18n("Cool") },
        { key: "quiet", label: i18n("Quiet") },
        { key: "balanced", label: i18n("Balanced") },
        { key: "performance", label: i18n("Performance") }
    ]

    spacing: Kirigami.Units.smallSpacing

    function refresh() {
        runner.connectSource(statusCommand);
    }

    function runRequest(request) {
        if (pendingCommand)
            return;
        message = "";
        pendingCommand = helper + " " + request;
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
            } else if (source === root.pendingCommand) {
                if (data["exit code"] !== 0) {
                    root.message = String(data.stderr || "").trim() || i18n("Could not change the thermal settings.");
                }
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
        text: root.pendingCommand ? i18n("Applying thermal setting…")
            : root.message || (root.fanRpm ? i18n("Fan speed: %1 RPM", root.fanRpm) : i18n("Fan speed unavailable"))
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

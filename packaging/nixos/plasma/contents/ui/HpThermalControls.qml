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
    property var fan: ({})
    property var temperatures: []
    property bool boostActive: false
    property string activeCurve: "unavailable"
    property string pendingCommand: ""
    property string message: ""
    property var charge: ({})
    property bool chargeEdited: false
    property bool pendingChargeSave: false
    readonly property bool chargeAvailable: charge.service_active === true
    readonly property int stopPercent: Number(stopAt.text)
    readonly property int resumePercent: Number(resumeAt.text)
    readonly property var modes: [
        { key: "cool", label: i18n("Cool") },
        { key: "quiet", label: i18n("Quiet") },
        { key: "balanced", label: i18n("Balanced") },
        { key: "performance", label: i18n("Performance") }
    ]
    readonly property bool customCurveActive: modes.some(mode => mode.key === activeCurve)

    spacing: Kirigami.Units.smallSpacing

    component ModeButton: PlasmaComponents.Button {
        id: modeButton
        property bool selected: false
        Accessible.description: selected ? i18n("Selected") : ""

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 2
            visible: modeButton.selected
            color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                           Kirigami.Theme.highlightColor.b, 0.30)
            border.color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                                  Kirigami.Theme.highlightColor.b, 0.85)
        }
    }

    component PercentField: QQC2.TextField {
        id: field
        implicitWidth: Kirigami.Units.gridUnit * 4
        leftPadding: Kirigami.Units.smallSpacing * 2
        rightPadding: unitLabel.implicitWidth + Kirigami.Units.smallSpacing * 3
        horizontalAlignment: TextInput.AlignRight
        verticalAlignment: TextInput.AlignVCenter
        selectByMouse: true
        inputMethodHints: Qt.ImhDigitsOnly
        color: fieldPalette.buttonText

        SystemPalette { id: fieldPalette; colorGroup: SystemPalette.Active }

        background: Rectangle {
            implicitHeight: Kirigami.Units.gridUnit + Kirigami.Units.smallSpacing
            radius: 2
            color: Qt.tint(fieldPalette.button,
                           Qt.rgba(fieldPalette.light.r, fieldPalette.light.g, fieldPalette.light.b, 0.48))
            border.color: field.activeFocus ? Kirigami.Theme.highlightColor
                : fieldPalette.mid
        }

        Text {
            id: unitLabel
            anchors.right: parent.right
            anchors.rightMargin: Kirigami.Units.smallSpacing * 2
            anchors.verticalCenter: parent.verticalCenter
            text: i18n("%")
            font: field.font
            color: field.color
            opacity: 0.7
            Accessible.ignored: true
        }
    }

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

    function fanDecision() {
        if (!fan.state)
            return i18n("Fan service unavailable.");
        if (fan.state === "Restoring HP fan control")
            return i18n("Restoring HP fan control. The firmware has not confirmed the handoff.");
        if (fan.target > 0)
            return boostActive
                ? i18n("Fan boost requests %1 RPM.", fan.target)
                : i18n("The custom curve requests %1 RPM.", fan.target);
        if (fan.state === "Firmware cooling")
            return i18n("HP controls the fan for temperature safety.");
        if (fan.state === "Checking firmware fan speed")
            return i18n("HP controls the fan during a scheduled speed check.");
        if (fan.state === "Firmware fan speed is already sufficient")
            return i18n("HP already calls for at least as much cooling as the selected curve.");
        if (fan.state === "Automatic")
            return customCurveActive
                ? i18n("HP controls the fan below the first point of the selected curve.")
                : i18n("HP controls the fan.");
        return fan.state;
    }

    function chargeSummary() {
        const states = {
            "Charging": i18n("Charging"), "Not charging": i18n("Not charging"),
            "Discharging": i18n("Discharging"), "Full": i18n("Fully charged")
        };
        const parts = [states[charge.battery_status] || i18n("Charging status unavailable")];
        if (typeof charge.capacity === "number")
            parts.push(i18n("%1%", charge.capacity));
        if (charge.online === true)
            parts.push(i18n("Plugged in"));
        else if (charge.online === false)
            parts.push(i18n("Unplugged"));
        if ((charge.battery_status === "Charging" || charge.battery_status === "Discharging")
                && charge.power_watts > 0) {
            parts.push(i18n("%1 W", charge.power_watts.toLocaleString(Qt.locale(), "f", 1)));
        }
        return parts.join(" · ");
    }

    function chargeDecision() {
        if (!chargeAvailable) {
            if (charge.native_limit === "on")
                return i18n("Charge-limit service is inactive. HP hard 80% limit is enabled.");
            if (charge.native_limit === "unknown")
                return i18n("Charge-limit service is inactive. Could not verify the HP charging limit.");
            return i18n("Charge-limit service is inactive.");
        }
        const nativeNote = charge.native_limit === "on"
            ? (charge.enabled && charge.limit > 80
                ? i18n(" HP hard 80% limit is also on and caps charging at 80%.")
                : i18n(" HP hard 80% limit is also on."))
            : (charge.native_limit === "unknown"
                ? i18n(" Could not verify the HP charging limit.")
                : "");
        if (charge.state !== "Automatic charging" && charge.state !== "Charging paused")
            return (charge.state || "") + nativeNote;
        if (!charge.enabled) {
            if (charge.native_limit === "on")
                return i18n("HP hard 80% limit is enabled.");
            if (charge.native_limit === "unknown")
                return i18n("Could not verify the HP charging limit.");
            return i18n("Custom soft limit off. HP manages charging.");
        }
        if (charge.online === false)
            return i18n("The soft limit applies when plugged in.") + nativeNote;
        const resume = charge.limit - charge.hysteresis;
        if (charge.paused && charge.battery_status === "Not charging")
            return i18n("Held by the custom soft limit at %1%. Charging resumes at %2%.", charge.limit, resume) + nativeNote;
        if (charge.native_limit === "on" && charge.limit > 80
                && charge.battery_status === "Not charging" && charge.capacity >= 79)
            return i18n("Held by the HP hard 80% limit (custom soft limit is set to %1%).", charge.limit);
        if (charge.battery_status === "Charging" && charge.capacity < charge.limit)
            return i18n("Charging toward the %1% limit.", charge.limit) + nativeNote;
        return i18n("Soft limit on. Stops at %1% and resumes at %2%.", charge.limit, resume) + nativeNote;
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
                    root.fan = JSON.parse(result[6] || "{}");
                } catch (error) {
                    root.temperatures = [];
                    root.hpModes = [];
                    root.fan = {};
                }
            } else if (source === root.chargeStatusCommand) {
                try {
                    root.charge = JSON.parse(String(data.stdout || "{}"));
                    if (root.chargeAvailable && !root.chargeEdited) {
                        stopAt.text = String(root.charge.limit);
                        resumeAt.text = String(root.charge.limit - root.charge.hysteresis);
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
        text: root.fanRpm ? i18n("Fan · %1 RPM", Number(root.fanRpm).toLocaleString(Qt.locale(), "f", 0))
                          : i18n("Fan speed unavailable")
        font.weight: Font.DemiBold
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.fanDecision()
    }

    PlasmaComponents.Label {
        text: i18n("HP Thermal Mode")
        font.weight: Font.DemiBold
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        uniformCellWidths: true

        Repeater {
            model: root.modes
            delegate: ModeButton {
                required property var modelData
                Layout.fillWidth: true
                text: modelData.label
                enabled: !root.pendingCommand && root.hpModes.includes(modelData.key)
                selected: !root.customCurveActive && !root.boostActive && modelData.key === root.activeMode
                onClicked: if (modelData.key !== root.activeMode) root.runRequest("set " + modelData.key)
            }
        }
    }

    ModeButton {
        Layout.fillWidth: true
        enabled: !root.pendingCommand
        selected: root.boostActive
        text: root.boostActive ? i18n("End Fan Boost") : i18n("Fan Boost (30 seconds)")
        onClicked: root.runRequest(root.boostActive ? "auto" : "boost")
    }

    PlasmaComponents.Label {
        text: i18n("Custom Fan Curves")
        font.weight: Font.DemiBold
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        uniformCellWidths: true

        Repeater {
            model: root.modes
            delegate: ModeButton {
                required property var modelData
                Layout.fillWidth: true
                text: modelData.label
                enabled: !root.pendingCommand && root.activeCurve !== "unavailable"
                selected: !root.boostActive && modelData.key === root.activeCurve
                onClicked: if (modelData.key !== root.activeCurve) root.runRequest("curve " + modelData.key)
            }
        }

        ModeButton {
            Layout.fillWidth: true
            enabled: !root.pendingCommand && root.activeCurve !== "unavailable"
            selected: !root.boostActive && root.activeCurve === "auto"
            text: i18n("HP default")
            onClicked: if (root.activeCurve !== "auto") root.runRequest("curve auto")
        }

        PlasmaComponents.Button {
            Layout.fillWidth: true
            text: i18n("Edit Curves…")
            onClicked: runner.connectSource("sh -c '\"$1\" </dev/null >/dev/null 2>&1 &' sh " + JSON.stringify(root.editorCommand))
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: root.chargeAvailable || !!root.charge.battery_status

        RowLayout {
            Layout.fillWidth: true

            PlasmaComponents.Label {
                text: i18n("Battery Charging")
                font.weight: Font.DemiBold
            }

            Item { Layout.fillWidth: true }

            PlasmaComponents.Switch {
                visible: !!root.charge.native_limit
                enabled: !root.pendingCommand && root.charge.native_limit !== "unknown"
                checked: root.charge.native_limit === "on"
                text: i18n("HP hard 80% limit")
                onClicked: {
                    const currentlyOn = root.charge.native_limit === "on";
                    checked = Qt.binding(() => root.charge.native_limit === "on");
                    root.runRequest(currentlyOn ? "native-disable" : "native-enable", root.chargeHelper);
                }
            }
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.chargeSummary()
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.chargeDecision()
        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing * 2
            visible: root.chargeAvailable
            enabled: !root.pendingCommand

            PlasmaComponents.Label {
                text: i18n("Custom soft limit")
            }
            PlasmaComponents.Label {
                text: i18n("Stop at")
            }
            PercentField {
                id: stopAt
                text: "80"
                Accessible.name: i18n("Stop charging percentage")
                validator: IntValidator { bottom: 2; top: 100 }
                onTextEdited: root.chargeEdited = true
            }

            PlasmaComponents.Label {
                Layout.leftMargin: Kirigami.Units.smallSpacing
                text: i18n("Resume at")
            }
            PercentField {
                id: resumeAt
                text: "75"
                Accessible.name: i18n("Resume charging percentage")
                validator: IntValidator { bottom: 1; top: Math.max(1, root.stopPercent - 1) }
                onTextEdited: root.chargeEdited = true
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.chargeAvailable
            enabled: !root.pendingCommand

            PlasmaComponents.Button {
                text: root.charge.enabled ? i18n("Disable Soft Limit") : i18n("Enable Soft Limit")
                onClicked: root.runRequest(root.charge.enabled ? "disable" : "enable", root.chargeHelper)
            }

            Item { Layout.fillWidth: true }

            PlasmaComponents.Button {
                text: i18n("Save")
                enabled: root.chargeEdited && stopAt.acceptableInput && resumeAt.acceptableInput
                         && root.resumePercent >= 1 && root.resumePercent < root.stopPercent
                onClicked: root.runRequest("set " + root.stopPercent + " " + (root.stopPercent - root.resumePercent),
                                           root.chargeHelper, true)
            }
        }
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        visible: !!root.pendingCommand || !!root.message
        wrapMode: Text.WordWrap
        text: root.pendingCommand ? i18n("Applying setting…") : root.message
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        visible: root.temperatures.length > 0
        uniformCellWidths: true
        columnSpacing: Kirigami.Units.largeSpacing

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

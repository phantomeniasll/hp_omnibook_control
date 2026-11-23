import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: applet

    Plasmoid.icon: "temperature-symbolic"
    preferredRepresentation: compactRepresentation
    toolTipMainText: i18n("HP Thermal Mode")

    fullRepresentation: HpThermalControls {
        monitoring: applet.expanded
        Layout.minimumWidth: Kirigami.Units.gridUnit * 15
        Layout.minimumHeight: implicitHeight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 17
        Layout.preferredHeight: implicitHeight
    }
}

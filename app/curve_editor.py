import json
import os
import sys

try:
    from PySide6.QtCore import QProcess, QTimer
    from PySide6.QtGui import QIcon
    from PySide6.QtWidgets import (
        QAbstractItemView, QApplication, QComboBox, QDialog, QFormLayout, QGroupBox, QHBoxLayout,
        QHeaderView, QLabel, QPushButton, QSpinBox, QTableWidget, QVBoxLayout,
    )
except ImportError:
    from PyQt6.QtCore import QProcess, QTimer
    from PyQt6.QtGui import QIcon
    from PyQt6.QtWidgets import (
        QAbstractItemView, QApplication, QComboBox, QDialog, QFormLayout, QGroupBox, QHBoxLayout,
        QHeaderView, QLabel, QPushButton, QSpinBox, QTableWidget, QVBoxLayout,
    )


from curve_control import BASE, KEYS, MAX_RPM, MIN_RPM, check_profiles, load_config, load_status, read_hp_mode
from temperature_status import readings
from battery_limit import STATUS as BATTERY_LIMIT_STATUS, status as battery_limit_status

LABELS = {"auto": "Automatic", "quiet": "Quiet", "balanced": "Balanced",
          "cool": "Cool", "performance": "Performance"}
PKEXEC = os.environ.get("OMNIBOOK_PKEXEC", "/usr/bin/pkexec")


class CurveEditor(QDialog):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("HP Fan Curves")
        self.setWindowIcon(QIcon.fromTheme("temperature-symbolic"))
        self.resize(480, 460)
        config = load_config()
        self.profiles = config["profiles"]
        self.current = config["active"] if config["active"] in KEYS else "balanced"
        self.process = QProcess(self)

        layout = QVBoxLayout(self)
        self.status = QLabel()
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        self.temperatures = QLabel()
        self.temperatures.setWordWrap(True)
        layout.addWidget(self.temperatures)
        self.charge_controls = QGroupBox("Battery charging")
        self.charge_values_loaded = False
        charge_form = QFormLayout(self.charge_controls)
        self.charge_limit = QSpinBox()
        self.charge_limit.setRange(2, 100)
        self.charge_limit.setSuffix("%")
        self.charge_hysteresis = QSpinBox()
        self.charge_hysteresis.setRange(1, 99)
        self.charge_hysteresis.setSuffix(" pp")
        self.charge_limit.valueChanged.connect(
            lambda value: self.charge_hysteresis.setMaximum(value - 1))
        self.charge_hysteresis.setToolTip("Percentage points below the limit at which charging resumes.")
        charge_form.addRow("Stop charging at", self.charge_limit)
        charge_form.addRow("Hysteresis", self.charge_hysteresis)
        self.charge_status = QLabel()
        self.charge_status.setWordWrap(True)
        charge_form.addRow(self.charge_status)
        charge_actions = QHBoxLayout()
        self.save_charge = QPushButton("Save Charging Settings")
        self.save_charge.clicked.connect(lambda: self.battery_command(
            "set", str(self.charge_limit.value()), str(self.charge_hysteresis.value())))
        self.battery_limit = QPushButton()
        self.battery_limit.clicked.connect(self.switch_battery_limit)
        charge_actions.addWidget(self.save_charge)
        charge_actions.addWidget(self.battery_limit)
        charge_form.addRow(charge_actions)
        layout.addWidget(self.charge_controls)

        hp_row = QHBoxLayout()
        self.hp_modes = {}
        for key in KEYS:
            button = QPushButton(LABELS[key])
            button.setCheckable(True)
            button.clicked.connect(lambda checked, name=key: self.command("hp-mode", name))
            self.hp_modes[key] = button
            hp_row.addWidget(button)
        layout.addWidget(QLabel("HP firmware modes"))
        layout.addLayout(hp_row)

        profile_row = QHBoxLayout()
        profile_label = QLabel("&Curve")
        self.profile = QComboBox()
        profile_label.setBuddy(self.profile)
        for key in KEYS:
            self.profile.addItem(LABELS[key], key)
        self.profile.setCurrentIndex(KEYS.index(self.current))
        profile_row.addWidget(profile_label)
        profile_row.addWidget(self.profile, 1)
        layout.addLayout(profile_row)

        self.points = QTableWidget(0, 2)
        self.points.setHorizontalHeaderLabels(["CPU temperature (°C)", "Target fan speed (RPM)"])
        self.points.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self.points.verticalHeader().hide()
        self.points.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.points.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        layout.addWidget(self.points, 1)

        point_actions = QHBoxLayout()
        self.add = QPushButton("&Add Point")
        self.remove = QPushButton("&Remove Point")
        self.add.clicked.connect(self.add_point)
        self.remove.clicked.connect(self.remove_point)
        self.points.itemSelectionChanged.connect(self.update_point_actions)
        point_actions.addWidget(self.add)
        point_actions.addWidget(self.remove)
        point_actions.addStretch()
        layout.addLayout(point_actions)

        self.message = QLabel("Below the first point, HP controls the fan. "
                              "Above it, custom curves can request up to 4,500 RPM.")
        self.message.setWordWrap(True)
        layout.addWidget(self.message)

        actions = QHBoxLayout()
        self.fan_boost = QPushButton()
        self.fan_boost.clicked.connect(lambda: self.command("stop-boost" if load_status().get("boost") else "boost"))
        self.automatic = QPushButton("Use &Automatic")
        self.save = QPushButton("&Save Curves")
        self.apply = QPushButton("Save and &Apply")
        self.automatic.clicked.connect(lambda: self.command("select", "auto"))
        self.save.clicked.connect(lambda: self.save_profiles(False))
        self.apply.clicked.connect(lambda: self.save_profiles(True))
        for button in (self.fan_boost, self.automatic, self.save, self.apply):
            actions.addWidget(button)
        layout.addLayout(actions)

        self.profile.currentIndexChanged.connect(self.change_profile)
        self.process.finished.connect(self.command_finished)
        self.process.errorOccurred.connect(self.command_error)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(1000)
        self.show_points()
        self.refresh()

    def values(self):
        return [[self.points.cellWidget(row, column).value() for column in range(2)]
                for row in range(self.points.rowCount())]

    def add_row(self, temperature, rpm):
        row = self.points.rowCount()
        self.points.insertRow(row)
        for column, value, limits, step in (
            (0, temperature, (30, 82), 1), (1, rpm, (MIN_RPM, MAX_RPM), 50),
        ):
            field = QSpinBox()
            field.setRange(*limits)
            field.setSingleStep(step)
            field.setValue(value)
            field.setKeyboardTracking(False)
            self.points.setCellWidget(row, column, field)

    def show_points(self):
        self.points.setRowCount(0)
        for temperature, rpm in self.profiles[self.current]:
            self.add_row(temperature, rpm)
        self.update_point_actions()

    def change_profile(self, _index):
        self.profiles[self.current] = self.values()
        self.current = self.profile.currentData()
        self.show_points()

    def add_point(self):
        points = self.values()
        for position, (first, second) in enumerate(zip(points, points[1:])):
            if second[0] - first[0] > 1:
                points.insert(position + 1, [(first[0] + second[0]) // 2, first[1]])
                break
        else:
            if points[-1][0] >= 82:
                self.message.setText("Make room between two temperatures before adding a point.")
                return
            points.append([min(82, points[-1][0] + 3), points[-1][1]])
        self.profiles[self.current] = points
        self.show_points()

    def remove_point(self):
        row = self.points.currentRow()
        if row >= 0 and self.points.rowCount() > 2:
            self.points.removeRow(row)
        self.update_point_actions()

    def update_point_actions(self):
        self.add.setEnabled(self.points.rowCount() < 12)
        self.remove.setEnabled(self.points.rowCount() > 2 and self.points.currentRow() >= 0)

    def refresh(self):
        value = load_status()
        running = bool(value)
        busy = self.process.state() != QProcess.ProcessState.NotRunning
        has_battery_service = BATTERY_LIMIT_STATUS.is_file()
        self.charge_controls.setVisible(has_battery_service)
        if has_battery_service:
            battery = battery_limit_status()
            limit, hysteresis = battery["limit"], battery["hysteresis"]
            if not self.charge_values_loaded:
                self.charge_limit.setValue(limit)
                self.charge_hysteresis.setValue(hysteresis)
            self.battery_limit.setText("Disable Charge Limit" if battery["enabled"] else
                                       "Enable Charge Limit")
            thresholds = f"Stop at {limit}%, resume at {limit - hysteresis}%"
            self.charge_status.setText(f'{thresholds}\n{battery.get("state", "")}')
            self.charge_controls.setEnabled(not busy)
        self.charge_values_loaded = has_battery_service
        for button in (self.fan_boost, self.automatic, self.save, self.apply):
            button.setEnabled(running and not busy)
        self.fan_boost.setText("End Fan Boost" if value.get("boost") else "Fan Boost (30 s)")
        names = {"cpu": "CPU", "gpu": "GPU", "ssd": "SSD", "system": "System", "wifi": "Wi-Fi"}
        temperatures = []
        for sensor in readings():
            name = names.get(sensor["kind"], "")
            if sensor["label"]:
                name = f'{name} ({sensor["label"]})' if name else sensor["label"]
            temperatures.append(f'{name} {sensor["temperature"]:.0f}°C')
        self.temperatures.setText("  ·  ".join(temperatures))
        hp_mode, choices = read_hp_mode()
        for key, button in self.hp_modes.items():
            button.setEnabled(not busy and key in choices)
            button.setChecked(key == hp_mode)
            button.setToolTip("" if choices else "Requires an HP driver that exposes firmware modes.")
        if not running:
            self.status.setText("Background fan control is inactive. Start omnibook-fan-curves.service.")
            return
        temperature = "—" if value["temperature"] is None else f'{value["temperature"]:.0f}°C'
        rpm = "—" if value["rpm"] is None else f'{value["rpm"]:,} RPM'
        self.status.setText(f'{LABELS[value["profile"]]}   ·   {temperature}   ·   {rpm}\n{value["state"]}')

    def command(self, operation, argument=None):
        arguments = ["--disable-internal-agent", str(BASE / "curve-python"),
                     str(BASE / "curve_control.py"), operation]
        if argument is not None:
            arguments.append(argument)
        self.process.start(PKEXEC, arguments)
        self.message.setText("Waiting for authorization…")
        self.refresh()

    def switch_battery_limit(self):
        self.battery_command("disable" if battery_limit_status()["enabled"] else "enable")

    def battery_command(self, *operations):
        self.process.start(PKEXEC, ["--disable-internal-agent", str(BASE / "curve-python"),
                                    str(BASE / "battery_limit.py"), *operations])
        self.message.setText("Waiting for authorization…")
        self.refresh()

    def save_profiles(self, apply):
        self.profiles[self.current] = self.values()
        try:
            check_profiles(self.profiles)
        except ValueError as error:
            self.message.setText(str(error))
            return
        self.command("save-select" if apply else "save",
                     json.dumps({"profiles": self.profiles, "active": self.current}))

    def command_error(self, _error):
        self.message.setText(self.process.errorString())
        self.refresh()

    def command_finished(self, code, _status):
        error = self.process.readAllStandardError().data().decode(errors="replace").strip()
        self.message.setText("Updated." if code == 0 else
                             "Authorization canceled." if code == 126 else error or "Could not apply the change.")
        self.refresh()


if __name__ == "__main__":
    app = QApplication(sys.argv[:1])
    window = CurveEditor()
    window.show()
    if "--check" in sys.argv:
        QTimer.singleShot(0, app.quit)
    sys.exit(app.exec())

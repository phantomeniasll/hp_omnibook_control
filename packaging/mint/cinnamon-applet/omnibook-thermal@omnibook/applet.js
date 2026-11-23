const Applet = imports.ui.applet;
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const Mainloop = imports.mainloop;
const Pango = imports.gi.Pango;
const PopupMenu = imports.ui.popupMenu;
const St = imports.gi.St;

const THERMAL_HELPER = "/usr/local/lib/omnibook-fan-curves/thermal";
const EDITOR_HELPER = "/usr/local/lib/omnibook-fan-curves/open-curve-editor";
const CHARGE_HELPER = "/usr/local/bin/hp-charge-limit";

const MODES = [
    { key: "cool", label: "Cool" },
    { key: "quiet", label: "Quiet" },
    { key: "balanced", label: "Balanced" },
    { key: "performance", label: "Performance" }
];

const SENSOR_NAMES = {
    cpu: "CPU",
    gpu: "GPU",
    ssd: "SSD",
    system: "System",
    wifi: "Wi-Fi"
};

function runCommandAsync(argv, callback) {
    try {
        const proc = Gio.Subprocess.new(
            argv,
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
        );
        proc.communicate_utf8_async(null, null, (source, res) => {
            try {
                const [, stdout, stderr] = source.communicate_utf8_finish(res);
                callback({
                    ok: source.get_successful(),
                    stdout: stdout || "",
                    stderr: stderr || ""
                });
            } catch (err) {
                callback({ ok: false, stdout: "", stderr: String(err) });
            }
        });
    } catch (err) {
        callback({ ok: false, stdout: "", stderr: String(err) });
    }
}

class OmnibookThermalApplet extends Applet.IconApplet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);
        this.set_applet_icon_symbolic_name("temperature-symbolic");
        this.set_applet_tooltip("HP Thermal & Battery");

        this._activeMode = "";
        this._hpModes = [];
        this._fanRpm = "";
        this._fan = {};
        this._temperatures = [];
        this._boostActive = false;
        this._activeCurve = "unavailable";
        this._charge = {};
        this._chargeEdited = false;
        this._syncingEntries = false;
        this._pending = false;
        this._message = "";
        this._refreshTimerId = 0;
        this._destroyed = false;

        this.menuManager = new PopupMenu.PopupMenuManager(this);
        this.menu = new Applet.AppletPopupMenu(this, orientation);
        this.menuManager.addMenu(this.menu);

        this._buildMenu();
        this.menu.connect("open-state-changed", (_menu, isOpen) => {
            if (isOpen) {
                this._refresh();
                this._startTimer();
            } else {
                this._stopTimer();
            }
        });
    }

    on_applet_clicked() {
        this.menu.toggle();
    }

    on_applet_removed_from_panel() {
        this._destroyed = true;
        this._stopTimer();
    }

    _startTimer() {
        this._stopTimer();
        this._refreshTimerId = Mainloop.timeout_add(2500, () => {
            if (this._destroyed || !this.menu.isOpen) {
                this._refreshTimerId = 0;
                return false;
            }
            if (!this._pending) {
                this._refresh();
            }
            return true;
        });
    }

    _stopTimer() {
        if (this._refreshTimerId) {
            Mainloop.source_remove(this._refreshTimerId);
            this._refreshTimerId = 0;
        }
    }

    _makeButton(label, onClick) {
        const button = new St.Button({
            label: label,
            style_class: "omnibook-button",
            reactive: true,
            can_focus: true,
            x_expand: true
        });
        button.connect("clicked", () => {
            if (button.reactive) {
                onClick();
            }
        });
        return button;
    }

    _setButtonState(button, enabled, selected) {
        button.reactive = enabled;
        button.can_focus = enabled;
        if (enabled) {
            button.remove_style_pseudo_class("insensitive");
        } else {
            button.add_style_pseudo_class("insensitive");
        }
        if (selected) {
            button.add_style_class_name("omnibook-button-selected");
        } else {
            button.remove_style_class_name("omnibook-button-selected");
        }
    }

    _makeLabel(text, styleClass, wrap) {
        const label = new St.Label({ text: text, style_class: styleClass || "omnibook-text" });
        if (wrap) {
            label.clutter_text.line_wrap = true;
            label.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;
        }
        return label;
    }

    _buildMenu() {
        const section = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            activate: false
        });
        const root = new St.BoxLayout({
            vertical: true,
            style_class: "omnibook-popup",
            x_expand: true
        });
        section.addActor(root, { expand: true, span: -1 });
        this.menu.addMenuItem(section);

        this._fanHeading = this._makeLabel("Fan speed unavailable", "omnibook-heading", false);
        this._fanDecisionLabel = this._makeLabel("Loading…", "omnibook-text", true);
        root.add_child(this._fanHeading);
        root.add_child(this._fanDecisionLabel);

        root.add_child(this._makeLabel("HP Thermal Mode", "omnibook-heading", false));
        this._hpModeButtons = {};
        for (let row = 0; row < 2; row++) {
            const box = new St.BoxLayout({ style_class: "omnibook-row", x_expand: true });
            for (let col = 0; col < 2; col++) {
                const mode = MODES[row * 2 + col];
                const button = this._makeButton(mode.label, () => {
                    if (mode.key !== this._activeMode) {
                        this._runAction([THERMAL_HELPER, "set", mode.key], false);
                    }
                });
                this._hpModeButtons[mode.key] = button;
                box.add_child(button);
            }
            root.add_child(box);
        }

        this._boostButton = this._makeButton("Fan Boost (30 seconds)", () => {
            this._runAction([THERMAL_HELPER, this._boostActive ? "auto" : "boost"], false);
        });
        root.add_child(this._boostButton);

        root.add_child(this._makeLabel("Custom Fan Curves", "omnibook-heading", false));
        this._curveButtons = {};
        for (let row = 0; row < 2; row++) {
            const box = new St.BoxLayout({ style_class: "omnibook-row", x_expand: true });
            for (let col = 0; col < 2; col++) {
                const mode = MODES[row * 2 + col];
                const button = this._makeButton(mode.label, () => {
                    if (mode.key !== this._activeCurve) {
                        this._runAction([THERMAL_HELPER, "curve", mode.key], false);
                    }
                });
                this._curveButtons[mode.key] = button;
                box.add_child(button);
            }
            root.add_child(box);
        }
        const curveFooter = new St.BoxLayout({ style_class: "omnibook-row", x_expand: true });
        this._autoCurveButton = this._makeButton("HP default", () => {
            if (this._activeCurve !== "auto") {
                this._runAction([THERMAL_HELPER, "curve", "auto"], false);
            }
        });
        this._editCurvesButton = this._makeButton("Edit Curves…", () => {
            try {
                Gio.Subprocess.new([EDITOR_HELPER], Gio.SubprocessFlags.NONE);
                this.menu.close();
            } catch (err) {
                this._message = String(err);
                this._render();
            }
        });
        curveFooter.add_child(this._autoCurveButton);
        curveFooter.add_child(this._editCurvesButton);
        root.add_child(curveFooter);

        this._batteryBox = new St.BoxLayout({ vertical: true, x_expand: true });
        this._batteryBox.hide();
        root.add_child(this._batteryBox);

        const batteryHeader = new St.BoxLayout({ style_class: "omnibook-row", x_expand: true });
        const batteryTitle = this._makeLabel("Battery Charging", "omnibook-heading", false);
        batteryTitle.x_expand = true;
        this._nativeLimitButton = this._makeButton("HP hard 80% limit", () => {
            const native = this._charge.native_limit;
            if (native === "on" || native === "off") {
                this._runAction([
                    CHARGE_HELPER,
                    native === "on" ? "native-disable" : "native-enable"
                ], false);
            }
        });
        this._nativeLimitButton.x_expand = false;
        this._nativeLimitButton.hide();
        batteryHeader.add_child(batteryTitle);
        batteryHeader.add_child(this._nativeLimitButton);
        this._batteryBox.add_child(batteryHeader);

        this._chargeSummaryLabel = this._makeLabel("", "omnibook-text", true);
        this._chargeDecisionLabel = this._makeLabel("", "omnibook-text", true);
        this._batteryBox.add_child(this._chargeSummaryLabel);
        this._batteryBox.add_child(this._chargeDecisionLabel);

        this._softLimitInputsRow = new St.BoxLayout({
            style_class: "omnibook-row",
            x_expand: true
        });
        this._softLimitInputsRow.add_child(this._makeLabel("Stop at", "omnibook-text", false));
        this._stopEntry = new St.Entry({ text: "80", style_class: "omnibook-entry" });
        this._stopEntry.clutter_text.connect("text-changed", () => {
            if (!this._syncingEntries) {
                this._chargeEdited = true;
                this._updateChargeSaveButton();
            }
        });
        this._softLimitInputsRow.add_child(this._stopEntry);
        this._softLimitInputsRow.add_child(this._makeLabel("%  Resume at", "omnibook-text", false));
        this._resumeEntry = new St.Entry({ text: "75", style_class: "omnibook-entry" });
        this._resumeEntry.clutter_text.connect("text-changed", () => {
            if (!this._syncingEntries) {
                this._chargeEdited = true;
                this._updateChargeSaveButton();
            }
        });
        this._softLimitInputsRow.add_child(this._resumeEntry);
        this._softLimitInputsRow.add_child(this._makeLabel("%", "omnibook-text", false));
        this._batteryBox.add_child(this._softLimitInputsRow);

        this._softLimitActionsRow = new St.BoxLayout({
            style_class: "omnibook-row",
            x_expand: true
        });
        this._softLimitToggleButton = this._makeButton("Enable Soft Limit", () => {
            this._runAction([
                CHARGE_HELPER,
                this._charge.enabled ? "disable" : "enable"
            ], false);
        });
        this._saveChargeButton = this._makeButton("Save", () => {
            const parsed = this._parsedThresholds();
            if (!parsed) {
                return;
            }
            this._runAction([
                CHARGE_HELPER,
                "set",
                String(parsed.stop),
                String(parsed.stop - parsed.resume)
            ], true);
        });
        this._saveChargeButton.x_expand = false;
        this._softLimitActionsRow.add_child(this._softLimitToggleButton);
        this._softLimitActionsRow.add_child(this._saveChargeButton);
        this._batteryBox.add_child(this._softLimitActionsRow);

        this._messageLabel = this._makeLabel("", "omnibook-message", true);
        this._messageLabel.hide();
        root.add_child(this._messageLabel);

        this._tempsBox = new St.BoxLayout({ vertical: true, x_expand: true });
        this._tempsBox.hide();
        root.add_child(this._tempsBox);
    }

    _parsedThresholds() {
        const stopText = this._stopEntry.get_text().trim();
        const resumeText = this._resumeEntry.get_text().trim();
        if (!/^[0-9]+$/.test(stopText) || !/^[0-9]+$/.test(resumeText)) {
            return null;
        }
        const stop = parseInt(stopText, 10);
        const resume = parseInt(resumeText, 10);
        if (stop < 2 || stop > 100 || resume < 1 || resume >= stop) {
            return null;
        }
        return { stop, resume };
    }

    _updateChargeSaveButton() {
        const valid = this._chargeEdited && this._parsedThresholds() !== null;
        this._setButtonState(this._saveChargeButton, !this._pending && valid, false);
    }

    _runAction(argv, isChargeSave) {
        if (this._pending) {
            return;
        }
        this._pending = true;
        this._message = "";
        this._render();
        runCommandAsync(argv, (result) => {
            if (this._destroyed) {
                return;
            }
            this._pending = false;
            if (!result.ok) {
                this._message = result.stderr.trim() || "Could not apply the setting.";
            } else if (isChargeSave) {
                this._chargeEdited = false;
            }
            this._render();
            this._refresh();
        });
    }

    _refresh() {
        runCommandAsync([THERMAL_HELPER, "status"], (result) => {
            if (this._destroyed) {
                return;
            }
            if (result.ok) {
                const lines = result.stdout.trim().split("\n");
                this._activeMode = lines[0] === "unavailable" ? "" : (lines[0] || "");
                this._fanRpm = /^[0-9]+$/.test(lines[1] || "") ? lines[1] : "";
                this._boostActive = lines[2] === "Y";
                this._activeCurve = lines[3] || "unavailable";
                try {
                    this._temperatures = JSON.parse(lines[4] || "[]");
                    this._hpModes = JSON.parse(lines[5] || "[]");
                    this._fan = JSON.parse(lines[6] || "{}");
                } catch (_err) {
                    this._temperatures = [];
                    this._hpModes = [];
                    this._fan = {};
                }
            }
            this._render();
        });

        if (GLib.file_test(CHARGE_HELPER, GLib.FileTest.IS_EXECUTABLE)) {
            runCommandAsync([CHARGE_HELPER, "status"], (result) => {
                if (this._destroyed) {
                    return;
                }
                if (result.ok) {
                    try {
                        this._charge = JSON.parse(result.stdout || "{}");
                        if (this._charge.service_active === true && !this._chargeEdited) {
                            this._syncingEntries = true;
                            this._stopEntry.set_text(String(this._charge.limit));
                            this._resumeEntry.set_text(String(this._charge.limit - this._charge.hysteresis));
                            this._syncingEntries = false;
                        }
                    } catch (_err) {
                        this._charge = {};
                    }
                }
                this._render();
            });
        } else {
            this._charge = {};
        }
    }

    _fanDecision() {
        const state = this._fan.state || "";
        if (!state) {
            return "Fan service unavailable.";
        }
        if (state === "Restoring HP fan control") {
            return "Restoring HP fan control. The firmware has not confirmed the handoff.";
        }
        if (this._fan.target > 0) {
            return this._boostActive
                ? `Fan boost requests ${this._fan.target} RPM.`
                : `The custom curve requests ${this._fan.target} RPM.`;
        }
        if (state === "Firmware cooling") {
            return "HP controls the fan for temperature safety.";
        }
        if (state === "Checking firmware fan speed") {
            return "HP controls the fan during a scheduled speed check.";
        }
        if (state === "Firmware fan speed is already sufficient") {
            return "HP already calls for at least as much cooling as the selected curve.";
        }
        if (state === "Automatic") {
            const customCurve = MODES.some(mode => mode.key === this._activeCurve);
            return customCurve
                ? "HP controls the fan below the first point of the selected curve."
                : "HP controls the fan.";
        }
        return state;
    }

    _chargeSummary() {
        const states = {
            "Charging": "Charging",
            "Not charging": "Not charging",
            "Discharging": "Discharging",
            "Full": "Fully charged"
        };
        const parts = [states[this._charge.battery_status] || "Charging status unavailable"];
        if (typeof this._charge.capacity === "number") {
            parts.push(`${this._charge.capacity}%`);
        }
        if (this._charge.online === true) {
            parts.push("Plugged in");
        } else if (this._charge.online === false) {
            parts.push("Unplugged");
        }
        if ((this._charge.battery_status === "Charging" || this._charge.battery_status === "Discharging")
                && this._charge.power_watts > 0) {
            parts.push(`${this._charge.power_watts.toFixed(1)} W`);
        }
        return parts.join(" · ");
    }

    _chargeDecision() {
        const available = this._charge.service_active === true;
        const native = this._charge.native_limit;
        if (!available) {
            if (native === "on") {
                return "Charge-limit service is inactive. HP hard 80% limit is enabled.";
            }
            if (native === "unknown") {
                return "Charge-limit service is inactive. Could not verify the HP charging limit.";
            }
            return "Charge-limit service is inactive.";
        }
        const nativeNote = native === "on"
            ? (this._charge.enabled && this._charge.limit > 80
                ? " HP hard 80% limit is also on and caps charging at 80%."
                : " HP hard 80% limit is also on.")
            : (native === "unknown"
                ? " Could not verify the HP charging limit."
                : "");
        if (this._charge.state !== "Automatic charging" && this._charge.state !== "Charging paused") {
            return (this._charge.state || "") + nativeNote;
        }
        if (!this._charge.enabled) {
            if (native === "on") {
                return "HP hard 80% limit is enabled.";
            }
            if (native === "unknown") {
                return "Could not verify the HP charging limit.";
            }
            return "Custom soft limit off. HP manages charging.";
        }
        if (this._charge.online === false) {
            return "The soft limit applies when plugged in." + nativeNote;
        }
        const resume = this._charge.limit - this._charge.hysteresis;
        if (this._charge.paused && this._charge.battery_status === "Not charging") {
            return `Held by the custom soft limit at ${this._charge.limit}%. Charging resumes at ${resume}%.` + nativeNote;
        }
        if (native === "on" && this._charge.limit > 80
                && this._charge.battery_status === "Not charging" && this._charge.capacity >= 79) {
            return `Held by the HP hard 80% limit (custom soft limit is set to ${this._charge.limit}%).`;
        }
        if (this._charge.battery_status === "Charging" && this._charge.capacity < this._charge.limit) {
            return `Charging toward the ${this._charge.limit}% limit.` + nativeNote;
        }
        return `Soft limit on. Stops at ${this._charge.limit}% and resumes at ${resume}%.` + nativeNote;
    }

    _sensorName(sensor) {
        const name = SENSOR_NAMES[sensor.kind];
        return name && sensor.label ? `${name} (${sensor.label})` : (name || sensor.label || "");
    }

    _render() {
        const customCurve = MODES.some(mode => mode.key === this._activeCurve);
        this._fanHeading.set_text(
            this._fanRpm ? `Fan · ${Number(this._fanRpm).toLocaleString()} RPM` : "Fan speed unavailable"
        );
        this._fanDecisionLabel.set_text(this._fanDecision());

        for (const mode of MODES) {
            const available = this._hpModes.indexOf(mode.key) !== -1;
            const selected = !customCurve && !this._boostActive && mode.key === this._activeMode;
            this._setButtonState(this._hpModeButtons[mode.key], !this._pending && available, selected);
        }

        this._boostButton.set_label(this._boostActive ? "End Fan Boost" : "Fan Boost (30 seconds)");
        this._setButtonState(
            this._boostButton,
            !this._pending && this._activeCurve !== "unavailable",
            this._boostActive
        );

        const curvesReady = this._activeCurve !== "unavailable";
        for (const mode of MODES) {
            const selected = !this._boostActive && mode.key === this._activeCurve;
            this._setButtonState(this._curveButtons[mode.key], !this._pending && curvesReady, selected);
        }
        this._setButtonState(
            this._autoCurveButton,
            !this._pending && curvesReady,
            !this._boostActive && this._activeCurve === "auto"
        );

        const chargeAvailable = this._charge.service_active === true;
        const native = this._charge.native_limit;
        const showBattery = chargeAvailable || Boolean(native) || Boolean(this._charge.battery_status);
        this._batteryBox.visible = showBattery;
        if (showBattery) {
            this._chargeSummaryLabel.set_text(this._chargeSummary());
            this._chargeDecisionLabel.set_text(this._chargeDecision());

            this._nativeLimitButton.visible = Boolean(native);
            if (native) {
                const label = native === "on"
                    ? "HP hard 80% · On"
                    : (native === "off" ? "HP hard 80% · Off" : "HP hard 80% · ?");
                this._nativeLimitButton.set_label(label);
                this._setButtonState(
                    this._nativeLimitButton,
                    !this._pending && (native === "on" || native === "off"),
                    native === "on"
                );
            }

            this._softLimitInputsRow.visible = chargeAvailable;
            this._softLimitActionsRow.visible = chargeAvailable;
            if (chargeAvailable) {
                this._softLimitToggleButton.set_label(
                    this._charge.enabled ? "Disable Soft Limit" : "Enable Soft Limit"
                );
                this._setButtonState(this._softLimitToggleButton, !this._pending, Boolean(this._charge.enabled));
                this._updateChargeSaveButton();
            }
        }

        if (this._pending || this._message) {
            this._messageLabel.set_text(this._pending ? "Applying setting…" : this._message);
            this._messageLabel.show();
        } else {
            this._messageLabel.hide();
        }

        this._tempsBox.destroy_all_children();
        if (this._temperatures.length > 0) {
            this._tempsBox.add_child(this._makeLabel("Temperatures", "omnibook-heading", false));
            for (let i = 0; i < this._temperatures.length; i += 2) {
                const row = new St.BoxLayout({ style_class: "omnibook-temp-row", x_expand: true });
                for (let j = i; j < Math.min(i + 2, this._temperatures.length); j++) {
                    const sensor = this._temperatures[j];
                    const cell = new St.BoxLayout({ style_class: "omnibook-temp-cell", x_expand: true });
                    const name = this._makeLabel(this._sensorName(sensor), "omnibook-text", false);
                    name.x_expand = true;
                    const value = this._makeLabel(`${Math.round(sensor.temperature)} °C`, "omnibook-text", false);
                    cell.add_child(name);
                    cell.add_child(value);
                    row.add_child(cell);
                }
                this._tempsBox.add_child(row);
            }
            this._tempsBox.show();
        } else {
            this._tempsBox.hide();
        }
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new OmnibookThermalApplet(metadata, orientation, panelHeight, instanceId);
}

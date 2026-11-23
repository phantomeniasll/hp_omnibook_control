import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))

import battery_limit
import control_runner
import curve_control
import status_text
import temperature_status


class CurveControlTests(unittest.TestCase):
    def _valid_profiles(self):
        return {
            "quiet": [[60, 3150], [80, 4200]],
            "balanced": [[54, 3300], [78, 4500]],
            "cool": [[48, 3450], [72, 4500]],
            "performance": [[45, 3700], [69, 4500]],
        }

    def test_check_profiles_accepts_valid_curves(self):
        profiles = self._valid_profiles()
        self.assertEqual(curve_control.check_profiles(profiles), profiles)

    def test_check_profiles_rejects_invalid_inputs(self):
        cases = [
            {"quiet": [[60, 3150], [80, 4200]]},
            {**self._valid_profiles(), "quiet": [[60, 3150]]},
            {**self._valid_profiles(), "quiet": [[60, 3150], [60, 3200]]},
            {**self._valid_profiles(), "quiet": [[29, 3150], [80, 4200]]},
            {**self._valid_profiles(), "quiet": [[60, 3150], [83, 4200]]},
            {**self._valid_profiles(), "quiet": [[60, 3125], [80, 4200]]},
            {**self._valid_profiles(), "quiet": [[60, 3500], [80, 3400]]},
            {**self._valid_profiles(), "quiet": [[True, 3150], [80, 4200]]},
        ]
        for bad in cases:
            with self.assertRaises(ValueError):
                curve_control.check_profiles(bad)

    def test_curve_rpm_interpolation_and_bounds(self):
        points = [[50, 3000], [60, 3500], [70, 4500]]
        self.assertEqual(curve_control.curve_rpm(points, 49.9), 0)
        self.assertEqual(curve_control.curve_rpm(points, 50), 3000)
        self.assertEqual(curve_control.curve_rpm(points, 55), 3250)
        self.assertEqual(curve_control.curve_rpm(points, 65), 4000)
        self.assertEqual(curve_control.curve_rpm(points, 90), 4500)

    def test_load_status_detects_staleness(self):
        with tempfile.TemporaryDirectory() as tmp:
            status_file = Path(tmp) / "status.json"
            status_file.write_text(json.dumps({
                "profile": "auto",
                "state": "Automatic",
                "updated_at": 50.0,
            }))
            with mock.patch.object(curve_control, "STATUS", status_file):
                with mock.patch.object(curve_control, "boottime", return_value=58.0):
                    self.assertEqual(curve_control.load_status()["profile"], "auto")
                with mock.patch.object(curve_control, "boottime", return_value=90.0):
                    self.assertEqual(curve_control.load_status(), {})

    def test_read_fan_rpm_fallback_and_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            devices = Path(tmp)
            with mock.patch.object(curve_control, "ACPI_DEVICES", devices), \
                 mock.patch.object(curve_control, "RPM", devices / "PNP0C0B:00" / "fan_speed_rpm"):
                self.assertIsNone(curve_control.read_fan_rpm())
                alt = devices / "PNP0C0B:01"
                alt.mkdir()
                (alt / "fan_speed_rpm").write_text("3200\n")
                self.assertEqual(curve_control.read_fan_rpm(), 3200)


class BatteryLimitTests(unittest.TestCase):
    def test_check_settings(self):
        battery_limit.check_settings(80, 5)
        battery_limit.check_settings(2, 1)
        battery_limit.check_settings(100, 99)
        for limit, hysteresis in [(1, 1), (101, 5), (80, 0), (80, 80), (True, 5), (80, False)]:
            with self.assertRaises(ValueError):
                battery_limit.check_settings(limit, hysteresis)

    def test_target_mode_hysteresis(self):
        self.assertFalse(battery_limit.target_mode(False, True, 95, True, 80, 5))
        self.assertFalse(battery_limit.target_mode(True, False, 95, True, 80, 5))
        self.assertFalse(battery_limit.target_mode(True, True, 75, True, 80, 5))
        self.assertFalse(battery_limit.target_mode(True, True, 77, False, 80, 5))
        self.assertTrue(battery_limit.target_mode(True, True, 77, True, 80, 5))
        self.assertTrue(battery_limit.target_mode(True, True, 80, False, 80, 5))

    def test_status_detects_stale_runtime_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            status_file = root / "status.json"
            config_file = root / "settings.json"
            config_file.write_text(json.dumps({"enabled": True, "limit": 80, "hysteresis": 5}))
            status_file.write_text(json.dumps({
                "paused": False,
                "state": "Automatic charging",
                "updated_at": 100.0,
            }))
            with mock.patch.object(battery_limit, "STATUS", status_file), \
                 mock.patch.object(battery_limit, "CONFIG", config_file), \
                 mock.patch.object(battery_limit, "NATIVE_LIMIT", root / "missing"), \
                 mock.patch.object(battery_limit, "BATTERY", root / "missing_bat"), \
                 mock.patch.object(battery_limit, "AC", root / "missing_ac"), \
                 mock.patch.object(battery_limit, "POWER_SUPPLY", root / "missing_ps"):
                with mock.patch.object(battery_limit, "boottime", return_value=110.0):
                    fresh = battery_limit.status()
                self.assertTrue(fresh["service_active"])
                with mock.patch.object(battery_limit, "boottime", return_value=200.0):
                    stale = battery_limit.status()
                self.assertFalse(stale["service_active"])
                self.assertIn("unresponsive", stale["state"])


class ControlRunnerTests(unittest.TestCase):
    def test_dispatch_ping_and_rejects_unknown_commands(self):
        control_runner.dispatch(["ping"])
        for bad in [
            "fan",
            [],
            ["fan"],
            ["fan", "select"],
            ["fan", "select", "quiet", "extra"],
            ["fan", "select", 123],
            ["battery", "run"],
            ["battery", "load-driver"],
            ["other", "enable"],
        ]:
            with self.assertRaises(ValueError):
                control_runner.dispatch(bad)


class TemperatureStatusTests(unittest.TestCase):
    def test_readings_parsing_and_sorting(self):
        with tempfile.TemporaryDirectory() as tmp:
            sysfs = Path(tmp)
            hwmon = sysfs / "hwmon"
            entries = [
                ("hwmon0", "mt7921e", {"temp1_input": "43200"}),
                ("hwmon1", "BAT0", {"temp1_input": "30000"}),
                ("hwmon2", "nvme", {"temp1_input": "39100", "temp1_label": "Composite"}),
                ("hwmon3", "k10temp", {"temp1_input": "58600", "temp1_label": "Tctl"}),
                ("hwmon4", "amdgpu", {"temp1_input": "47400", "temp1_label": "edge"}),
                ("hwmon5", "acpitz", {"temp1_input": "200000"}),
            ]
            for name, driver, files in entries:
                device = hwmon / name
                device.mkdir(parents=True)
                (device / "name").write_text(driver + "\n")
                for filename, value in files.items():
                    (device / filename).write_text(value + "\n")
            result = temperature_status.readings(sysfs)
            self.assertEqual([r["kind"] for r in result], ["cpu", "gpu", "ssd", "wifi"])
            self.assertEqual(result[0], {"kind": "cpu", "label": "", "temperature": 58.6})
            self.assertEqual(result[2], {"kind": "ssd", "label": "", "temperature": 39.1})


class StatusTextTests(unittest.TestCase):
    def test_fan_decision_messages(self):
        self.assertIn("unavailable", status_text.fan_decision({}))
        self.assertIn("4,500 RPM", status_text.fan_decision({
            "state": "Fan Boost", "target": 4500, "boost": True,
        }))
        self.assertIn("3,650 RPM", status_text.fan_decision({
            "state": "Custom curve", "target": 3650, "boost": False,
        }))
        self.assertIn("below the first point", status_text.fan_decision({
            "state": "Automatic", "profile": "balanced", "target": 0,
        }))

    def test_charge_summary_and_combined_hard_soft_decisions(self):
        summary = status_text.charge_summary({
            "battery_status": "Charging",
            "capacity": 65,
            "online": True,
            "power_watts": 12.34,
        })
        self.assertEqual(summary, "Charging · 65% · Plugged in · 12.3 W")

        both_soft_lower = status_text.charge_decision({
            "service_active": True,
            "state": "Charging paused",
            "enabled": True,
            "paused": True,
            "online": True,
            "limit": 60,
            "hysteresis": 5,
            "capacity": 78,
            "battery_status": "Not charging",
            "native_limit": "on",
        })
        self.assertIn("Held by the custom soft limit at 60%", both_soft_lower)
        self.assertIn("HP hard 80% limit is also on.", both_soft_lower)

        both_soft_higher = status_text.charge_decision({
            "service_active": True,
            "state": "Automatic charging",
            "enabled": True,
            "paused": False,
            "online": True,
            "limit": 90,
            "hysteresis": 5,
            "capacity": 80,
            "battery_status": "Not charging",
            "native_limit": "on",
        })
        self.assertIn("Held by the HP hard 80% limit", both_soft_higher)
        self.assertIn("90%", both_soft_higher)

        inactive_with_native = status_text.charge_decision({
            "service_active": False,
            "native_limit": "on",
        })
        self.assertIn("HP hard 80% limit is enabled", inactive_with_native)


class MintAppletMetadataTests(unittest.TestCase):
    def test_cinnamon_applet_metadata_is_valid(self):
        meta_path = ROOT / "packaging/mint/cinnamon-applet/omnibook-thermal@omnibook/metadata.json"
        meta = json.loads(meta_path.read_text())
        self.assertEqual(meta["uuid"], "omnibook-thermal@omnibook")
        self.assertTrue((meta_path.parent / "applet.js").is_file())
        self.assertTrue((meta_path.parent / "stylesheet.css").is_file())


if __name__ == "__main__":
    unittest.main()

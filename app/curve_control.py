import errno
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from temperature_status import readings

BASE = Path(__file__).resolve().parent
STATE = Path("/var/lib/omnibook-fan-curves")
RUNTIME = Path("/run/omnibook-fan-curves")
CONFIG = STATE / "curves.json"
STATUS = RUNTIME / "status.json"
BOOST = RUNTIME / "boost-until"
MODULE = Path("/sys/module/omnibook_fan_probe")
PARAM = MODULE / "parameters"
RPM = Path("/sys/bus/acpi/devices/PNP0C0B:00/fan_speed_rpm")
KEYS = ("quiet", "balanced", "cool", "performance")
MIN_RPM, MAX_RPM = 3000, 4500
BIN = Path(os.environ.get("OMNIBOOK_KMOD_BIN", "/usr/sbin"))


def atomic_write(path, data):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        file.write(data)
    try:
        temporary.chmod(0o644)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def check_profiles(profiles):
    if not isinstance(profiles, dict) or set(profiles) != set(KEYS):
        raise ValueError("Exactly four curves are required.")
    for points in profiles.values():
        if not isinstance(points, list) or not 2 <= len(points) <= 12:
            raise ValueError("Each curve needs 2 to 12 points.")
        previous_temp, previous_rpm = 29, MIN_RPM
        for point in points:
            if not isinstance(point, list) or len(point) != 2:
                raise ValueError("Each point needs a temperature and RPM.")
            temperature, rpm = point
            if type(temperature) is not int or not previous_temp < temperature <= 82:
                raise ValueError("Temperatures must increase strictly from 30 to 82°C.")
            if type(rpm) is not int or not previous_rpm <= rpm <= MAX_RPM or rpm % 50:
                raise ValueError("RPM must be nondecreasing, from 3,000 to 4,500 in 50 RPM steps.")
            previous_temp, previous_rpm = temperature, rpm
    return profiles


def load_config():
    path = CONFIG if CONFIG.is_file() else BASE / "curves.json"
    config = json.loads(path.read_text())
    if config["active"] not in (*KEYS, "auto"):
        raise ValueError("Unknown active curve.")
    check_profiles(config["profiles"])
    return config


def load_status():
    try:
        return json.loads(STATUS.read_text())
    except (OSError, ValueError):
        return {}


def change_config(command, argument):
    with (STATE / "config.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        config = load_config()
        if command in ("save", "save-select"):
            edits = json.loads(argument)
            config["profiles"] = check_profiles(edits["profiles"])
            if command == "save-select":
                if edits["active"] not in KEYS:
                    raise ValueError("Unknown active curve.")
                config["active"] = edits["active"]
        elif argument in (*KEYS, "auto"):
            config["active"] = argument
        else:
            raise ValueError("Unknown curve.")
        atomic_write(CONFIG, json.dumps(config, indent=2) + "\n")


def sensor(directory, label_file, label, value_file):
    for device in directory.glob("*"):
        try:
            if (device / label_file).read_text().strip() == label:
                return int((device / value_file).read_text())
        except (OSError, ValueError):
            continue
    raise OSError(f"{label} temperature is unavailable")


def curve_rpm(points, temperature):
    if temperature < points[0][0]:
        return 0
    for (low_temp, low_rpm), (high_temp, high_rpm) in zip(points, points[1:]):
        if temperature <= high_temp:
            requested = low_rpm + (high_rpm - low_rpm) * (temperature - low_temp) / (high_temp - low_temp)
            return round(requested / 50) * 50
    return points[-1][1]


def firmware_control():
    if ((PARAM / "curve").exists() and (PARAM / "curve").read_text().strip() == "Y" and
            (PARAM / "active").read_text().strip() == "Y"):
        (PARAM / "cancel").write_text("Y\n")


def ensure_module():
    with Path("/run/omnibook-thermal.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if MODULE.exists() and (PARAM / "target").exists():
            if (PARAM / "curve").read_text().strip() == "Y":
                return
        if MODULE.exists():
            if (PARAM / "active").read_text().strip() == "Y":
                raise OSError("Waiting for the previous Fan Boost to finish")
            subprocess.run([BIN / "rmmod", MODULE.name], check=True, capture_output=True, text=True)
        module_path = BASE / os.uname().release / "omnibook-fan-probe.ko"
        if not module_path.is_file():
            raise OSError("Fan curves are unavailable for this kernel")
        subprocess.run([BIN / "insmod", module_path, "curve=1"], check=True, capture_output=True, text=True)


def boost_time():
    try:
        return float(BOOST.read_text())
    except (OSError, ValueError):
        return 0


def run():
    stopping = False
    hot = False
    last_target = 0
    manual_since = None
    pause_until = 0

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping:
            now = time.monotonic()
            status = {"profile": "auto", "boost": False, "target": 0,
                      "temperature": None, "rpm": None, "state": "Automatic"}
            try:
                config = load_config()
                status["profile"] = profile = config["active"]
                status["boost"] = boosting = boost_time() > now
                status["rpm"] = int(RPM.read_text())
                cpu = sensor(Path("/sys/class/hwmon"), "name", "k10temp", "temp1_input")
                acpi = sensor(Path("/sys/class/thermal"), "type", "acpitz", "temp")
                status["temperature"] = round(cpu / 1000, 1)
                if not 0 < cpu < 120000 or not 0 < acpi < 120000:
                    raise OSError("Invalid temperature reading")
                hot = cpu >= (82000 if hot else 85000) or acpi >= (72000 if hot else 75000)
                requested = MAX_RPM if boosting else (
                    0 if profile == "auto" else curve_rpm(config["profiles"][profile], cpu / 1000)
                )
                if manual_since is not None and now - manual_since >= 120 and not boosting:
                    pause_until = now + 12
                if hot or (now < pause_until and not boosting):
                    requested = 0
                    status["state"] = "Firmware cooling" if hot else "Checking firmware fan speed"
                if requested:
                    if abs(requested - last_target) == 50 and not boosting:
                        requested = last_target
                    ensure_module()
                    try:
                        (PARAM / "target").write_text(f"{requested}\n")
                        if manual_since is None:
                            manual_since = now
                        last_target = requested
                        status["target"] = requested
                        status["state"] = "Fan Boost" if boosting else "Custom curve"
                    except OSError as error:
                        if error.errno not in (errno.EAGAIN, errno.EBUSY):
                            raise
                        firmware_control()
                        status["state"] = "Firmware fan speed is already sufficient"
                        manual_since, last_target = None, 0
                else:
                    firmware_control()
                    manual_since, last_target = None, 0
            except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
                try:
                    firmware_control()
                except OSError:
                    pass
                manual_since, last_target = None, 0
                status["state"] = "Firmware control: " + str(error)
            atomic_write(STATUS, json.dumps(status) + "\n")
            time.sleep(1)
    finally:
        firmware_control()


def hp_profile_device():
    for device in Path("/sys/class/platform-profile").glob("*"):
        try:
            if (device / "name").read_text().strip() == "hp-wmi":
                return device
        except OSError:
            continue
    return None


def read_hp_mode():
    device = hp_profile_device()
    if device is not None:
        try:
            return (device / "profile").read_text().strip(), (device / "choices").read_text().split()
        except OSError:
            pass
    return None, ()


def switch_hp_mode(mode):
    current, choices = read_hp_mode()
    if mode not in KEYS or mode not in choices:
        raise OSError("This kernel does not expose that HP thermal mode.")
    if current != mode:
        device = hp_profile_device()
        if device is None:
            raise OSError("The HP thermal mode device disappeared.")
        (device / "profile").write_text(mode + "\n")
        if read_hp_mode()[0] != mode:
            raise OSError("The HP driver did not confirm the selected mode.")


def main(args):
    if args == ["config"]:
        print(json.dumps(load_config()))
    elif args == ["status"]:
        print(json.dumps(load_status()))
    elif args == ["widget-status"]:
        status = load_status()
        print("Y" if status.get("boost") else "N")
        print(status.get("profile", "unavailable"))
        print(json.dumps(readings(), ensure_ascii=True))
    elif args == ["panel-status"]:
        mode, choices = read_hp_mode()
        status = load_status()
        print(mode or "unavailable")
        try:
            print(int(RPM.read_text()))
        except (OSError, ValueError):
            print()
        print("Y" if status.get("boost") else "N")
        print(status.get("profile", "unavailable"))
        print(json.dumps(readings(), ensure_ascii=True))
        print(json.dumps(choices))
        print(json.dumps({"target": status.get("target", 0), "state": status.get("state", "")}))
    elif os.geteuid() != 0:
        from control_runner import request
        request("fan", args)
    elif len(args) == 2 and args[0] == "hp-mode":
        switch_hp_mode(args[1])
    elif len(args) == 2 and args[0] in ("save", "save-select", "select"):
        if not STATE.is_dir():
            raise OSError("Install the background fan service first.")
        change_config(*args)
    elif args in (["boost"], ["stop-boost"]):
        if not STATUS.is_file():
            raise OSError("The background fan service is unavailable.")
        if args == ["boost"]:
            atomic_write(BOOST, str(time.monotonic() + 30))
        else:
            BOOST.unlink(missing_ok=True)
    elif args == ["run"]:
        if not CONFIG.exists():
            atomic_write(CONFIG, (BASE / "curves.json").read_text())
        run()
    else:
        raise ValueError("Unknown fan curve command.")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))

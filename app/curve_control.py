import errno
import fcntl
import json
import os
from pathlib import Path
import select
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
BOOST_DURATION = 30
STATUS_HEARTBEAT = 5
STATUS_MAX_AGE = 15
MODULE = Path("/sys/module/omnibook_fan_probe")
PARAM = MODULE / "parameters"
HP_MODE_FALLBACK = PARAM / "hp_mode"
ACPI_DEVICES = Path("/sys/bus/acpi/devices")
RPM = ACPI_DEVICES / "PNP0C0B:00" / "fan_speed_rpm"
KEYS = ("quiet", "balanced", "cool", "performance")
MIN_RPM, MAX_RPM = 3000, 4500
BIN = Path(os.environ.get("OMNIBOOK_KMOD_BIN", "/usr/sbin"))


def boottime():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def read_fan_rpm():
    candidates = [RPM]
    if not RPM.is_file():
        candidates.extend(sorted(ACPI_DEVICES.glob("PNP0C0B:*/fan_speed_rpm")))
    for path in candidates:
        try:
            return int(path.read_text())
        except (OSError, ValueError):
            continue
    return None


def atomic_write(path, data):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        file.write(data)
        file.flush()
        os.fsync(file.fileno())
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
        status = json.loads(STATUS.read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(status, dict):
        return {}
    updated_at = status.get("updated_at")
    if isinstance(updated_at, (int, float)):
        age = boottime() - updated_at
        if not -5 <= age <= STATUS_MAX_AGE:
            return {}
    return status


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
    for device in sorted(directory.glob("*")):
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
    if fan_recovering():
        return
    if ((PARAM / "curve").exists() and (PARAM / "curve").read_text().strip() == "Y" and
            (PARAM / "active").read_text().strip() == "Y"):
        (PARAM / "cancel").write_text("Y\n")


def fan_recovering():
    try:
        return (PARAM / "handoff").read_text().strip() == "recovering"
    except FileNotFoundError:
        return False


def ensure_module():
    with Path("/run/omnibook-thermal.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if MODULE.exists() and (PARAM / "target").exists():
            if (PARAM / "curve").read_text().strip() == "Y":
                return
        if MODULE.exists():
            if fan_recovering() or (PARAM / "active").read_text().strip() == "Y":
                raise OSError("Waiting for the fan override to be released")
            result = subprocess.run([BIN / "rmmod", MODULE.name], capture_output=True, text=True)
            if result.returncode:
                raise OSError(result.stderr.strip() or "Could not unload the fan control module")
        module_path = BASE / os.uname().release / "omnibook-fan-probe.ko"
        if not module_path.is_file():
            raise OSError("Fan curves are unavailable for this kernel")
        result = subprocess.run([BIN / "insmod", module_path, "curve=1"], capture_output=True, text=True)
        if result.returncode:
            raise OSError(result.stderr.strip() or "The kernel rejected the fan control module")


def boost_deadline():
    try:
        state = json.loads(BOOST.read_text())
        if isinstance(state, dict):
            state = state["until"]
        return float(state)
    except (OSError, ValueError, KeyError, TypeError):
        return 0


def change_boost(start):
    with BOOST.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not start:
            BOOST.unlink(missing_ok=True)
            return
        now = boottime()
        if now < boost_deadline():
            raise OSError("Fan Boost is already running.")
        atomic_write(BOOST, json.dumps({"until": now + BOOST_DURATION}) + "\n")


def run():
    stopping = False
    hot = False
    last_target = 0
    last_written_status = None
    last_write_time = -STATUS_HEARTBEAT
    wake_read, wake_write = os.pipe()
    os.set_blocking(wake_read, False)
    os.set_blocking(wake_write, False)

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True
        try:
            os.write(wake_write, b"\0")
        except OSError:
            pass

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping:
            now = boottime()
            status = {"profile": "auto", "boost": False, "target": 0,
                      "temperature": None, "rpm": None, "state": "Automatic"}
            try:
                config = load_config()
                status["profile"] = profile = config["active"]
                status["boost"] = boost_requested = boost_deadline() > now
                status["rpm"] = read_fan_rpm()
                cpu = sensor(Path("/sys/class/hwmon"), "name", "k10temp", "temp1_input")
                acpi = sensor(Path("/sys/class/thermal"), "type", "acpitz", "temp")
                status["temperature"] = round(cpu / 1000, 1)
                if not 0 < cpu < 120000 or not 0 < acpi < 120000:
                    raise OSError("Invalid temperature reading")
                hot = cpu >= (82000 if hot else 85000) or acpi >= (72000 if hot else 75000)
                boosting = boost_requested and not hot
                requested = MAX_RPM if boosting else (
                    0 if profile == "auto" else curve_rpm(config["profiles"][profile], cpu / 1000)
                )
                if boost_requested and hot and not requested:
                    status["state"] = "Firmware cooling"
                if requested:
                    if abs(requested - last_target) == 50 and not boosting:
                        requested = last_target
                    ensure_module()
                    try:
                        target = PARAM / "target"
                        if boosting and (PARAM / "boost_target").exists():
                            target = PARAM / "boost_target"
                        target.write_text(f"{requested}\n")
                        last_target = requested
                        status["target"] = requested
                        status["state"] = "Fan Boost" if boosting else "Custom curve"
                    except OSError as error:
                        reasons = {
                            errno.EALREADY: "Firmware fan speed is already sufficient",
                            errno.EAGAIN: "Checking firmware fan speed",
                            errno.EBUSY: "Firmware fan control unavailable",
                            errno.ERANGE: "Firmware cooling",
                            errno.EOPNOTSUPP: "Firmware did not confirm fan control",
                        }
                        if error.errno not in reasons:
                            raise
                        try:
                            firmware_control()
                        except OSError:
                            pass
                        status["state"] = reasons[error.errno]
                        last_target = 0
                else:
                    firmware_control()
                    last_target = 0
            except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
                try:
                    firmware_control()
                except OSError:
                    pass
                last_target = 0
                status["state"] = "Firmware control: " + str(error)
            if fan_recovering():
                status.update(state="Restoring HP fan control", target=0)
            if status != last_written_status or now - last_write_time >= STATUS_HEARTBEAT:
                payload = {**status, "updated_at": round(now, 3)}
                atomic_write(STATUS, json.dumps(payload) + "\n")
                last_written_status = status
                last_write_time = now
            if not stopping:
                try:
                    select.select([wake_read], [], [], 1)
                except InterruptedError:
                    pass
    finally:
        os.close(wake_read)
        os.close(wake_write)
        try:
            firmware_control()
        except OSError:
            pass
        STATUS.unlink(missing_ok=True)


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
            choices = (device / "choices").read_text().split()
        except OSError:
            choices = ()
        if choices:
            try:
                return (device / "profile").read_text().strip(), choices
            except OSError:
                pass
            try:
                mode = HP_MODE_FALLBACK.read_text().strip()
                if mode in choices:
                    return mode, choices
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
        if fan_recovering():
            status.update(state="Restoring HP fan control", target=0)
        print(mode or "unavailable")
        rpm = read_fan_rpm()
        print("" if rpm is None else rpm)
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
        if not load_status():
            raise OSError("The background fan service is unavailable.")
        change_boost(args == ["boost"])
    elif args == ["load-driver"]:
        ensure_module()
    elif args == ["run"]:
        with (STATE / "config.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
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

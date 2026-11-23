import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from curve_control import BASE, BIOS_MODULE_ARGS, BIN, atomic_write

BATTERY = Path("/sys/class/power_supply/BAT0")
AC = Path("/sys/class/power_supply/ADP1/online")
PARAM = Path("/sys/module/omnibook_charge_control/parameters/inhibit")
PREFERENCE = Path("/var/lib/omnibook-charge-limit/enabled")
CONFIG = PREFERENCE.with_name("settings.json")
STATUS = Path("/run/omnibook-charge-limit/status.json")
DEFAULT_LIMIT, DEFAULT_HYSTERESIS = 80, 5


def check_settings(limit, hysteresis):
    if type(limit) is not int or not 2 <= limit <= 100:
        raise ValueError("Charge limit must be a whole percentage from 2 to 100.")
    if type(hysteresis) is not int or not 1 <= hysteresis < limit:
        raise ValueError("Hysteresis must be at least 1 point and below the charge limit.")


def load_settings():
    try:
        settings = json.loads(CONFIG.read_text())
    except FileNotFoundError:
        return {"enabled": PREFERENCE.exists(), "limit": DEFAULT_LIMIT,
                "hysteresis": DEFAULT_HYSTERESIS}
    if not isinstance(settings, dict) or type(settings.get("enabled")) is not bool:
        raise ValueError("Invalid charge limit settings.")
    check_settings(settings.get("limit"), settings.get("hysteresis"))
    return settings


def change_settings(args):
    with CONFIG.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        settings = load_settings()
        if args in (["enable"], ["disable"]):
            settings["enabled"] = args == ["enable"]
        elif len(args) == 3 and args[0] == "set":
            limit, hysteresis = map(int, args[1:])
            check_settings(limit, hysteresis)
            settings.update(limit=limit, hysteresis=hysteresis)
        else:
            raise ValueError("Use status, enable, disable, or set LIMIT HYSTERESIS.")
        atomic_write(CONFIG, json.dumps(settings) + "\n")


def target_mode(enabled, online, capacity, paused, limit=DEFAULT_LIMIT,
                hysteresis=DEFAULT_HYSTERESIS):
    if not enabled or not online or capacity <= limit - hysteresis:
        return False
    return capacity >= limit or paused


def driver_ready():
    if PARAM.exists():
        return
    module = BASE / os.uname().release / "omnibook-charge-control.ko"
    if not module.is_file():
        raise OSError("No charge control module for this kernel")
    result = subprocess.run([BIN / "insmod", module, *BIOS_MODULE_ARGS], capture_output=True, text=True)
    if result.returncode:
        raise OSError(result.stderr.strip() or "The kernel rejected the charge control module")


def release():
    if PARAM.exists():
        PARAM.write_text("N\n")


def status():
    try:
        state = json.loads(STATUS.read_text())
    except (OSError, ValueError):
        state = {"service_active": False, "state": "Charge limit service is inactive"}
    else:
        state["service_active"] = True
    try:
        state.update(load_settings())
    except (OSError, ValueError) as error:
        state.update(enabled=False, limit=DEFAULT_LIMIT, hysteresis=DEFAULT_HYSTERESIS,
                     state=str(error))
    state["battery_status"] = None
    state["power_watts"] = None
    try:
        state["battery_status"] = (BATTERY / "status").read_text().strip()
        state["capacity"] = int((BATTERY / "capacity").read_text())
    except (OSError, ValueError):
        pass
    try:
        state["online"] = AC.read_text().strip() == "1"
    except OSError:
        state["online"] = None
    try:
        state["power_watts"] = int((BATTERY / "power_now").read_text()) / 1_000_000
    except (OSError, ValueError):
        pass
    return state


def run():
    stopping = False

    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping:
            state = {"paused": False,
                     "capacity": None, "online": False, "state": "Automatic charging"}
            try:
                settings = load_settings()
                capacity = int((BATTERY / "capacity").read_text())
                if not 0 <= capacity <= 100:
                    raise ValueError("Invalid battery charge percentage")
                state["capacity"] = capacity
                state["online"] = AC.read_text().strip() == "1"
                if settings["enabled"] and state["online"]:
                    driver_ready()
                    paused = PARAM.read_text().strip() == "Y"
                    if paused and (BATTERY / "status").read_text().strip() == "Charging":
                        release()
                        paused = False
                    if target_mode(True, True, capacity, paused, settings["limit"],
                                   settings["hysteresis"]):
                        PARAM.write_text("Y\n")
                        state["paused"] = True
                        state["state"] = "Charging paused"
                    elif paused:
                        release()
                else:
                    release()
            except (OSError, ValueError) as error:
                try:
                    release()
                except OSError:
                    pass
                state["state"] = str(error)
            atomic_write(STATUS, json.dumps(state) + "\n")
            for _ in range(5):
                if stopping:
                    break
                time.sleep(1)
    finally:
        release()


def main(args):
    if args == ["status"]:
        print(json.dumps(status()))
        return
    if os.geteuid() != 0:
        from control_runner import request
        request("battery", args)
    elif args == ["run"]:
        run()
    else:
        change_settings(args)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError) as error:
        sys.exit(str(error))

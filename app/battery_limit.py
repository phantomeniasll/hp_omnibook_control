import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from curve_control import BASE, BIN, atomic_write

BATTERY = Path("/sys/class/power_supply/BAT0")
AC = Path("/sys/class/power_supply/ADP1/online")
PARAM = Path("/sys/module/omnibook_charge_control/parameters/inhibit")
PREFERENCE = Path("/var/lib/omnibook-charge-limit/enabled")
STATUS = Path("/run/omnibook-charge-limit/status.json")
STOP, RESUME = 80, 75


def target_mode(enabled, online, capacity, paused):
    if not enabled or not online or capacity <= RESUME:
        return False
    return capacity >= STOP or paused


def driver_ready():
    if PARAM.exists():
        return
    module = BASE / os.uname().release / "omnibook-charge-control.ko"
    if not module.is_file():
        raise OSError("No charge control module for this kernel")
    result = subprocess.run([BIN / "insmod", module], capture_output=True, text=True)
    if result.returncode:
        raise OSError(result.stderr.strip() or "The kernel rejected the charge control module")


def release():
    if PARAM.exists():
        PARAM.write_text("N\n")


def status():
    try:
        state = json.loads(STATUS.read_text())
    except (OSError, ValueError):
        state = {"state": "Charge limit service is inactive"}
    state["enabled"] = PREFERENCE.exists()
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
            state = {"enabled": PREFERENCE.exists(), "paused": False,
                     "capacity": None, "online": False, "state": "Automatic charging"}
            try:
                capacity = int((BATTERY / "capacity").read_text())
                if not 0 <= capacity <= 100:
                    raise ValueError("Invalid battery charge percentage")
                state["capacity"] = capacity
                state["online"] = AC.read_text().strip() == "1"
                if state["enabled"] and state["online"]:
                    driver_ready()
                    paused = PARAM.read_text().strip() == "Y"
                    if paused and (BATTERY / "status").read_text().strip() == "Charging":
                        release()
                        paused = False
                    if target_mode(True, True, capacity, paused):
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
        raise PermissionError("Administrator authentication is required.")
    if args == ["run"]:
        run()
    elif args == ["enable"]:
        atomic_write(PREFERENCE, "80\n")
    elif args == ["disable"]:
        PREFERENCE.unlink(missing_ok=True)
    else:
        raise ValueError("Use status, enable, or disable.")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError) as error:
        sys.exit(str(error))

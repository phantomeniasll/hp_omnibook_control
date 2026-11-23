"""Run a bounded set of OmniBook controls through a root-owned systemd socket."""

import json
import os
import socket
import sys
from pathlib import Path

SOCKET = Path("/run/omnibook-control.sock")
MAX_REQUEST = 16384
OPERATIONS = {
    "fan": {"hp-mode": 1, "save": 1, "save-select": 1, "select": 1,
            "boost": 0, "stop-boost": 0},
    "battery": {"set": 2, "enable": 0, "disable": 0},
}


def request(feature, args):
    data = json.dumps([feature, *args]).encode() + b"\n"
    if len(data) > MAX_REQUEST:
        raise ValueError("OmniBook control request is too large.")
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(8)
        try:
            client.connect(str(SOCKET))
        except PermissionError as error:
            raise PermissionError("Join the omnibook-control group and sign in again.") from error
        except (FileNotFoundError, ConnectionRefusedError) as error:
            raise OSError("The OmniBook control socket is inactive.") from error
        client.sendall(data)
        with client.makefile("rb") as response:
            reply = response.readline(MAX_REQUEST)
    if not reply:
        raise OSError("The OmniBook control runner did not respond.")
    result = json.loads(reply)
    if result["error"]:
        raise OSError(result["error"])


def dispatch(command):
    if (not isinstance(command, list) or len(command) < 2 or
            any(not isinstance(value, str) for value in command)):
        raise ValueError("Invalid OmniBook control request.")
    feature, operation, *args = command
    if OPERATIONS.get(feature, {}).get(operation) != len(args):
        raise ValueError("Unknown OmniBook control request.")
    if feature == "fan":
        from curve_control import main
    else:
        from battery_limit import main
    main([operation, *args])


def serve():
    try:
        data = sys.stdin.buffer.readline(MAX_REQUEST + 1)
        if not data.endswith(b"\n") or len(data) > MAX_REQUEST:
            raise ValueError("Invalid OmniBook control request size.")
        dispatch(json.loads(data))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"error": str(error)}))
    else:
        print(json.dumps({"error": ""}))


if __name__ == "__main__":
    if sys.argv[1:] != ["serve"] or os.geteuid() != 0:
        sys.exit("The OmniBook control runner must be started by the system service.")
    serve()

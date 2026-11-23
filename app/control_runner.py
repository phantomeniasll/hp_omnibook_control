"""Run a bounded set of OmniBook controls through a root-owned systemd socket."""

import json
import os
import socket
import struct
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

SOCKET = Path("/run/omnibook-control.sock")
MAX_REQUEST = 16384
READ_TIMEOUT = 2
WORKER_TIMEOUT = 6
IDLE_TIMEOUT = 30
MAX_WORKERS = 16
PER_UID_WORKERS = 2
PER_UID_RATE = 8
PEER_CREDENTIALS = struct.Struct("=iII")
OPERATIONS = {
    "fan": {"hp-mode": 1, "save": 1, "save-select": 1, "select": 1,
            "boost": 0, "stop-boost": 0},
    "battery": {"set": 2, "enable": 0, "disable": 0,
                "native-enable": 0, "native-disable": 0},
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
    if command == ["ping"]:
        return
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


def read_request(peer):
    deadline = time.monotonic() + READ_TIMEOUT
    data = bytearray()
    while len(data) < MAX_REQUEST:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Timed out reading the OmniBook request.")
        peer.settimeout(remaining)
        chunk = peer.recv(min(4096, MAX_REQUEST - len(data)))
        if not chunk:
            break
        data.extend(chunk)
        end = data.find(b"\n")
        if end >= 0:
            return json.loads(data[:end])
    raise ValueError("Invalid OmniBook control request size.")


def reply(peer, error, timeout=1):
    try:
        peer.settimeout(timeout)
        peer.sendall(json.dumps({"error": error}).encode() + b"\n")
    except (TimeoutError, BrokenPipeError, ConnectionResetError):
        pass


def serve(peer):
    try:
        dispatch(read_request(peer))
    except (OSError, ValueError, KeyError, TypeError) as error:
        reply(peer, str(error))
    else:
        reply(peer, "")


def listen(listener):
    workers = {}
    active = Counter()
    rate = Counter()
    window_end = time.monotonic() + 1
    while True:
        now = time.monotonic()
        if now >= window_end:
            rate.clear()
            window_end = now + 1
        for process, (uid, deadline) in list(workers.items()):
            if process.poll() is None:
                if now >= deadline:
                    process.kill()
                continue
            del workers[process]
            active[uid] -= 1
            if not active[uid]:
                del active[uid]

        listener.settimeout(0.25 if workers else IDLE_TIMEOUT)
        try:
            peer, _ = listener.accept()
        except TimeoutError:
            if not workers:
                return
            continue
        with peer:
            try:
                _, uid, _ = PEER_CREDENTIALS.unpack(peer.getsockopt(
                    socket.SOL_SOCKET, socket.SO_PEERCRED, PEER_CREDENTIALS.size))
            except OSError:
                continue
            if active[uid] >= PER_UID_WORKERS or rate[uid] >= PER_UID_RATE:
                reply(peer, "Too many OmniBook requests from your account. Try again shortly.", 0.05)
                continue
            if len(workers) >= MAX_WORKERS:
                reply(peer, "The OmniBook service is busy. Try again shortly.", 0.05)
                continue
            try:
                process = subprocess.Popen([sys.executable, __file__, "serve"], stdin=peer)
            except OSError as error:
                reply(peer, str(error), 0.05)
                continue
            workers[process] = (uid, time.monotonic() + WORKER_TIMEOUT)
            active[uid] += 1
            rate[uid] += 1


if __name__ == "__main__":
    if sys.argv[1:] == ["check"]:
        try:
            request("ping", [])
        except (OSError, ValueError) as error:
            sys.exit(str(error))
        sys.exit(0)
    if os.geteuid() != 0:
        sys.exit("The OmniBook control runner must be started by the system service.")
    if sys.argv[1:] == ["listen"] and os.environ.get("LISTEN_PID") == str(os.getpid()) \
            and os.environ.get("LISTEN_FDS") == "1":
        with socket.socket(fileno=3) as listener:
            listen(listener)
    elif sys.argv[1:] == ["serve"]:
        with socket.socket(fileno=os.dup(sys.stdin.fileno())) as peer:
            serve(peer)
    else:
        sys.exit("A systemd listener socket is required.")

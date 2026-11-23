"""Run a bounded set of OmniBook controls through a root-owned systemd socket."""

import errno
import json
import os
import select
import signal
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
RELOAD_EXIT = 75
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
    for attempt in range(3):
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
        if result.get("retry") and attempt < 2:
            time.sleep(0.25)
            continue
        if result["error"]:
            raise OSError(result["error"])
        return


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


def reply(peer, error, timeout=1, retry=False):
    payload = {"error": error}
    if retry:
        payload["retry"] = True
    try:
        peer.settimeout(timeout)
        peer.sendall(json.dumps(payload).encode() + b"\n")
    except (TimeoutError, BrokenPipeError, ConnectionResetError):
        pass


def serve(peer):
    try:
        dispatch(read_request(peer))
    except OSError as error:
        if error.errno == errno.EROFS:
            reply(peer, str(error), retry=True)
            return RELOAD_EXIT
        reply(peer, str(error))
        return 0
    except (ValueError, KeyError, TypeError) as error:
        reply(peer, str(error))
        return 0
    else:
        reply(peer, "")
        return 0


def listen(listener):
    workers = {}
    active = Counter()
    rate = Counter()
    window_end = time.monotonic() + 1
    reloading = False
    wake_read, wake_write = os.pipe()
    os.set_blocking(wake_read, False)
    os.set_blocking(wake_write, False)

    def on_child(_signum, _frame):
        try:
            os.write(wake_write, b"\0")
        except OSError:
            pass

    previous_sigchld = signal.signal(signal.SIGCHLD, on_child)
    listener.setblocking(False)
    try:
        while True:
            now = time.monotonic()
            if now >= window_end:
                rate.clear()
                window_end = now + 1
            for process, (uid, deadline) in list(workers.items()):
                code = process.poll()
                if code is None:
                    if now >= deadline:
                        process.kill()
                    continue
                if code == RELOAD_EXIT:
                    reloading = True
                del workers[process]
                active[uid] -= 1
                if not active[uid]:
                    del active[uid]
            if reloading and not workers:
                return

            watched = [wake_read] if reloading else [listener, wake_read]
            timeout = 0.25 if workers else IDLE_TIMEOUT
            try:
                ready, _, _ = select.select(watched, [], [], timeout)
            except InterruptedError:
                continue
            if wake_read in ready:
                try:
                    os.read(wake_read, 4096)
                except OSError:
                    pass
                continue
            if not ready:
                if not workers:
                    return
                continue
            if reloading or listener not in ready:
                continue
            try:
                peer, _ = listener.accept()
            except BlockingIOError:
                continue
            peer.setblocking(True)
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
    finally:
        signal.signal(signal.SIGCHLD, previous_sigchld)
        os.close(wake_read)
        os.close(wake_write)


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
            sys.exit(serve(peer))
    else:
        sys.exit("A systemd listener socket is required.")

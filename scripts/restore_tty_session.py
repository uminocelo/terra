#!/usr/bin/env python3
"""Run one keys.exs restore path on the current tty.

This is for a real emulator window. It does not allocate its own PTY.
The app inherits this tty. A key is injected with TIOCSTI after raw mode
is visible on the tty, then termios is read again after the app exits.

  python3 scripts/restore_tty_session.py quit /tmp/terra-quit.txt
  python3 scripts/restore_tty_session.py interrupt /tmp/terra-interrupt.txt
  python3 scripts/restore_tty_session.py crash /tmp/terra-crash.txt
"""

import fcntl
import os
import select
import subprocess
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYS = {"quit": b"q", "interrupt": b"\x03", "crash": b"!"}


def flags(fd):
    attrs = termios.tcgetattr(fd)
    lflag = attrs[3]
    return {
        "icanon": bool(lflag & termios.ICANON),
        "echo": bool(lflag & termios.ECHO),
        "isig": bool(lflag & termios.ISIG),
    }


def inject(data):
    tty = os.open("/dev/tty", os.O_RDWR)
    try:
        for byte in data:
            fcntl.ioctl(tty, termios.TIOCSTI, bytes([byte]))
    finally:
        os.close(tty)


def main(name, dest):
    if name not in KEYS:
        print("usage: restore_tty_session.py quit|interrupt|crash DEST", file=sys.stderr)
        return 2
    if not os.isatty(0) or not os.isatty(1):
        write_result(dest, {"status": "not-run", "detail": "stdin or stdout is not a tty"})
        return 0

    tty_fd = os.open("/dev/tty", os.O_RDWR)
    err_path = dest + ".err"
    err = open(err_path, "w")
    proc = subprocess.Popen(
        ["mix", "run", "examples/keys.exs"],
        cwd=ROOT,
        stderr=err,
    )
    entered = False
    inject_error = None
    try:
        deadline = time.time() + 40
        while time.time() < deadline and proc.poll() is None:
            state = flags(tty_fd)
            raw = not state["icanon"] and not state["echo"]
            if name == "interrupt":
                raw = raw and not state["isig"]
            if raw:
                entered = True
                break
            time.sleep(0.05)
        time.sleep(0.4)
        try:
            inject(KEYS[name])
        except OSError as exc:
            inject_error = f"{type(exc).__name__}: {exc}"
        try:
            code = proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            code = proc.wait(timeout=5)
            inject_error = (inject_error or "") + "; app did not exit"
    finally:
        err.close()
        os.close(tty_fd)

    time.sleep(0.2)
    after_fd = os.open("/dev/tty", os.O_RDWR)
    report = b""
    try:
        after = flags(after_fd)
        # Ask the emulator itself, with the tty briefly out of canonical mode
        # so the reply is readable. Cooked mode is put back before we judge it.
        cooked = termios.tcgetattr(after_fd)
        raw = termios.tcgetattr(after_fd)
        raw[3] = raw[3] & ~(termios.ICANON | termios.ECHO)
        raw[6][termios.VMIN] = 0
        raw[6][termios.VTIME] = 2
        termios.tcsetattr(after_fd, termios.TCSANOW, raw)
        os.write(after_fd, b"\x1b[?25$p\x1b[?1049$p")
        deadline = time.time() + 0.8
        while time.time() < deadline:
            ready, _, _ = select.select([after_fd], [], [], 0.1)
            if not ready:
                continue
            report += os.read(after_fd, 128)
            if report.count(b"$y") >= 2 or report.count(b";") >= 2:
                break
        termios.tcsetattr(after_fd, termios.TCSANOW, cooked)
        after = flags(after_fd)
    finally:
        os.close(after_fd)

    stderr = ""
    try:
        stderr = open(err_path, errors="replace").read()[-1500:]
    except OSError:
        pass

    # A second command in this same tty. If raw mode leaked, stty still reports it.
    stty = subprocess.run(["stty", "-a"], capture_output=True, text=True)
    shell = subprocess.run(["printf", "%s%s", "TERRA_SHELL_", "OK"], capture_output=True, text=True)

    failures = []
    notes = []
    if inject_error:
        failures.append(inject_error)
    if not entered:
        failures.append("app did not take raw mode on this tty")
    for bit in ("icanon", "echo", "isig"):
        if not after.get(bit):
            failures.append(f"raw: {bit} still off")
    if "TERRA_SHELL_OK" not in (shell.stdout or ""):
        failures.append("shell command did not print")
    if b"?25;2" in report:
        failures.append("hidden cursor")
    elif b"?25;1" in report:
        notes.append("cursor visible")
    else:
        notes.append("cursor not observed")
    if b"?1049;1" in report:
        failures.append("alt screen still on")
    elif b"?1049;2" in report:
        notes.append("alt screen off")
    else:
        notes.append("alt screen not observed")
    if name == "crash":
        if "boom from view/1" not in stderr:
            failures.append("error text missing from stderr")
        else:
            notes.append("error on stderr")
    status = "fail" if failures else "pass"
    detail = "; ".join(failures + notes)
    write_result(
        dest,
        {
            "status": status,
            "detail": detail,
            "entered_raw": entered,
            "after": after,
            "returncode": code,
            "stty": (stty.stdout or "")[-500:],
            "stderr": stderr,
            "cursor": report.decode("utf-8", "replace"),
        },
    )
    print(status, detail)
    return 0 if status == "pass" else 1


def write_result(dest, payload):
    lines = [f"{key}={value}" for key, value in payload.items()]
    with open(dest, "w") as handle:
        handle.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: restore_tty_session.py quit|interrupt|crash DEST", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))

#!/usr/bin/env python3
"""Script the three restore paths of examples/keys.exs.

Documented commands (this file, via scripts/restore_matrix.sh):

  scripts/restore_matrix.sh quit        # press q, {:quit, state}
  scripts/restore_matrix.sh interrupt   # press Ctrl+C
  scripts/restore_matrix.sh crash       # press !, view/1 raises

`all` runs the three in order.
"""

import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEAVE_ALT = b"\x1b[?1049l"
SHOW_CURSOR = b"\x1b[?25h"
ENTER_ALT = b"\x1b[?1049h"
HIDE_CURSOR = b"\x1b[?25l"

PATHS = {
    "quit": b"q",
    "interrupt": b"\x03",
    "crash": b"!",
}


class Pty:
    def __init__(self, command):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            env = dict(os.environ)
            env["TERM"] = "xterm-256color"
            env["COLUMNS"] = "80"
            env["LINES"] = "24"
            os.chdir(ROOT)
            os.execvpe("sh", ["sh", "-c", command], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    def write(self, data):
        os.write(self.fd, data)

    def read_until(self, token, timeout):
        buf = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            remaining = deadline - time.time()
            ready, _, _ = select.select([self.fd], [], [], min(0.2, remaining))
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if token in buf:
                break
        return buf

    def drain(self, seconds):
        buf = b""
        deadline = time.time() + seconds
        while time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
        return buf

    def termios_flags(self):
        attrs = termios.tcgetattr(self.fd)
        lflag = attrs[3]
        return {
            "icanon": bool(lflag & termios.ICANON),
            "echo": bool(lflag & termios.ECHO),
            "isig": bool(lflag & termios.ISIG),
        }

    def close(self):
        try:
            os.kill(self.pid, 15)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


def flag_on(text, name):
    if re.search(rf"(?<![\w])-{name}(?![\w])", text):
        return False
    if re.search(rf"(?<![\w]){name}(?![\w])", text):
        return True
    return None


def run_path(name):
    key = PATHS[name]
    command = "mix run examples/keys.exs; echo TERRA_SHELL_OK; stty -a; echo TERRA_STTY_DONE; sleep 30"
    session = Pty(command)
    failures = []
    output = b""
    try:
        output = session.read_until(b"Keys", 90)
        if b"Keys" not in output:
            return fail(name, ["app did not show the Keys frame"], output)
        if ENTER_ALT not in output or HIDE_CURSOR not in output:
            failures.append("app frame lacked alt-screen enter or cursor hide")

        session.write(key)
        output += session.read_until(b"TERRA_STTY_DONE", 30)
        output += session.drain(0.5)

        if b"TERRA_SHELL_OK" not in output:
            failures.append("shell did not print after the app exited")
        if LEAVE_ALT not in output:
            failures.append("alt screen: leave sequence missing")
        if SHOW_CURSOR not in output:
            failures.append("hidden cursor: show sequence missing")
        else:
            if output.rfind(SHOW_CURSOR) < output.rfind(HIDE_CURSOR):
                failures.append("hidden cursor: last cursor op is hide")

        if name == "crash":
            error_at = output.find(b"boom from view/1")
            leave_at = output.rfind(LEAVE_ALT)
            show_at = output.rfind(SHOW_CURSOR)
            shell_at = output.find(b"TERRA_SHELL_OK")
            if error_at < 0:
                failures.append("raise path did not print boom from view/1")
            elif leave_at < 0 or show_at < 0 or error_at < leave_at or error_at < show_at:
                failures.append("error was printed before restore")
            elif shell_at >= 0 and shell_at < error_at:
                failures.append("shell marker appeared before the error")

        try:
            flags = session.termios_flags()
        except termios.error as exc:
            flags = {}
            failures.append(f"raw: could not read termios ({exc})")
        else:
            for bit in ("icanon", "echo", "isig"):
                if not flags.get(bit):
                    failures.append(f"raw: {bit} is off ({flags})")

        stty = output.decode("utf-8", "replace")
        for bit in ("icanon", "echo", "isig"):
            seen = flag_on(stty, bit)
            if seen is False:
                failures.append(f"raw: stty reports -{bit}")
            elif seen is None:
                failures.append(f"raw: stty did not report {bit}")
    finally:
        session.close()

    if failures:
        return fail(name, failures, output)
    print(f"pass {name}")
    return 0


def fail(name, failures, output):
    print(f"fail {name}")
    for item in failures:
        print(f"  - {item}")
    tail = output.decode("utf-8", "replace")[-2000:]
    print("--- output tail ---")
    print(tail)
    return 1


def main(argv):
    if len(argv) != 1 or argv[0] not in list(PATHS) + ["all"]:
        print("usage: restore_matrix.py quit|interrupt|crash|all", file=sys.stderr)
        return 2
    names = list(PATHS) if argv[0] == "all" else [argv[0]]
    status = 0
    for name in names:
        status |= run_path(name)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

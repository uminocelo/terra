"""Minimal PTY driver for spiking Terra's terminal behaviour.

Spawns a command attached to a real pseudo-terminal so raw mode, alt screen,
cursor and restore paths can be observed without a human at a keyboard.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


class Pty:
    def __init__(self, argv, cols=80, rows=24, env=None):
        self.cols = cols
        self.rows = rows
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            environment = dict(os.environ)
            environment["TERM"] = "xterm-256color"
            if env:
                environment.update(env)
            os.execvpe(argv[0], argv, environment)
        self.set_winsize(cols, rows)

    def set_winsize(self, cols, rows):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def termios(self):
        attrs = termios.tcgetattr(self.fd)
        lflag = attrs[3]
        iflag = attrs[0]
        return {
            "icanon": bool(lflag & termios.ICANON),
            "echo": bool(lflag & termios.ECHO),
            "isig": bool(lflag & termios.ISIG),
            "ixon": bool(iflag & termios.IXON),
        }

    def write(self, data):
        if isinstance(data, str):
            data = data.encode()
        os.write(self.fd, data)

    def read(self, timeout=2.0, want=None, total_timeout=20.0):
        """Read output until `want` (bytes or predicate) shows up or time runs out."""
        buf = b""
        deadline = time.time() + total_timeout
        while time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], timeout)
            if not ready:
                if want is None:
                    break
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if want is not None and _matches(want, buf):
                break
        self.buf = buf
        return buf

    def wait_for(self, want, total_timeout=20.0):
        return self.read(timeout=0.2, want=want, total_timeout=total_timeout)

    def drain(self, seconds=0.4):
        end = time.time() + seconds
        buf = b""
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
        return buf

    def signal(self, sig):
        os.kill(self.pid, sig)

    def alive(self):
        try:
            done, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            return False, 0
        if done == 0:
            return True, None
        if os.WIFEXITED(status):
            return False, os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return False, -os.WTERMSIG(status)
        return False, status

    def close(self):
        os.close(self.fd)


def _matches(want, buf):
    if callable(want):
        return want(buf)
    return want in buf


def summarize(buf, limit=4000):
    return buf.decode("utf-8", "replace")[-limit:]


def escape_report(buf):
    """Which restore escape sequences are present in `buf`."""
    return {
        "alt_enter": b"\x1b[?1049h" in buf,
        "alt_leave": b"\x1b[?1049l" in buf,
        "cursor_hide": b"\x1b[?25l" in buf,
        "cursor_show": b"\x1b[?25h" in buf,
        "clear": b"\x1b[2J" in buf,
        "home": b"\x1b[H" in buf,
    }


if __name__ == "__main__":
    pty_session = Pty(sys.argv[1:])
    out = pty_session.drain(1.5)
    print(summarize(out))
    print(escape_report(out))
    pty_session.close()
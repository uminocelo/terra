"""End-to-end checks for Terra.Terminal against a real pseudo-terminal.

Complements `mix test` (which uses a capture backend): this runs the real
`Terra.Terminal` on a tty and inspects termios flags and emitted escapes from
the outside.

Usage: python3 spike/terminal_live.py
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pty_driver import Pty, escape_report, summarize  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "spike", "live_terminal.exs")
REPORT = []


def start(mode):
    return Pty(["mix", "run", SCRIPT, mode], cols=80, rows=24, env={"MIX_ENV": "dev"})


def note(name, ok, detail):
    REPORT.append((name, ok, detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}")


def wait_exit(p, seconds=6.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        alive, code = p.alive()
        if not alive:
            return code
        time.sleep(0.05)
    return "still-alive"


def check_quit():
    p = start("keys")
    out = p.wait_for(b"LIVE READY", total_timeout=25)
    during = p.termios()
    p.write(b"q")
    out += p.wait_for(b"LIVE RESTORED", total_timeout=8)
    code = wait_exit(p)
    out += p.drain(0.4)
    escapes = escape_report(out)

    note("Terra disables ISIG so Ctrl+C is readable", during["isig"] is False, f"termios={during}")
    note("raw mode active while held", during["icanon"] is False and during["echo"] is False, f"termios={during}")
    note("alt screen + hidden cursor on enter",
         escapes["alt_enter"] and escapes["cursor_hide"], f"{escapes}")
    note("alt screen + cursor restored on quit",
         escapes["alt_leave"] and escapes["cursor_show"], f"{escapes}")
    note("termios restored on quit", p.termios()["icanon"] and p.termios()["echo"] and p.termios()["isig"],
         f"termios={p.termios()}")
    note("clean exit status", code == 0, f"exit={code}")
    p.close()


def check_interrupt():
    p = start("keys")
    out = p.wait_for(b"LIVE READY", total_timeout=25)
    during = p.termios()
    p.write(b"\x03")
    out += p.wait_for(b"LIVE EVENT :interrupt", total_timeout=8)
    out += p.wait_for(b"LIVE RESTORED", total_timeout=8)
    code = wait_exit(p)
    out += p.drain(0.4)
    escapes = escape_report(out)

    note("Ctrl+C reaches the app as a byte", b"LIVE EVENT :interrupt" in out, f"isig_during={during['isig']}")
    note("Ctrl+C path restores and exits",
         code == 0 and escapes["alt_leave"] and p.termios()["icanon"] and p.termios()["isig"],
         f"exit={code} termios={p.termios()} {escapes}")
    p.close()


def check_crash():
    p = start("crash")
    out = p.wait_for(b"LIVE READY", total_timeout=25)
    out += p.wait_for(b"boom from view/1", total_timeout=12)
    code = wait_exit(p)
    out += p.drain(0.4)
    escapes = escape_report(out)

    note("a raised callback restores before the error surfaces",
         escapes["alt_leave"] and escapes["cursor_show"] and b"boom from view/1" in out,
         f"{escapes} exit={code}")
    note("terminal usable after the raise",
         p.termios()["icanon"] and p.termios()["echo"] and p.termios()["isig"],
         f"termios={p.termios()}")
    note("non-zero exit status after the raise", code not in (0, "still-alive"), f"exit={code}")
    p.close()


def check_loop_death():
    p = start("loop_death")
    out = p.wait_for(b"LIVE READY", total_timeout=25)
    out += p.wait_for(b"LIVE AFTER_KILL", total_timeout=8)
    code = wait_exit(p)
    out += p.drain(0.4)
    escapes = escape_report(out)

    note("killing the run loop restores the terminal",
         escapes["alt_leave"] and escapes["cursor_show"], f"{escapes}")
    note("owner released after the loop died",
         b"LIVE AFTER_KILL nil" in out, summarize(out, 200).replace("\n", " ")[-120:])
    note("terminal usable after the loop died",
         p.termios()["icanon"] and p.termios()["echo"] and p.termios()["isig"],
         f"termios={p.termios()} exit={code}")
    p.close()


CHECKS = [
    ("quit", check_quit),
    ("Ctrl+C", check_interrupt),
    ("raised callback", check_crash),
    ("run loop death", check_loop_death),
]


def main():
    only = sys.argv[1:] or None

    for name, fn in CHECKS:
        if only and not any(token in name for token in only):
            continue
        print(f"\n=== {name} ===")
        try:
            fn()
        except Exception as error:  # noqa: BLE001
            note(name, False, f"harness error: {error!r}")

    passed = sum(1 for _, ok, _ in REPORT if ok)
    print(f"\n{passed}/{len(REPORT)} live checks passed")


if __name__ == "__main__":
    main()

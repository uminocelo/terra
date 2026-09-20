"""Spike checks for Terra's terminal layer (Issue 1.1.1).

Runs spike/spike.exs against a real pseudo-terminal and reports objective
evidence: termios flags, restore escape sequences, exit status, raw output.

Usage: python3 spike/run_checks.py
"""

import os
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pty_driver import Pty, escape_report, summarize  # noqa: E402

SPIKE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "spike.exs")
REPORT = []
FINDINGS = []


def start(mode, cols=80, rows=24):
    return Pty(["elixir", SPIKE, mode], cols=cols, rows=rows)


def note(name, ok, detail):
    REPORT.append((name, ok, detail))
    flag = "PASS" if ok else "FAIL"
    print(f"[{flag}] {name}: {detail}")


def info(name, detail):
    FINDINGS.append((name, detail))
    print(f"[INFO] {name}: {detail}")


def events(out):
    return re.findall(rb"SPIKE EVENT (.+)", out)


def field(out, label):
    match = re.search(rb"SPIKE " + label.encode() + rb" (.+)", out)
    return match.group(1).decode(errors="replace") if match else None


def wait_exit(p, seconds=4.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        alive, code = p.alive()
        if not alive:
            return code
        time.sleep(0.05)
    return "still-alive"


def check_keys():
    p = start("keys")
    out = p.wait_for(b"SPIKE READY")
    ready = b"SPIKE READY" in out
    note("1.1.1.1 raw mode reaches the tty", ready and p.termios()["icanon"] is False,
         f"termios={p.termios()} raw={field(out, 'RAW')} size={field(out, 'SIZE')} "
         f"encoding={field(out, 'ENCODING')}")

    # A CSI split across two reads must become one :up event.
    p.write(b"\x1b[")
    time.sleep(0.06)
    p.write(b"A")
    p.write(b"\x1b[B\x1b[C\x1b[D")
    p.write(b"\r\t\x7f")
    # A UTF-8 character split across two reads must become one :char event.
    p.write(b"\xc3")
    time.sleep(0.06)
    p.write(b"\xa9")
    # A lone ESC must resolve to :escape after the flush timeout.
    p.write(b"\x1b")
    time.sleep(0.15)
    # A truncated sequence must flush after the longer hold.
    p.write(b"\x1b[")
    out += p.wait_for(b"SPIKE EVENT {:unknown", total_timeout=6)
    p.write(b"q")
    out += p.wait_for(b"SPIKE DONE", total_timeout=6)
    code = wait_exit(p)
    out += p.drain(0.4)

    seen = events(out)
    note("1.1.1.3 split CSI becomes one :up", seen.count(b":up") == 1, f"events={seen}")
    note("1.1.1.3 arrows/enter/tab/backspace decode",
         all(e in seen for e in [b":up", b":down", b":right", b":left", b":enter", b":tab", b":backspace"]),
         f"events={seen}")
    note("1.1.1.3 split UTF-8 becomes one :char",
         sum(1 for e in seen if b"\xc3\xa9" in e) == 1,
         f"char events={[e for e in seen if b'char' in e]}")
    note("1.1.1.3 lone ESC flushes to :escape", b":escape" in seen, f"events={seen}")
    note("1.1.1.3 truncated sequence flushes as :unknown",
         any(b"unknown" in e and b"\\e[" in e for e in seen), f"events={seen}")
    note("1.1.1.3 q quits", b":quit" in seen, f"events={seen}")

    escapes = escape_report(out)
    note("1.1.1.2 restore leaves alt screen", escapes["alt_leave"] and escapes["alt_enter"], f"{escapes}")
    note("1.1.1.2 restore shows the cursor", escapes["cursor_show"] and escapes["cursor_hide"], f"{escapes}")
    note("1.1.1.2 cooked mode restored", p.termios()["icanon"] and p.termios()["echo"], f"termios={p.termios()}")
    note("1.1.1.2 explicit exit status 0", code == 0, f"exit={code}")
    info("quit path runs System.at_exit",
         f"at_exit_output={b'AT_EXIT_RESTORE' in out} (System.halt skips at_exit; restore is explicit here)")
    p.close()


def check_crash():
    p = start("crash")
    out = p.wait_for(b"SPIKE READY", total_timeout=8)
    out += p.wait_for(b"boom from view/1", total_timeout=8)
    code = wait_exit(p, 6)
    out += p.drain(0.4)
    escapes = escape_report(out)
    note("1.1.1.2 restore after raise", escapes["alt_leave"] and escapes["cursor_show"], f"{escapes}")
    note("1.1.1.2 cooked mode after raise", p.termios()["icanon"] and p.termios()["echo"], f"termios={p.termios()}")
    note("1.1.1.2 error is not swallowed", code not in (0, "still-alive") and b"boom from view/1" in out,
         f"exit={code}")
    note("1.1.1.2 restore happens before the error surfaces",
         out.find(b"RESTORED_BEFORE_RERAISE") != -1
         and out.find(b"RESTORED_BEFORE_RERAISE") < out.find(b"boom from view/1"),
         "RESTORED_BEFORE_RERAISE precedes the raise message")
    p.close()


def check_ctrl_c_with_isig():
    p = start("keys")
    out = p.wait_for(b"SPIKE READY")
    before = p.termios()
    p.write(b"\x03")
    time.sleep(0.8)
    out += p.drain(0.6)
    code = wait_exit(p, 4)
    escapes = escape_report(out)
    info("Ctrl+C while ISIG is left on (as start_interactive leaves it)",
         f"isig={before['isig']} exit={code} alt_leave={escapes['alt_leave']} events={events(out)} "
         f"(the tty swallows the byte; the VM ignores the resulting SIGINT)")
    note("1.1.1.2 Ctrl+C alone is not enough without disabling ISIG",
         code != 0 or escapes["alt_leave"],
         f"exit={code} alt_leave={escapes['alt_leave']} termios={p.termios()}")
    p.close()


def check_ctrl_c_isig_off():
    p = start("keys_isig_off")
    out = p.wait_for(b"SPIKE READY", total_timeout=8)
    isig_during = p.termios()["isig"]
    p.write(b"\x03")
    out += p.wait_for(b"SPIKE DONE", total_timeout=6)
    code = wait_exit(p, 4)
    out += p.drain(0.4)
    escapes = escape_report(out)
    note("1.1.1.2 Ctrl+C byte handled when ISIG is off",
         b":interrupt" in events(out) and code == 0 and escapes["alt_leave"] and p.termios()["isig"],
         f"isig_during={isig_during} isig_result={field(out, 'ISIG')} events={events(out)} "
         f"exit={code} alt_leave={escapes['alt_leave']} isig_restored={p.termios()['isig']}")
    p.close()


def check_sigint():
    p = start("sigint")
    out = p.wait_for(b"SPIKE READY", total_timeout=8)
    p.signal(2)
    time.sleep(1.0)
    out += p.drain(0.6)
    code = wait_exit(p, 4)
    escapes = escape_report(out)
    info("external SIGINT",
         f"exit={code} alt_leave={escapes['alt_leave']} termios={p.termios()} "
         f"(:os.set_signal rejects :sigint; the VM neither dies nor restores)")
    p.close()


def check_sigterm():
    p = start("sigterm")
    out = p.wait_for(b"SPIKE READY", total_timeout=8)
    settable = field(out, "SET_SIGNAL")
    p.signal(15)
    time.sleep(1.2)
    out += p.drain(0.6)
    code = wait_exit(p, 4)
    escapes = escape_report(out)
    note("1.1.1.2 SIGTERM leaves the terminal usable",
         code == 0 and p.termios()["icanon"] and p.termios()["echo"] and p.termios()["isig"],
         f"set_signal={settable} exit={code} termios={p.termios()}")
    info("SIGTERM escape sequences",
         f"alt_leave={escapes['alt_leave']} (no Elixir hook runs; the Erlang tty driver "
         f"restores termios, but the alt screen is left until an explicit restore)")
    p.close()


def check_bench():
    p = start("bench")
    out = p.wait_for(b"SPIKE READY", total_timeout=8)

    stop = threading.Event()
    collected = []
    lock = threading.Lock()

    def drain():
        while not stop.is_set():
            chunk = p.drain(0.2)
            if chunk:
                with lock:
                    collected.append(chunk)

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    out += p.wait_for(b"SPIKE BENCH_FRAMES", total_timeout=30)
    stop.set()
    reader.join(timeout=2)
    with lock:
        out += b"".join(collected)
    out += p.read(timeout=0.3, total_timeout=5)
    code = wait_exit(p, 6)
    avg = field(out, "BENCH_AVG_MS")
    gen = field(out, "BENCH_GEN_AVG_MS")
    note("1.1.1.4 frame time recorded", avg is not None, f"avg={avg}ms gen={gen}ms p50={field(out, 'BENCH_P50_MS')}ms "
         f"p95={field(out, 'BENCH_P95_MS')}ms max={field(out, 'BENCH_MAX_MS')}ms "
         f"total={field(out, 'BENCH_TOTAL_MS')}ms exit={code}")
    note("1.1.1.4 measured under 5 ms for 80x24", avg is not None and float(avg) < 5.0, f"avg={avg}ms")
    p.close()


CHECKS = [
    ("1.1.1.1 + 1.1.1.3 keys and restore", check_keys),
    ("1.1.1.2 raise", check_crash),
    ("1.1.1.2 Ctrl+C (ISIG on)", check_ctrl_c_with_isig),
    ("1.1.1.2 Ctrl+C (ISIG off)", check_ctrl_c_isig_off),
    ("1.1.1.2 SIGINT", check_sigint),
    ("1.1.1.2 SIGTERM", check_sigterm),
    ("1.1.1.4 bench", check_bench),
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
    print(f"\n{passed}/{len(REPORT)} checks passed, {len(FINDINGS)} findings")
    print("\nFindings (raw evidence, not pass/fail):")
    for name, detail in FINDINGS:
        print(f"  - {name}: {detail}")


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""Run the keys.exs restore paths on hosts this machine can actually drive.

  python3 scripts/restore_hosts.py
  python3 scripts/restore_hosts.py tmux "Terminal.app"

tmux is driven with send-keys on a tmux pty. Terminal.app and iTerm are asked
to run scripts/restore_tty_session.py in their own window, so the app inherits
that emulator's tty. SSH uses ssh -tt localhost. Missing hosts are not-run.
"""

import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATHS = ("quit", "interrupt", "crash")
# Split so the typed command does not contain the marker the shell prints.
SHELL_LINE = (
    "mix run examples/keys.exs; "
    "printf '%s%s\\n' TERRA_SHELL_ OK; "
    "stty -a; "
    "printf '\\033[?25$p'; sleep 0.3; echo; "
    "printf '%s%s\\n' TERRA_ DONE"
)


def flag_on(text, name):
    if re.search(rf"(?<![\w])-{name}(?![\w])", text):
        return False
    if re.search(rf"(?<![\w]){name}(?![\w])", text):
        return True
    return None


def judge(name, blob, saw_app):
    text = blob.decode("utf-8", "replace") if isinstance(blob, bytes) else blob
    raw = blob if isinstance(blob, bytes) else blob.encode("utf-8", "replace")
    notes = []
    failures = []
    if not saw_app and "Keys" not in text:
        failures.append("app frame not observed")
    if "TERRA_SHELL_OK" not in text:
        failures.append("shell did not return")
    if "TERRA_DONE" not in text:
        failures.append("host session did not finish")
    for bit in ("icanon", "echo", "isig"):
        seen = flag_on(text, bit)
        if seen is False:
            failures.append(f"raw: stty reports -{bit}")
        elif seen is None:
            failures.append(f"raw: stty did not report {bit}")
    if b"?25;2" in raw:
        failures.append("hidden cursor")
    elif b"?25;1" in raw:
        notes.append("cursor visible")
    else:
        notes.append("cursor not observed")
    if name == "crash":
        error_at = text.find("boom from view/1")
        shell_at = text.find("TERRA_SHELL_OK")
        if error_at < 0:
            failures.append("error text missing")
        elif shell_at >= 0 and error_at > shell_at:
            failures.append("error printed after the shell marker")
        else:
            notes.append("error printed before the shell marker")
    status = "fail" if failures else "pass"
    return status, "; ".join(failures + notes)


def tmux_capture(session):
    proc = subprocess.run(
        ["tmux", "capture-pane", "-p", "-e", "-S", "-300", "-t", session],
        check=False,
        capture_output=True,
    )
    return proc.stdout


def run_tmux(name):
    if not shutil.which("tmux"):
        return "not-run", "tmux is not installed"
    session = f"terra-restore-{name}-{os.getpid()}"
    subprocess.run(["tmux", "kill-session", "-t", session], capture_output=True)
    created = subprocess.run(
        ["tmux", "new-session", "-d", "-s", session, "-x", "100", "-y", "30"],
        capture_output=True,
        text=True,
    )
    if created.returncode != 0:
        return "not-run", (created.stderr or "tmux new-session failed").strip()
    try:
        command = f"cd {ROOT} && {SHELL_LINE}"
        subprocess.run(["tmux", "send-keys", "-t", session, command, "Enter"], check=True)
        saw_app = False
        deadline = time.time() + 60
        while time.time() < deadline:
            if b"Keys" in tmux_capture(session):
                saw_app = True
                break
            time.sleep(0.2)
        if not saw_app:
            tail = tmux_capture(session).decode("utf-8", "replace")[-300:]
            return "fail", "app frame not observed; " + tail
        time.sleep(0.3)
        if name == "interrupt":
            subprocess.run(["tmux", "send-keys", "-t", session, "C-c"], check=True)
        else:
            key = {"quit": "q", "crash": "!"}[name]
            subprocess.run(["tmux", "send-keys", "-t", session, "-l", key], check=True)
        deadline = time.time() + 25
        blob = b""
        while time.time() < deadline:
            blob = tmux_capture(session)
            if b"TERRA_DONE" in blob:
                break
            time.sleep(0.2)
        time.sleep(0.3)
        return judge(name, tmux_capture(session), saw_app)
    finally:
        subprocess.run(["tmux", "kill-session", "-t", session], capture_output=True)


def run_ssh(_name):
    if not shutil.which("ssh"):
        return "not-run", "ssh is not installed"
    probe = subprocess.run(
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=4",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "localhost",
            "echo",
            "terra-ssh-ok",
        ],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0 or "terra-ssh-ok" not in probe.stdout:
        reason = (probe.stderr or probe.stdout or "ssh localhost failed").strip().splitlines()
        return "not-run", reason[-1] if reason else "ssh localhost failed"
    return "not-run", "ssh answered, but this runner does not claim a pass without a fresh tty log"


def launch_tty_app(app, dest_dir):
    """Open app on a .command that runs the three paths. Return combined text or None."""
    os.makedirs(dest_dir, exist_ok=True)
    for path in PATHS:
        try:
            os.remove(os.path.join(dest_dir, path + ".txt"))
        except OSError:
            pass
    done = os.path.join(dest_dir, "done.txt")
    try:
        os.remove(done)
    except OSError:
        pass
    command = os.path.join(dest_dir, "run.command")
    lines = ["#!/bin/bash", f"cd {ROOT}"]
    for path in PATHS:
        dest = os.path.join(dest_dir, path + ".txt")
        lines.append(f"/usr/bin/python3 scripts/restore_tty_session.py {path} {dest}")
    lines.append(f"echo done > {done}")
    lines.append("exit")
    with open(command, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    os.chmod(command, 0o755)
    opened = subprocess.run(["open", "-a", app, command], capture_output=True, text=True)
    if opened.returncode != 0:
        return None, (opened.stderr or f"open -a {app} failed").strip()
    deadline = time.time() + 50
    while time.time() < deadline:
        if os.path.exists(done):
            chunks = []
            for path in PATHS:
                try:
                    chunks.append(path + "\n" + open(os.path.join(dest_dir, path + ".txt")).read())
                except OSError as exc:
                    chunks.append(path + f"\nmissing ({exc})")
            return "\n".join(chunks), None
        time.sleep(0.5)
    return None, f"{app} did not finish the session"


def parse_tty_result(name, blob):
    section = blob.split(f"\n{name}\n", 1)[-1] if blob.startswith("quit") else blob
    # blob is "quit\n...\ninterrupt\n..."
    parts = {}
    current = None
    buf = []
    for line in blob.splitlines():
        if line in PATHS and (current is None or line != current):
            if current:
                parts[current] = "\n".join(buf)
            current = line
            buf = []
            continue
        buf.append(line)
    if current:
        parts[current] = "\n".join(buf)
    text = parts.get(name, "")
    status = "fail"
    detail = "no result"
    for line in text.splitlines():
        if line.startswith("status="):
            status = line.split("=", 1)[1].strip()
        elif line.startswith("detail="):
            detail = line.split("=", 1)[1].strip()
    return status, detail


def run_terminal(_name):
    if not os.path.exists("/System/Applications/Utilities/Terminal.app") and not os.path.isdir(
        "/Applications/Terminal.app"
    ):
        return "not-run", "Terminal.app is not installed"
    blob, err = launch_tty_app("Terminal", "/tmp/terra-restore-terminal")
    if blob is None:
        return "not-run", err
    return parse_tty_result(_name, blob)


def run_iterm(_name):
    if not os.path.isdir("/Applications/iTerm.app"):
        return "not-run", "iTerm is not installed"
    blob, err = launch_tty_app("iTerm", "/tmp/terra-restore-iterm")
    if blob is None:
        return "not-run", err
    return parse_tty_result(_name, blob)


HOSTS = [
    ("tmux", run_tmux),
    ("SSH", run_ssh),
    ("Terminal.app", run_terminal),
    ("iTerm2", run_iterm),
]

NOT_INSTALLED = [
    ("Ghostty", "not installed"),
    ("Kitty", "not installed"),
    ("Alacritty", "not installed"),
    ("GNOME Terminal", "not installed"),
    ("Windows Terminal", "not installed"),
]


def main():
    only = sys.argv[1:]
    rows = []
    for label, reason in NOT_INSTALLED:
        if only and label not in only:
            continue
        rows.append((label, {path: ("not-run", reason) for path in PATHS}))
    for label, fn in HOSTS:
        if only and label not in only and label.lower() not in [item.lower() for item in only]:
            continue
        results = {}
        # Terminal and iTerm launch all three paths in one window.
        if label in {"Terminal.app", "iTerm2"}:
            print(f"# {label}", file=sys.stderr, flush=True)
            status, detail = fn("quit")
            if status == "not-run":
                for path in PATHS:
                    results[path] = (status, detail)
            else:
                blob = open(
                    "/tmp/terra-restore-terminal/done.txt"
                    if label == "Terminal.app"
                    else "/tmp/terra-restore-iterm/done.txt"
                ).read()
                # Re-read the per-path files. fn already checked quit; read each file.
                directory = (
                    "/tmp/terra-restore-terminal"
                    if label == "Terminal.app"
                    else "/tmp/terra-restore-iterm"
                )
                for path in PATHS:
                    text = open(os.path.join(directory, path + ".txt"), errors="replace").read()
                    results[path] = parse_tty_result(path, path + "\n" + text)
            for path in PATHS:
                print(f"# {label} {path}: {results[path][0]} {results[path][1]}", file=sys.stderr)
            rows.append((label, results))
            continue
        for path in PATHS:
            print(f"# {label} {path}", file=sys.stderr, flush=True)
            try:
                results[path] = fn(path)
            except Exception as exc:
                results[path] = ("fail", f"driver error: {exc}")
            print(f"# {label} {path}: {results[path][0]} {results[path][1]}", file=sys.stderr)
        rows.append((label, results))

    print("| Host | quit | Ctrl+C | raise in view/1 |")
    print("| --- | --- | --- | --- |")
    for label, results in rows:
        cells = [f"{results[path][0]}: {results[path][1]}" for path in PATHS]
        print("| " + label + " | " + " | ".join(cells) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main())

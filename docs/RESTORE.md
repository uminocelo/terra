# Restore matrix

Recorded on this machine on 2026-10-02. A host is **not-run** when it is not installed or this session could not drive it. Nothing here is marked pass unless that host's own tty ran `examples/keys.exs`.

## Commands

One command per path. Each one runs `mix run examples/keys.exs` on a PTY, sends one key, and checks restore. The raise path must print `boom from view/1` after the leave-alt-screen and show-cursor sequences.

```bash
scripts/restore_matrix.sh quit        # q
scripts/restore_matrix.sh interrupt   # Ctrl+C
scripts/restore_matrix.sh crash       # !  raises in view/1
```

PTY result this session: **pass** for quit, Ctrl+C, and raise. After the raise, `boom from view/1` was after the restore sequences, then the shell printed.

Inside a real emulator, the same three keys are `q`, Ctrl+C, and `!`. `scripts/restore_tty_session.py` drives them on whatever tty it is started in. It does not allocate a PTY of its own.

## Hosts

| Host | quit | Ctrl+C | raise in view/1 |
| --- | --- | --- | --- |
| Ghostty | not-run: not installed | not-run: not installed | not-run: not installed |
| iTerm2 | not-run: AppleEvent timed out, and `open -a iTerm` did not run the session | not-run | not-run |
| Terminal.app | pass: raw mode restored (`icanon`, `echo`, `isig` back on). Cursor and alt-screen queries got no reply | pass: same raw-mode restore | pass: same raw-mode restore, stderr showed `boom from view/1` |
| Kitty | not-run: not installed | not-run: not installed | not-run: not installed |
| Alacritty | not-run: not installed | not-run: not installed | not-run: not installed |
| GNOME Terminal | not-run: not installed | not-run: not installed | not-run: not installed |
| Windows Terminal | not-run: not installed | not-run: not installed | not-run: not installed |
| tmux | pass: app frame seen, shell returned, `stty` cooked, cursor visible | pass: same | pass: error printed before the shell marker, cursor visible |
| SSH | not-run: `ssh localhost` connection refused on port 22 | not-run | not-run |

tmux saw the Keys frame and then the shell on the main screen, so the alternate screen had been left. Terminal.app's tty flags show raw mode was taken and given back. Terminal.app did not answer the cursor or alternate-screen queries, so those two are not claimed there.

The clip in `docs/restore.gif` is the tmux session: the app is up, Ctrl+C returns the prompt, and `echo restored` prints. This environment could not take a display screenshot.

Re-run the hosts that this script can drive:

```bash
python3 scripts/restore_hosts.py
```

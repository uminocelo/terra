# Spike 1.1.1 go/no-go note

Scope: one throwaway spike (`spike/spike.exs` + `spike/spike_lib.exs`) driven through a real
pseudo-terminal by `spike/run_checks.py`. Machine: Elixir 1.20.4 on Erlang/OTP 29, macOS,
80x24 PTY. Raw output of the last run: `spike/evidence.txt` (20/20 automated checks passed).

## What the spike proved

1. **Raw input works with no NIF and no dependency.** `:shell.start_interactive({:noshell, :raw})`
   returns `:ok` on a tty, clears `ICANON` and `ECHO`, and delivers keypresses one byte at a time
   (`IO.binread(:stdio, 1)` returns as soon as a key is pressed, no line buffering).
2. **The terminal always comes back on our own exit paths.** `:quit`, the Ctrl+C interrupt
   (`\\x03`), and a raised callback each emit `ESC[?25h` + `ESC[?1049l` + reset, then
   `start_interactive({:noshell, :cooked})`. Verified from the outside: termios shows
   `icanon`/`echo`/`isig` back on, the alt screen is left, and the exit status is 0 or 1.
3. **A raised callback restores before the error surfaces** (`RESTORED_BEFORE_RERAISE` precedes
   `boom from view/1`), so the original error is not swallowed and the terminal is usable.
4. **Parsing is viable**: arrows, Enter, Tab, Backspace, a lone ESC (flushed after 50 ms), a CSI
   split across two reads (`ESC[` then `A` becomes exactly one `:up`), and UTF-8 split across two
   reads (`0xC3` then `0xA9` becomes one `{:char, "é"}`). A truncated sequence flushes as
   `{:unknown, "\\e["}` after a 250 ms hold.
5. **80x24 full redraw is cheap**: 120 timed frames of a styled box, average 0.13 ms
   (generation alone 0.05 ms, p95 0.19 ms, max 0.22 ms), i.e. roughly 40x under the 5 ms target.

## What the spike also exposed (design constraints for 1.2.2)

- `{noshell, :raw}` is **not** full raw: `ISIG` stays on, so the tty swallows Ctrl+C and the
  emulator never sees the byte. The spike disables it with `stty -isig`, run through a port opened
  with `:nouse_stdio` so the child inherits the tty on fd 0 (`/dev/tty` is not available to port
  children here: "Device not configured"). `stty isig` puts it back on restore.
- The tty defaults to `encoding: :unicode`, which folds `0xC3 0xA9` into a single byte `233`.
  Bytes must be read with `:io.setopts(:standard_io, encoding: :latin1)`.
- Size: `:io.columns(:stdio)` returns `{:error, :enotsup}` even on a tty;
  `:io.columns(:standard_error)` / `:io.rows(:standard_error)` return the real 80x24. Fallback:
  `COLUMNS`/`LINES`, then 80x24.
- `:os.set_signal/2` has no `:sigint` (only sighup, sigterm, sigwinch, ...). SIGINT cannot be
  trapped, which is exactly why Ctrl+C has to be handled as a byte instead.
- On SIGTERM the Erlang tty driver puts termios back, but no Elixir code runs, so the alt screen
  can be left behind. `System.at_exit/1` is not reliable here (own docs: not guaranteed on
  `System.stop/1`, `System.halt/1`, or exit signals). Open item, not required by 1.2.2.
- The VM does **not** exit on its own after `start_interactive`; the runtime must halt explicitly
  once restore has been written (a short flush delay is enough).

## What is still unknown

- **Visual verification on a real terminal (needs a human).** The PTY proves escape sequences and
  termios flags, not what iTerm/Terminal.app actually show: alt screen left, cursor visible, prompt
  usable, no leftover drawing.
- **True frame cost on a real emulator.** The measured 0.13 ms is the app-side write to a kernel
  buffer; terminal emulation cost (iTerm, tmux, SSH) is outside this spike. Smoothness at 80x24
  should still be confirmed by eye.
- **IEx / `mix run` parity.** The spike ran as a script. Whether raw mode behaves the same inside
  IEx (the known limitation tracked by 4.3.4.3) was not tested.

## Library check (run while implementing 1.2.2)

`spike/terminal_live.py` repeats the same probes against the real `Terra.Terminal`
(`mix run spike/live_terminal.exs`) instead of the throwaway code: 14/14 checks pass. Raw output:
`spike/terminal_live_evidence.txt`. Covered: quit, Ctrl+C as a byte, a raised callback, and a run
loop killed with `:kill`, each restoring the alt screen, the cursor, termios (`icanon`/`echo`/
`isig`), and exiting cleanly.

## Verdict

Keep Terra, rather than contributing a terminal layer to TermUI/Tuix. The spike shows the hard
parts (raw mode without a NIF, restore on every exit path we control, split-sequence parsing, frame
budget) are all reachable in a few hundred lines with zero runtime dependencies, which is the whole
premise of the plan. The second option, contributing upstream, would inherit a widget framework
Terra explicitly does not want.

**Status: pending the human interactive run below.** 1.1.1.5 blocks 1.2.1 by the plan, so the
verdict line above is a recommendation until confirmed.

## Reproduce

```bash
python3 spike/run_checks.py                  # 20 automated checks, ~40 s
python3 spike/run_checks.py "bench"          # frame timing only

elixir spike/spike.exs keys                  # interactive: arrows, tab, backspace, q to quit
elixir spike/spike.exs keys_isig_off         # interactive: Ctrl+C restores and exits
elixir spike/spike.exs crash                 # interactive: raise still restores, then the error
```

Interactive checklist: after `q`, after Ctrl+C, and after the `crash` error, the shell is back on
the main screen with the cursor visible and normal line editing.

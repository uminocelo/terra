# Changelog

## 1.1.0

### Added

- `{:read_file, path, msg}` and `{:port, cmd, msg}` commands. `init/1` and
  `update/2` return them as data; the runtime runs the work off the view path
  and delivers `{msg, {:ok, data} | {:error, reason}}` back to `update/2`.
  `view/1` stays pure. See `Terra.Command` and `guides/effects.md`.
- `examples/keys.exs`, a key debugger showing the last 20 parsed input events.
- `examples/test_watcher.exs`, a mix test watcher: runs `mix test --no-color`
  as a port command, parses failures into file, line, name and assertion, and
  renders them in a selectable list with an assertion pane and progress while
  the suite runs.
- Input parser fixtures covering split CSI sequences, split UTF-8 graphemes,
  Ctrl+C and unknown escape sequences.

Still zero runtime dependencies.

## 1.0.0

First stable release: the runtime (`init` / `update` / `view`), the restore
contract, input events with buffered partial sequences, cell-grid diffing,
`vstack` / `hstack` / `box` / `text`, list, progress, spinner and text input
widgets, focus, themes, `{:tick, ms, msg}` commands, `{:resize, w, h}` events,
`Terra.Test`, and the counter, tick, menu, todo and pomodoro examples.

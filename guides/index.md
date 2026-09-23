# Terra guides

Two pages take you from install to a running app, then through the event
model, commands, layout, widgets and headless tests.

- [[getting_started|Getting Started]] is the one-page walkthrough: install, a
  working app, events, commands, rendering, headless tests and the restore
  contract.
- [[tutorial|Tutorial]] is the deep dive: a counter, tick-driven work, a
  keyboard menu, layout, styling and testing without a terminal.
- [[effects|Effects as data]] is the effects page: `view/1` stays pure,
  `{:read_file, path, msg}` and `{:port, cmd, msg}` run off the view path, and
  the mix test watcher shows the whole pattern.

## Where to start

Run the counter first, then read the page that matches how much you want to
know:

```bash
mix run examples/counter.exs
```

If that works, read [[getting_started|Getting Started]]. If you want to
understand every part of the loop before writing your own app, read
[[tutorial|Tutorial]].

## In this repo

- `examples/` - counter, tick spinner, menu, todo, pomodoro, key debugger and
  mix test watcher apps
- `lib/` - the runtime, view primitives, widgets, focus and themes
- `test/` - headless tests driven with `Terra.Test`

Terra ships no runtime dependencies, so these guides are the whole manual.
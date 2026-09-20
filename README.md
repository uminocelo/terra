# Terra

A zero-dependency TUI library for Elixir built around an Elm-style `init` / `update` / `view` loop that always gives your terminal back.

**Status:** version `0.1.0-dev`, work in progress, not on Hex yet. The terminal layer, input parser, renderer, run loop, headless test helpers, differential painting, widgets, focus and themes are all in place.

## Requirements

- Elixir 1.18 or newer
- OTP 28 or newer

Terra ships no runtime dependencies: no NIFs, no port drivers, no widget framework.

## Installation

```elixir
def deps do
  [
    {:terra, "~> 0.1"}
  ]
end
```

## The Counter app

```elixir
defmodule Counter do
  use Terra

  def init(_opts), do: 0

  def update({:char, "j"}, count), do: count + 1
  def update({:char, "k"}, count), do: count - 1
  def update({:char, "q"}, count), do: {:quit, count}
  def update(_event, count), do: count

  def view(count) do
    box([text("Count: #{count}"), text("j/k to change, q to quit")])
  end
end

Terra.run(Counter)
```

Run it with `mix run examples/counter.exs`, or see `examples/todo.exs` and
`examples/pomodoro.exs` for the v0.2 widgets. `guides/getting_started.md` is the
one-page walkthrough and `guides/tutorial.md` goes deeper.

Keys arrive as small runtime events such as `{:char, "j"}`, `:up`, or `:interrupt`, not as raw bytes. Map them to your own messages with `event_to_msg/2`, or let them pass through.

## How apps run

Each frame is rendered into a cell grid and diffed against the previous one, so
only changed cells are written. `update/2` can return `{state, [{:tick, ms, msg}]}`
to schedule work, and the runtime feeds resize events back as `{:resize, w, h}`.

`Terra.Widget` provides stateless list, progress, spinner and text input views
whose state stays in your app, `Terra.Focus` handles Tab order, and `Terra.Theme`
supplies `fg` / `bg` / `accent` / `border` colors that views read at render time.

## Running inside IEx

**Not supported.** Run apps as a script with `mix run path/to/app.exs` (or
`elixir path/to/app.exs`).

Under `iex -S mix`, stdin belongs to the IEx shell process rather than the app.
Terra's raw-mode and alternate-screen setup, and the restore contract, assume it
owns the terminal, so rendering and restore are not guaranteed there. A TTY
fallback for IEx may come later.

Headless testing needs no terminal at all:

```elixir
machine = Terra.Test.start(Counter)
machine |> Terra.Test.send_keys("jj") |> Terra.Test.render()
#=> "┌────────────────────────\n│Count: 2                │\n│j/k to change, q to quit│\n└────────────────────────┘"
```

## Restore contract

Terra owns the terminal only while your app runs, and it puts the terminal back on **every** exit path:

- `:quit` returned from `update/2`
- `Ctrl+C` / `:interrupt`
- a crash in `init/1`, `update/2`, or `view/1`
- the process that started `Terra.run/1` dying, or the runtime being killed

After each path the terminal is in cooked mode, the cursor is visible, and you are back on the main screen. If a callback raises, Terra restores first and then lets the error surface; it is never swallowed.

## How it fits next to TermUI and Tuix

Terra is deliberately small. TermUI and Tuix are full widget frameworks with mature
component sets; if you need tables, forms, charts and mouse support today, use them.

Terra is for the case where you want a handful of screens, an Elm-shaped loop, no
runtime dependencies, and a restore contract you can rely on. Widgets are functions
of your parent state rather than nested components, and the whole surface is
`init` / `update` / `view` plus a few helpers.

## Non-goals

- No NIFs and no runtime dependencies
- No widget kitchen sink
- No mouse, flexbox engine, SSH, or nested-component runtime

## License

MIT
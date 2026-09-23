# Getting Started

Terra is a zero-dependency TUI library for Elixir built around an
Elm-style `init` / `update` / `view` loop. This page is one page: install, a
working app, the event and command model, and headless tests.

## Install

```elixir
def deps do
  [
    {:terra, "~> 1.0"}
  ]
end
```

No runtime dependencies, no NIFs.

## A working app

```elixir
defmodule Counter do
  use Terra

  def init(_opts), do: 0

  def update({:char, "j"}, count), do: count + 1
  def update({:char, "k"}, count), do: count - 1
  def update({:char, "q"}, count), do: {:quit, count}
  def update(_event, count), do: count

  def view(count) do
    box([
      text("Count: #{count}"),
      text("j/k to change, q to quit")
    ])
  end
end

Terra.run(Counter)
```

`use Terra` adds the behaviour, imports the layout primitives (`text/2`,
`vstack/2`, `hstack/2`, `box/2`), and gives you a pass-through `event_to_msg/2`.

## Events

Keys arrive as a small runtime event union, never as raw bytes:

```
:up | :down | :left | :right | :enter | :tab | :backspace | :esc | :interrupt
| {:char, grapheme} | {:ctrl, atom}
```

Partial escape and UTF-8 sequences are buffered, so a split arrow or a split
multi-byte character is emitted once, correctly.

Run the key debugger to watch events arrive as Terra parses them: `mix run examples/keys.exs`.

Map events to your own messages with `event_to_msg/2`, or return `:ignore` to
drop an event:

```elixir
def event_to_msg({:char, " "}, _state), do: :toggle
def event_to_msg(_event, _state), do: :ignore
```

## update/2 and commands

`update/2` is pure and returns one of:

- `state` to keep running unchanged
- `{:quit, state}` to stop
- `{state, commands}` to keep running and schedule work

Commands are data the runtime executes:

```elixir
def init(_opts), do: {0, [{:tick, 100, :tick}]}

def update(:tick, ticks), do: {ticks + 1, [{:tick, 100, :tick}]}
```

After 100 ms the runtime delivers `:tick` to `update/2`. Return commands from
`init/1` to start a timer immediately. `guides/effects.md` covers the file and
port commands and the watcher example that motivates them.

## Rendering

`view/1` returns plain data. Build it with `text/1-2`, `vstack/1-2`, `hstack/1-2`
and `box/1-2`, with `:width`, `:height`, `:gap`, `:align`, `:valign`, `:padding`,
`:border` and `:title` options. Terra measures and places the layout into a cell
grid, diffs it against the previous frame, and writes only what changed.

For the small pieces of a form, `Terra.Widget` renders a list, progress bar,
spinner or text input from state you own, and `Terra.Focus` handles Tab order.

## Testing headlessly

Snapshots and simulated keys need no terminal:

```elixir
machine = Terra.Test.start(Counter, width: 26, height: 4)

machine
|> Terra.Test.send_keys("jj")
|> Terra.Test.render()
#=> "┌────────────────────────┐\n│Count: 2                │\n│j/k to change, q to quit│\n└────────────────────────┘"

Terra.Test.state(machine)
#=> 2
```

`Terra.Test.render/1` also accepts a module or a view directly.

## Running apps

Run an app as a script:

```bash
mix run examples/counter.exs
```

`examples/keys.exs` shows the last 20 parsed input events and
`examples/test_watcher.exs` runs `mix test` as a command and lists failures.

`iex -S mix` is **not supported**: IEx owns stdin, so raw mode, rendering and
restore are not guaranteed there.

## The restore contract

Terra owns the terminal only while your app runs and restores it on **every**
exit path:

- `{:quit, state}` from `update/2`
- `Ctrl+C` / `:interrupt`
- a crash in `init/1`, `update/2` or `view/1`

After each path: cooked mode, visible cursor, main screen. If a callback raises,
Terra restores first and then lets the original error surface; it is never
swallowed.

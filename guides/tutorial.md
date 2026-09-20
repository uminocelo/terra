# The Terra tutorial

A hands-on walkthrough of building terminal apps with Terra: a counter, a
tick-driven spinner, a keyboard menu, layout, styling, and headless tests.

Everything here runs with Elixir 1.18+ on OTP 28+ and **no runtime dependencies**.

If you only want the short version, read `guides/getting_started.md`. This page
goes deeper and every example is a file you can run from the repo.

- [1. Run the examples](#1-run-the-examples)
- [2. The loop in five minutes](#2-the-loop-in-five-minutes)
- [3. Events](#3-events)
- [4. Mapping events to messages](#4-mapping-events-to-messages)
- [5. Commands and ticks](#5-commands-and-ticks)
- [6. Layout](#6-layout)
- [7. Styling](#7-styling)
- [8. A menu with arrow keys](#8-a-menu-with-arrow-keys)
- [9. Testing without a terminal](#9-testing-without-a-terminal)
- [10. The restore contract](#10-the-restore-contract)
- [11. Gotchas and current limits](#11-gotchas-and-current-limits)
- [12. Widgets, focus, and themes](#12-widgets-focus-and-themes)

## 1. Run the examples

From the repo root:

```bash
mix run examples/counter.exs   # j/k to change, q to quit
mix run examples/tick.exs      # a spinner that advances every 100 ms, q to quit
mix run examples/menu.exs      # arrow keys via j/k or ↑/↓, Enter to select, q/Esc to quit
```

Each example takes over the terminal, draws a frame, reacts to keys, and puts
your shell back when you quit. Run them in a real terminal (`mix run`), not
inside IEx.

The app modules live in `*_app.exs` next to the runner so tests can load them
without a terminal.

## 2. The loop in five minutes

A Terra app is a module implementing three callbacks. `use Terra` marks it as an
app and imports the layout primitives.

```elixir
defmodule Counter do
  use Terra

  # Called once. Return the initial state.
  def init(_opts), do: 0

  # Called for every key. Return the next state.
  def update({:char, "j"}, count), do: count + 1
  def update({:char, "k"}, count), do: count - 1
  def update({:char, "q"}, count), do: {:quit, count}
  def update(_event, count), do: count

  # Called after every update. Return the screen as data.
  def view(count) do
    box([
      text("Count: #{count}", fg: :green),
      text("j/k to change, q to quit", dim: true)
    ])
  end
end

Terra.run(Counter)
```

Run it:

```bash
mix run examples/counter.exs
```

What happens:

1. `Terra.run/1` takes the terminal (raw mode, alternate screen, hidden cursor).
2. `init/1` returns `0`.
3. `view/1` is rendered to a cell grid and painted.
4. Each keypress becomes an event, `update/2` produces a new state, and the frame
   is redrawn.
5. `{:quit, state}` stops the loop, restores the terminal, and `run/1` returns
   `{:ok, state}`.

State can be anything: an integer, a map, a struct. `update/2` must stay pure
(no file or network IO); put effects in commands instead (section 5).

## 3. Events

Keys arrive as a small event union. You never match on raw escape bytes.

```
:up | :down | :left | :right      arrow keys (CSI or SS3)
:enter | :tab | :backspace
:esc                              a lone Escape, after a short timeout
:interrupt                        Ctrl+C
{:char, "a"}                      one printable grapheme
{:ctrl, :a}                       a Ctrl+letter combination
```

Terra buffers partial input, so this is safe:

- an arrow sequence split across two reads becomes exactly one `:up`
- a multi-byte character split across two reads becomes exactly one
  `{:char, "é"}`
- combining marks join their base character into one grapheme

Bytes that never form a documented event (an unknown escape sequence, an
Alt-modified key) are dropped.

## 4. Mapping events to messages

`update/2` can match runtime events directly, but most apps want their own
message names. Define `event_to_msg/2` and return either a message or `:ignore`.

```elixir
defmodule Menu do
  use Terra

  def event_to_msg({:char, "j"}, _state), do: :down
  def event_to_msg({:char, "k"}, _state), do: :up
  def event_to_msg(:enter, _state), do: :select
  def event_to_msg({:char, "q"}, _state), do: :quit
  def event_to_msg(:esc, _state), do: :quit
  def event_to_msg(event, _state) when event in [:up, :down], do: event
  def event_to_msg(_event, _state), do: :ignore
end
```

`:ignore` drops the event: `update/2` never sees it. The default
`event_to_msg/2` (from `use Terra`) passes events through unchanged, so simple
apps can skip this entirely.

## 5. Commands and ticks

`update/2` may return `{state, commands}` to keep running and schedule work.
Commands are data, not functions:

```elixir
{:tick, ms, msg}
```

After `ms` milliseconds the runtime delivers `msg` to `update/2`.

```elixir
defmodule Spinner do
  use Terra

  @frames ["|", "/", "-", "\\"]
  @tick_ms 100

  def init(_opts), do: {0, [{:tick, @tick_ms, :tick}]}

  def update(:tick, ticks), do: {ticks + 1, [{:tick, @tick_ms, :tick}]}
  def update({:char, "q"}, ticks), do: {:quit, ticks}
  def update(_event, ticks), do: ticks

  def view(ticks) do
    frame = Enum.at(@frames, rem(ticks, length(@frames)))
    box([text("#{frame} working", fg: :cyan), text("q to quit", dim: true)])
  end
end
```

Returning a fresh `{:tick, ...}` on every tick is how you build a repeating
timer. You can schedule several at once, and `init/1` can return commands too
(used above so the spinner starts immediately).

The three allowed `update/2` return shapes are:

| Return | Meaning |
| --- | --- |
| `state` | keep running, state unchanged or updated |
| `{:quit, state}` | stop the loop and restore |
| `{state, commands}` | keep running and schedule commands |

There is no `{:noreply, state}`; just return the state.

## 6. Layout

`view/1` returns data. Terra measures each primitive, places it into the
available area, paints a cell grid, and clips anything that does not fit. There
is no flexbox and no wrapping: overflow is dropped.

A root `box` grows to fill the area it is given, so an unsized box at the root
occupies the whole screen. Give it `:width`/`:height` when you want it compact.

```elixir
box(
  vstack([
    text("Title", bold: true),
    hstack([text("left"), text("  right")]),
    text("\nmulti\nline")
  ]),
  padding: 1
)
```

Primitives:

- `text(string)` / `text(string, style)` — one or more lines (`\n` splits)
- `vstack(children)` / `vstack(children, opts)` — top to bottom
- `hstack(children)` / `hstack(children, opts)` — left to right
- `box(content)` / `box(content, opts)` — bordered container; a list of children
  is stacked vertically

Options:

| Option | Applies to | Meaning |
| --- | --- | --- |
| `:width`, `:height` | all | fixed size, overriding the natural size |
| `:gap` | stacks | blank cells between children (default 0) |
| `:align` | `vstack`, `box` | `:left`, `:center`, `:right` |
| `:align` | `hstack` | `:top`, `:center`, `:bottom` |
| `:valign` | `box` | `:top`, `:center`, `:bottom` |
| `:padding` | `box` | integer, or `[top:, right:, bottom:, left:]` |
| `:border` | `box` | `false` disables the single-line border |

Sizes are in terminal cells, and wide graphemes (CJK, emoji) correctly take two
columns.

Natural sizing example:

```elixir
Terra.View.measure(box(text("hi")))                     #=> {4, 3}
Terra.View.measure(box(text("hi"), padding: 1))         #=> {6, 5}
Terra.View.measure(vstack([text("a"), text("b")], gap: 1)) #=> {1, 3}
```

## 7. Styling

Pass a keyword list to `text/2`:

```elixir
text("danger", fg: :red, bold: true)
text("muted", dim: true)
text("selected", reverse: true)
text("link", fg: :cyan, underline: true)
text("256-colour", fg: 208)   # any 0..255 palette index
```

Supported keys: `:fg`, `:bg` (named colour or `0..255`), `:bold`, `:dim`,
`:italic`, `:underline`, `:reverse`. Unknown keys are ignored rather than
crashing a frame.

Named colours: `:black`, `:red`, `:green`, `:yellow`, `:blue`, `:magenta`,
`:cyan`, `:white`, and the same with a `:bright_` prefix.

## 8. A menu with arrow keys

`examples/menu_app.exs` combines everything: a small state machine, event
mapping, arrow keys, and selection highlighting.

```elixir
defmodule Menu do
  use Terra

  @items [{"Start", :start}, {"Settings", :settings}, {"Quit", :quit}]

  def init(_opts), do: %{index: 0, chosen: nil}

  def event_to_msg({:char, "j"}, _state), do: :down
  def event_to_msg({:char, "k"}, _state), do: :up
  def event_to_msg(:enter, _state), do: :select
  def event_to_msg({:char, "q"}, _state), do: :quit
  def event_to_msg(:esc, _state), do: :quit
  def event_to_msg(event, _state) when event in [:up, :down], do: event
  def event_to_msg(_event, _state), do: :ignore

  def update(:down, state), do: %{state | index: rem(state.index + 1, length(@items))}
  def update(:up, state), do: %{state | index: rem(state.index - 1 + length(@items), length(@items))}

  def update(:select, state) do
    case Enum.at(@items, state.index) do
      {"Quit", :quit} -> {:quit, state}
      {label, action} -> %{state | chosen: {label, action}}
    end
  end

  def update(:quit, state), do: {:quit, state}
  def update(_msg, state), do: state

  def view(state) do
    rows =
      @items
      |> Enum.with_index()
      |> Enum.map(fn {{label, _action}, index} ->
        if index == state.index do
          text("› " <> label, reverse: true)
        else
          text("  " <> label, dim: true)
        end
      end)

    box(vstack(rows), padding: [top: 0, right: 2, bottom: 0, left: 1])
  end
end
```

Run it with `mix run examples/menu.exs`. Use `j`/`k`, the actual arrow keys, or
`↑`/`↓`; press Enter to select; `q` or `Esc` to quit.

Note how `event_to_msg/2` normalizes both `"j"` and `:down` into the same
`:down` message, so `update/2` only deals in your domain language.

## 9. Testing without a terminal

`Terra.Test` drives an app headlessly: snapshot rendering plus simulated keys.
This is a first-class feature, not an afterthought, so no PTY or TTY is needed
in CI.

### Render a module or a view

```elixir
Terra.Test.render(Counter, width: 26, height: 4)
#=> "┌────────────────────────┐\n│Count: 0                │\n│j/k to change, q to quit│\n└────────────────────────┘"

Terra.Test.render(Terra.View.text("hi"), width: 8, height: 2)
#=> "hi"
```

### Drive a machine

```elixir
machine = Terra.Test.start(Counter)

Terra.Test.send_keys(machine, "jj")
Terra.Test.state(machine)     #=> 2
Terra.Test.render(machine)    #=> "…Count: 2…"

Terra.Test.send_keys(machine, [:up])   # a single runtime event works too
Terra.Test.send_keys(machine, "k")
Terra.Test.state(machine)     #=> 1
```

`send_keys/2` accepts a string (each grapheme → `{:char, g}`), a single event
like `:up` or `{:ctrl, :a}`, or a list of either. It returns the machine, so it
pipes:

```elixir
snapshot =
  Counter
  |> Terra.Test.start(width: 40, height: 5)
  |> Terra.Test.send_keys("jj")
  |> Terra.Test.render()
```

Assert on snapshots in ExUnit:

```elixir
defmodule CounterTest do
  use ExUnit.Case, async: true

  test "j increments and q quits" do
    machine = Terra.Test.start(Counter)

    assert machine |> Terra.Test.send_keys("jj") |> Terra.Test.render() =~ "Count: 2"

    ref = Process.monitor(machine)
    Terra.Test.send_keys(machine, "q")
    assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
  end
end
```

Ticks work headlessly too:

```elixir
machine = Terra.Test.start(Spinner)
Process.sleep(250)
assert Terra.Test.state(machine) >= 2
Terra.Test.stop(machine)
```

`Terra.Test.start/2` forwards options to `Terra.Runtime`, so `:width`, `:height`
and `:app` (options for `init/1`) are available.

## 10. The restore contract

Terra owns the terminal only while the app runs, and it gives it back on every
path it can observe:

| Path | Result |
| --- | --- |
| `update/2` returns `{:quit, state}` | restore, `run/1` returns `{:ok, state}` |
| Ctrl+C / `:interrupt` | restore, loop stops |
| `init/1`, `update/2` or `view/1` raises | restore first, then the original error is re-raised |
| the process that called `run/1` dies | restore |
| the runtime is killed (`:kill`) | restore via the monitored terminal owner |

After each path: cooked input mode, visible cursor, main screen, and your shell
is usable.

Crash handling means the error is never swallowed:

```elixir
assert_raise RuntimeError, "boom from view/1", fn ->
  Terra.run(BrokenApp)
end
# the terminal is already restored when the exception reaches you
```

Missing callbacks are a startup error, not a mystery:

```elixir
Terra.run(NotAnApp)
# ** (ArgumentError) Terra app NotAnApp is missing required callbacks: init/1, update/2, view/1.
```

## 11. Gotchas and current limits

- **OTP 28+ is required.** Raw mode uses `:shell.start_interactive({:noshell,
  :raw})`.
- **`iex -S mix` is not supported.** IEx owns stdin, so raw mode, rendering and
  restore are not guaranteed; run apps with `mix run path/to/app.exs`.
- **Ctrl+C is delivered as `:interrupt`.** Terra turns off the tty `ISIG` flag so
  the byte reaches the app; the runtime stops on it unless your app quits first.
- **`SIGTERM` is not trappable** by the app, so a `kill` of the VM can leave the
  alternate screen behind. A plain `:kill` of the runtime process is handled.
- **No wrapping, no flex.** Content that does not fit is clipped. Size things with
  explicit `:width`/`:height` where it matters.
- **Frames are diffed.** Only changed cells are written after the first frame;
  a resize repaints from scratch. A full 80x24 frame is well under the 5 ms budget.
- **Widgets are stateless.** `Terra.Widget` list/progress/spinner/input and
  `Terra.Focus` are plain functions over parent state, not nested components.
- **Terminal size** is read from the tty, then `COLUMNS`/`LINES`, then 80x24.
  Pass `:width`/`:height` to `run/2` or `Terra.Test.start/2` to pin it.

## 12. Widgets, focus, and themes

`Terra.Widget` renders the small pieces a form needs, and the state stays in your
app. Each widget has an event helper that returns documented values:

```elixir
def view(state) do
  box(
    vstack([
      Widget.input(state.draft, cursor: state.cursor, focused: state.focus == :input),
      Widget.list(state.todos, selected: state.selected, height: 5)
    ]),
    title: "Todos",
    border: :rounded
  )
end

def event_to_msg(event, state) do
  case Focus.event(event, Focus.ids(view(state)), state.focus) do
    {:focus, id} -> {:focus, id}
    :ignore -> event
  end
end
```

- `Terra.Widget.list/2` + `list_event/3` — highlight, scrolling window, `{:chosen, i}` / `:cancel`
- `Terra.Widget.progress/2` — `0..1` by default, `max: 100` for percentages
- `Terra.Widget.spinner/2` + `spinner_frame/2` — advances with a tick
- `Terra.Widget.input/2` + `input_event/3` — insert, backspace, cursor, `{:submit, value}`
- `Terra.Focus` — mark children with `focus/2`; Tab moves forward, Shift-Tab
  (`{:ctrl, :tab}`) moves backward, and only marked children participate
- `Terra.Theme` — `%{fg:, bg:, accent:, border:}`; use `fg: :accent` in a style and
  borders pick up `:border`. The default theme resolves every token to nothing

Boxes also take a `:title` and a `:border` style (`:single`, `:double`, `:rounded`,
`:thick`, `:ascii`, or `false`). `examples/todo.exs` uses input + list + focus, and
`examples/pomodoro.exs` uses ticks + progress + spinner.

## Where to go next

- `guides/getting_started.md` — the one-page version
- `examples/` — counter, spinner, menu
- `Terra.App` — the callbacks in detail
- `Terra.View` — layout primitives and options
- `Terra.Runtime` — the run loop, options, resize, and restore paths
- `Terra.Widget` / `Terra.Focus` / `Terra.Theme` — widgets and theming
- `Terra.Test` — headless driving and snapshots

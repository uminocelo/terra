# Effects as data

`view/1` is pure: it takes state and returns a tree of text, stacks and boxes.
It never reads a file, runs a shell command, or talks to the network. Effects
in Terra are **commands**, and commands are plain data returned from `init/1`
and `update/2`.

```elixir
def update(:refresh, state) do
  {state, [{:read_file, "data/todos.txt", :loaded}]}
end
```

The runtime executes the command off the view path and delivers the result to
`update/2` like any other message, wrapped as `{msg, result}`:

```elixir
def update({:loaded, {:ok, contents}}, state), do: %{state | text: contents}
def update({:loaded, {:error, reason}}, state), do: %{state | error: inspect(reason)}
```

## The shapes

| Command | Delivered to `update/2` |
| --- | --- |
| `{:tick, ms, msg}` | `msg` after `ms` milliseconds |
| `{:read_file, path, msg}` | `{msg, {:ok, contents} \| {:error, reason}}` |
| `{:port, cmd, msg}` | `{msg, {:ok, {lines, status}}}` when the command finishes, `{msg, {:error, reason}}` when the port cannot start, closes, or crashes |

A non-zero exit status from a port command is data, not an error: the command
ran and produced output, and your app decides what that output means. A failing
`mix test` run is still parseable.

Return a list of commands to schedule several at once, and return commands from
`init/1` to start work immediately:

```elixir
def init(_opts) do
  {%{status: :running}, [{:port, "mix test --no-color", :ran}, {:tick, 150, :tick}]}
end
```

## The worked examples

- `examples/keys.exs` is the key debugger: a ring buffer of the last 20 parsed
  events, useful when you suspect the input layer before your own app. Run it
  with `mix run examples/keys.exs`.
- `examples/test_watcher.exs` is the reason this page exists: it runs
  `mix test --no-color` as a port command, parses the output into failures, and
  renders them in a selectable list with an assertion pane. No IO touches
  `view/1`; re-running is just returning the same command data again.

Both apps are plain `Terra.App` modules you can read top to bottom, and both
are driven headlessly in the test suite.

## The restore contract still holds

Commands change nothing about the terminal. Whether your app quits from
`update/2`, receives Ctrl+C, crashes in a callback, or dies while a port is
still running, the runtime restores cooked mode, a visible cursor and the main
screen. Pending command runners are stopped before the restore, so a slow
`mix test` cannot outlive its window.

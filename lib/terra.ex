defmodule Terra do
  @moduledoc """
  Zero-dependency TUI library for Elixir (please use OTP 28+) built around an Elm loop.

  An app is a module that implements `Terra.App`. `use Terra` wires up the
  behaviour, imports the layout primitives, and gives you the default
  `event_to_msg/2`:

      defmodule Counter do
        use Terra

        def init(_opts), do: 0

        def update({:char, "j"}, count), do: count + 1
        def update({:char, "k"}, count), do: count - 1
        def update({:char, "q"}, count), do: {:quit, count}
        def update(_event, count), do: count

        def view(count) do
          box([text("Count: \#{count}"), text("j/k to change, q to quit")])
        end
      end

      Terra.run(Counter)

  `run/1` takes the terminal, drives the loop, and gives the terminal back on
  `:quit`, `:interrupt`, or a callback crash. See `Terra.App` for the callbacks,
  `Terra.View` for the primitives, and `Terra.Test` for headless tests.
  """

  @type event :: Terra.Input.event()
  @type command :: Terra.App.command()

  @doc """
  Marks a module as a Terra app.

  Adds `@behaviour Terra.App`, imports `Terra.View` so `text/2`, `vstack/2`,
  `hstack/2` and `box/2` are available unqualified, and defines an overridable
  `event_to_msg/2` that passes events through unchanged.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Terra.App
      import Terra.View

      @impl Terra.App
      def event_to_msg(event, _state), do: event

      defoverridable event_to_msg: 2
    end
  end

  @doc """
  Runs a Terra app and returns `{:ok, final_state}` when it quits.

  The terminal is restored on every exit path. If a callback raises, the terminal
  is restored first and then the original error is re-raised, so it is never
  swallowed. Missing callbacks raise `ArgumentError` before anything starts.

  Options are forwarded to `Terra.Runtime` (see its moduledoc), including
  `:terminal` (set `false` for a headless run), `:app` (options for `init/1`) and
  `:events`.
  """
  @spec run(module, keyword) :: {:ok, term} | {:error, term} | no_return
  def run(module, opts \\ []), do: Terra.Runtime.run(module, opts)
end

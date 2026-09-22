# The key debugger used by examples/keys.exs.
#
# Kept in its own file so tests can load the app without taking a terminal.

defmodule Keys do
  @moduledoc """
  A key debugger: shows the last 20 parsed events so a wrong CSI or grapheme
  is visible before you blame your own app.

  The runtime still owns restore: `q` returns `{:quit, state}` and `:interrupt`
  stops the loop after `update/2` records it, so Ctrl+C is visible in the ring
  on the final frame.
  """

  use Terra

  @limit 20

  @impl Terra.App
  def init(_opts), do: %{events: [], count: 0}

  @impl Terra.App
  def update({:char, "q"}, state), do: {:quit, state}

  def update(event, state) do
    events = [event | state.events] |> Enum.take(@limit)
    %{state | events: events, count: state.count + 1}
  end

  @impl Terra.App
  def view(state) do
    rows =
      case state.events do
        [] -> [text("press keys to see parsed events", dim: true)]
        events -> Enum.map(events, fn event -> text(inspect(event)) end)
      end

    box(
      vstack([
        text("last #{length(state.events)} of #{state.count} events", dim: true),
        text(""),
        vstack(rows),
        text(""),
        text("q or Ctrl+C to quit", dim: true)
      ]),
      title: "Keys",
      border: :rounded,
      padding: [top: 0, right: 2, bottom: 0, left: 1]
    )
  end
end

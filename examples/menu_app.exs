# The keyboard menu used by examples/menu.exs.
#
# Kept in its own file so tests can load the app without taking a terminal.

defmodule Menu do
  @moduledoc """
  A selectable menu: `j`/`k` or the arrow keys move, Enter selects, `q`/Esc quits.
  """

  use Terra

  @items [{"Start", :start}, {"Settings", :settings}, {"Quit", :quit}]

  @impl Terra.App
  def init(_opts), do: %{index: 0, chosen: nil}

  @impl Terra.App
  def event_to_msg({:char, "j"}, _state), do: :down
  def event_to_msg({:char, "k"}, _state), do: :up
  def event_to_msg(:enter, _state), do: :select
  def event_to_msg({:char, "q"}, _state), do: :quit
  def event_to_msg(:esc, _state), do: :quit
  def event_to_msg(event, _state) when event in [:up, :down], do: event
  def event_to_msg(_event, _state), do: :ignore

  @impl Terra.App
  def update(:down, state), do: %{state | index: rem(state.index + 1, length(@items))}

  def update(:up, state),
    do: %{state | index: rem(state.index - 1 + length(@items), length(@items))}

  def update(:select, state) do
    case Enum.at(@items, state.index) do
      {"Quit", :quit} -> {:quit, state}
      {label, action} -> %{state | chosen: {label, action}}
    end
  end

  def update(:quit, state), do: {:quit, state}
  def update(_msg, state), do: state

  @impl Terra.App
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

    status =
      case state.chosen do
        nil -> text("j/k or arrows, Enter to select, q to quit", dim: true)
        {label, _action} -> text("Selected: #{label}", fg: :green)
      end

    box(
      vstack([vstack(rows), text(""), status]),
      padding: [top: 0, right: 2, bottom: 0, left: 1]
    )
  end
end

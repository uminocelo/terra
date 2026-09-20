# A spinner driven by a tick command, in its own file so tests can load it
# without taking a terminal.

defmodule Spinner do
  @moduledoc """
  Shows a spinner that advances on a tick and quits on `q`.
  """

  use Terra

  @frames ["|", "/", "-", "\\"]
  @tick_ms 100

  @impl Terra.App
  def init(_opts), do: {0, [{:tick, @tick_ms, :tick}]}

  @impl Terra.App
  def update(:tick, ticks), do: {ticks + 1, [{:tick, @tick_ms, :tick}]}
  def update({:char, "q"}, ticks), do: {:quit, ticks}
  def update(_event, ticks), do: ticks

  @impl Terra.App
  def view(ticks) do
    frame = Enum.at(@frames, rem(ticks, length(@frames)))

    box([
      text("#{frame} working", fg: :cyan),
      text("ticks: #{ticks}", dim: true),
      text("q to quit", dim: true)
    ])
  end
end

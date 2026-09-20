# The Counter app used by examples/counter.exs.
#
# It lives in its own file so tests can load the app without taking a terminal:
#
#     Code.require_file("examples/counter_app.exs", File.cwd!())
#     Terra.Test.render(Counter)

defmodule Counter do
  @moduledoc """
  A tiny counter: `j` and `k` change it, `q` quits.
  """

  use Terra

  @impl Terra.App
  def init(_opts), do: 0

  @impl Terra.App
  def update({:char, "j"}, count), do: count + 1
  def update({:char, "k"}, count), do: count - 1
  def update({:char, "q"}, count), do: {:quit, count}
  def update(_event, count), do: count

  @impl Terra.App
  def view(count) do
    box([
      text("Count: #{count}", fg: :green),
      text("j/k to change, q to quit", dim: true)
    ])
  end
end

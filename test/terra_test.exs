defmodule TerraTest do
  use ExUnit.Case, async: true

  doctest Terra

  defmodule Demo do
    use Terra

    def init(_opts), do: 0
    def update({:char, "q"}, state), do: {:quit, state}
    def update(_event, state), do: state
    def view(state), do: text("state=#{state}")
  end

  test "use Terra provides the loop callbacks and layout imports" do
    assert function_exported?(Demo, :init, 1)
    assert function_exported?(Demo, :update, 2)
    assert function_exported?(Demo, :view, 1)
    assert Demo.view(1) == {:text, "state=1", []}
  end

  test "use Terra provides a pass-through event_to_msg/2" do
    assert Demo.event_to_msg({:char, "j"}, 0) == {:char, "j"}
    assert Demo.event_to_msg(:interrupt, 0) == :interrupt
  end

  test "run/1 is the runtime entry point" do
    assert Terra.run(Demo, terminal: false, events: [{:char, "q"}]) == {:ok, 0}
  end
end

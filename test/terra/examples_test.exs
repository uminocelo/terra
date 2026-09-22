defmodule Terra.ExamplesTest do
  use ExUnit.Case, async: true

  @examples Path.expand("../../examples", __DIR__)

  setup_all do
    Code.require_file("counter_app.exs", @examples)
    Code.require_file("tick_app.exs", @examples)
    Code.require_file("menu_app.exs", @examples)
    Code.require_file("todo_app.exs", @examples)
    Code.require_file("pomodoro_app.exs", @examples)
    Code.require_file("keys_app.exs", @examples)
    :ok
  end

  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(5)
        {:cont, false}
      end
    end)
  end

  test "the counter example uses only the public API" do
    snapshot = Terra.Test.render(Counter, width: 40, height: 5)

    assert snapshot =~ "Count: 0"
    assert snapshot =~ "j/k to change, q to quit"
  end

  test "the documented counter keys change state and quit" do
    machine = Terra.Test.start(Counter)

    Terra.Test.send_keys(machine, "jj")
    assert Terra.Test.state(machine) == 2
    assert Terra.Test.render(machine) =~ "Count: 2"

    Terra.Test.send_keys(machine, "k")
    assert Terra.Test.state(machine) == 1

    ref = Process.monitor(machine)
    Terra.Test.send_keys(machine, "q")
    assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
  end

  test "the tick example advances on its tick command" do
    machine = Terra.Test.start(Spinner)

    assert eventually(fn -> Terra.Test.state(machine) >= 2 end)
    assert Terra.Test.render(machine) =~ "working"
    assert Terra.Test.render(machine) =~ "q to quit"

    Terra.Test.stop(machine)
  end

  test "the menu example moves with j/k and the arrow keys" do
    machine = Terra.Test.start(Menu, width: 40, height: 10)

    assert Terra.Test.render(machine) =~ "› Start"

    Terra.Test.send_keys(machine, "j")
    assert Terra.Test.state(machine).index == 1
    assert Terra.Test.render(machine) =~ "› Settings"

    Terra.Test.send_keys(machine, [:up])
    assert Terra.Test.state(machine).index == 0

    Terra.Test.send_keys(machine, "k")
    assert Terra.Test.state(machine).index == 2

    Terra.Test.stop(machine)
  end

  test "the menu example selects and quits" do
    machine = Terra.Test.start(Menu, width: 40, height: 10)

    Terra.Test.send_keys(machine, [:enter])
    assert Terra.Test.state(machine).chosen == {"Start", :start}
    assert Terra.Test.render(machine) =~ "Selected: Start"

    ref = Process.monitor(machine)
    Terra.Test.send_keys(machine, [{:char, "q"}])
    assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
  end

  test "the menu example quits on Esc" do
    machine = Terra.Test.start(Menu, width: 40, height: 10)
    ref = Process.monitor(machine)

    Terra.Test.send_keys(machine, [:esc])
    assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
  end

  test "the todo example adds, reorders focus, and deletes" do
    machine = Terra.Test.start(Todo, width: 40, height: 14)

    assert Terra.Test.state(machine).focus == :input

    Terra.Test.send_keys(machine, "buy milk")
    assert Terra.Test.state(machine).draft == "buy milk"

    Terra.Test.send_keys(machine, [:enter])
    assert Terra.Test.state(machine).todos == ["buy milk"]
    assert Terra.Test.state(machine).draft == ""

    Terra.Test.send_keys(machine, "walk dog")
    Terra.Test.send_keys(machine, [:enter])
    assert Terra.Test.state(machine).todos == ["buy milk", "walk dog"]

    Terra.Test.send_keys(machine, [:tab])
    assert Terra.Test.state(machine).focus == :list

    Terra.Test.send_keys(machine, [:up])
    assert Terra.Test.state(machine).selected == 0
    assert Terra.Test.render(machine) =~ "walk dog"

    Terra.Test.send_keys(machine, [{:char, "d"}])
    assert Terra.Test.state(machine).confirming == 0
    assert Terra.Test.render(machine) =~ "Delete"

    Terra.Test.send_keys(machine, [{:char, "n"}])
    assert Terra.Test.state(machine).confirming == nil
    assert Terra.Test.state(machine).todos == ["buy milk", "walk dog"]

    Terra.Test.send_keys(machine, [{:char, "d"}, {:char, "y"}])
    assert Terra.Test.state(machine).todos == ["walk dog"]

    Terra.Test.stop(machine)
  end

  test "the todo example quits with Esc" do
    machine = Terra.Test.start(Todo, width: 40, height: 14)
    ref = Process.monitor(machine)

    Terra.Test.send_keys(machine, [:esc])
    assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
  end

  test "the pomodoro example counts down and switches phase on tick" do
    machine =
      Terra.Test.start(Pomodoro,
        width: 40,
        height: 10,
        app: [tick_ms: 5, focus_seconds: 3, break_seconds: 1]
      )

    assert Terra.Test.state(machine).phase == :focus
    assert Terra.Test.state(machine).remaining == 3

    assert eventually(fn ->
             state = Terra.Test.state(machine)
             state.phase == :break and state.cycles >= 1
           end)

    snapshot = Terra.Test.render(machine)
    assert snapshot =~ "Break"
    assert snapshot =~ "cycles: 1"
    assert snapshot =~ "█" or snapshot =~ "░"

    Terra.Test.stop(machine)
  end

  test "the pomodoro example pauses with space and quits with q" do
    machine =
      Terra.Test.start(Pomodoro, width: 40, height: 10, app: [tick_ms: 5, focus_seconds: 60])

    Terra.Test.send_keys(machine, [{:char, " "}])
    assert Terra.Test.state(machine).running == false
    assert Terra.Test.render(machine) =~ "paused"

    frozen = Terra.Test.state(machine).remaining
    Process.sleep(30)
    assert Terra.Test.state(machine).remaining == frozen

    ref = Process.monitor(machine)
    Terra.Test.send_keys(machine, [{:char, "q"}])
    assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
  end

  test "the keys example records the last 20 events" do
    machine = Terra.Test.start(Keys, width: 40, height: 30)

    # 25 keys, none of them q: the ring keeps only the last 20.
    Terra.Test.send_keys(machine, "abcdefghijklmnoprstuvwxyz")

    state = Terra.Test.state(machine)
    assert state.count == 25
    assert length(state.events) == 20
    assert hd(state.events) == {:char, "z"}

    snapshot = Terra.Test.render(machine)
    assert snapshot =~ "last 20 of 25 events"
    assert snapshot =~ ~s({:char, "z"})

    Terra.Test.stop(machine)
  end

  test "the keys example shows a multi-byte grapheme as one event" do
    machine = Terra.Test.start(Keys, width: 40, height: 10)

    Terra.Test.send_keys(machine, "é")

    assert Terra.Test.state(machine).events == [{:char, "é"}]
    assert Terra.Test.render(machine) =~ ~s({:char, "é"})

    Terra.Test.stop(machine)
  end

  test "the keys example quits with q and with Ctrl+C" do
    machine = Terra.Test.start(Keys, width: 40, height: 10)
    ref = Process.monitor(machine)

    Terra.Test.send_keys(machine, [{:char, "q"}])
    assert_receive {:DOWN, ^ref, :process, ^machine, :normal}

    machine = Terra.Test.start(Keys, width: 40, height: 10)
    ref = Process.monitor(machine)

    Terra.Test.send_keys(machine, [:interrupt])
    assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
  end
end

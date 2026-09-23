defmodule Terra.TestWatcherTest do
  use ExUnit.Case, async: true

  @examples Path.expand("../../examples", __DIR__)
  @fixtures Path.expand("../fixtures/mix_test", __DIR__)

  setup_all do
    Code.require_file("test_watcher_app.exs", @examples)
    :ok
  end

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
  end

  describe "MixTest.parse/1" do
    test "a passing suite produces an empty failure list and a pass count" do
      result = TestWatcher.MixTest.parse(fixture("pass.txt"))

      assert result.failures == []
      assert result.total == 5
      assert result.failed == 0
      assert result.passed == 5
    end

    test "one failure parses into file, line, name and assertion" do
      result = TestWatcher.MixTest.parse(fixture("one_fail.txt"))

      assert result.failed == 1
      assert result.passed == 3

      assert [
               %{
                 name: "test adds two numbers (MathTest)",
                 file: "test/math_test.exs",
                 line: 8,
                 assertion: assertion
               }
             ] = result.failures

      assert assertion =~ "Assertion with == failed"
      assert assertion =~ "code:  assert add(1, 1) == 3"
      refute assertion =~ "stacktrace"
    end

    test "many failures parse in a stable order, including doctests" do
      result = TestWatcher.MixTest.parse(fixture("many_fails.txt"))

      assert result.total == 9
      assert result.failed == 3
      assert result.passed == 6

      assert [
               %{
                 name: "test parses a record (ParserTest)",
                 file: "test/parser_test.exs",
                 line: 12
               },
               %{name: "test renders a row (RowTest)", file: "test/row_test.exs", line: 20},
               %{
                 name: "doctest Formatter.docs/1 (FormatterTest)",
                 file: "test/formatter_test.exs",
                 line: 3
               }
             ] = result.failures

      assert Enum.at(result.failures, 0).assertion =~ "left:  [\"a,b\"]"
      assert Enum.at(result.failures, 1).assertion =~ "right: {:error, :empty}"
      assert Enum.at(result.failures, 2).assertion =~ "Doctest failed"
    end
  end

  describe "watcher commands" do
    test "init schedules the suite as data, not IO in view/1" do
      assert {%{status: :running}, commands} = TestWatcher.init([])
      assert {:port, "mix test --no-color", :ran} in commands
      assert Enum.any?(commands, &match?({:tick, _, :tick}, &1))
    end

    test "r re-runs the suite as a command" do
      state = %{TestWatcher.init(command: nil) | status: :done, command: "mix test --no-color"}

      assert {%{status: :running}, commands} = TestWatcher.update({:char, "r"}, state)

      assert {:port, "mix test --no-color", :ran} in commands
    end
  end

  describe "watcher state machine" do
    test "inject a failing run, select a failure, quit" do
      machine = Terra.Test.start(TestWatcher, width: 80, height: 24, app: [command: nil])

      Terra.Test.send_keys(machine, [{:ran, {:ok, {fixture("many_fails.txt"), 1}}}])

      state = Terra.Test.state(machine)
      assert state.status == :done
      assert length(state.failures) == 3
      assert state.selected == 0

      snapshot = Terra.Test.render(machine)
      assert snapshot =~ "3 failures, 6 passed of 9"
      assert snapshot =~ "test parses a record"
      assert snapshot =~ "Assertion with == failed"

      Terra.Test.send_keys(machine, [:down])
      assert Terra.Test.state(machine).selected == 1

      snapshot = Terra.Test.render(machine)
      assert snapshot =~ "match (=) failed"
      assert snapshot =~ "test/row_test.exs:20"

      ref = Process.monitor(machine)
      Terra.Test.send_keys(machine, [{:char, "q"}])
      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
    end

    test "a passing run renders the pass count" do
      machine = Terra.Test.start(TestWatcher, width: 80, height: 24, app: [command: nil])

      Terra.Test.send_keys(machine, [{:ran, {:ok, {fixture("pass.txt"), 0}}}])

      assert Terra.Test.render(machine) =~ "all 5 tests passed"

      Terra.Test.stop(machine)
    end

    test "a command error renders instead of crashing" do
      machine = Terra.Test.start(TestWatcher, width: 80, height: 24, app: [command: nil])

      Terra.Test.send_keys(machine, [{:ran, {:error, :closed}}])

      assert Terra.Test.state(machine).status == :error
      assert Terra.Test.render(machine) =~ "could not run"

      Terra.Test.stop(machine)
    end

    test "ctrl+d/u scroll the assertion pane within bounds" do
      machine = Terra.Test.start(TestWatcher, width: 80, height: 24, app: [command: nil])

      Terra.Test.send_keys(machine, [{:ran, {:ok, {fixture("many_fails.txt"), 1}}}])
      assert Terra.Test.state(machine).scroll == 0

      Terra.Test.resize(machine, 80, 10)
      assert Terra.Test.state(machine).height == 10

      Terra.Test.send_keys(machine, [{:ctrl, :d}])
      scrolled = Terra.Test.state(machine).scroll
      assert scrolled > 0

      Terra.Test.send_keys(machine, [{:ctrl, :u}])
      assert Terra.Test.state(machine).scroll == 0

      Terra.Test.stop(machine)
    end
  end

  describe "resize" do
    test "shrinking leaves no glyphs outside the new size" do
      machine = Terra.Test.start(TestWatcher, width: 100, height: 30, app: [command: nil])

      Terra.Test.send_keys(machine, [{:ran, {:ok, {fixture("many_fails.txt"), 1}}}])
      assert Terra.Test.render(machine) =~ "test parses a record"

      Terra.Test.resize(machine, 40, 12)

      lines = String.split(Terra.Test.render(machine), "\n")
      assert length(lines) <= 12
      assert Enum.all?(lines, &(String.length(&1) <= 40))

      state = Terra.Test.state(machine)
      assert {state.width, state.height} == {40, 12}
      assert state.scroll <= length(String.split(hd(state.failures).assertion, "\n"))

      Terra.Test.stop(machine)
    end
  end
end

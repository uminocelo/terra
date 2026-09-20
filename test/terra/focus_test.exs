defmodule Terra.FocusTest.App do
  @moduledoc false
  use Terra

  alias Terra.Focus

  def init(_opts), do: %{focus: nil}

  def update({:focus, id}, state), do: %{state | focus: id}
  def update(_msg, state), do: state

  def event_to_msg(event, state), do: Focus.event(event, Focus.ids(view(state)), state.focus)

  def view(state) do
    vstack([
      Focus.focus(:first, text("first", row_style(state.focus, :first))),
      text("not focusable"),
      Focus.focus(:second, text("second", row_style(state.focus, :second)))
    ])
  end

  defp row_style(focus, id), do: if(focus == id, do: [reverse: true], else: [])
end

defmodule Terra.FocusTest do
  use ExUnit.Case, async: true

  alias Terra.{Focus, View}

  describe "ids/1" do
    test "collects marked children in layout order" do
      view =
        View.vstack([
          View.text("title"),
          Focus.focus(:a, View.text("a")),
          View.hstack([
            Focus.focus(:b, View.text("b")),
            View.box(Focus.focus(:c, View.text("c")))
          ])
        ])

      assert Focus.ids(view) == [:a, :b, :c]
    end

    test "an unmarked view has no ids" do
      assert Focus.ids(View.vstack([View.text("a"), View.text("b")])) == []
    end

    test "a focus marker is transparent for measure and place" do
      plain = View.text("hi")
      marked = Focus.focus(:x, plain)

      assert View.measure(marked) == View.measure(plain)
      assert View.place(marked, {0, 0}, {4, 1}) == View.place(plain, {0, 0}, {4, 1})
    end
  end

  describe "move/3" do
    test "cycles forward and backward, wrapping" do
      ids = [:a, :b, :c]

      assert Focus.next(ids, :a) == :b
      assert Focus.next(ids, :c) == :a
      assert Focus.previous(ids, :a) == :c
      assert Focus.previous(ids, :c) == :b
    end

    test "nil starts at the first or last id" do
      assert Focus.next([:a, :b], nil) == :a
      assert Focus.previous([:a, :b], nil) == :b
    end

    test "an unknown current id starts over" do
      assert Focus.next([:a, :b], :nope) == :a
      assert Focus.previous([:a, :b], :nope) == :b
    end

    test "no ids means no focus" do
      assert Focus.next([], :a) == nil
      assert Focus.previous([], :a) == nil
    end

    test "focused?/2 compares ids" do
      assert Focus.focused?(:a, :a)
      refute Focus.focused?(:a, :b)
    end
  end

  describe "event/3" do
    test "maps Tab forward and Shift-Tab backward" do
      assert Focus.event(:tab, [:a, :b], :a) == {:focus, :b}
      assert Focus.event({:ctrl, :tab}, [:a, :b], :a) == {:focus, :b}
      assert Focus.event(:tab, [:a, :b], :b) == {:focus, :a}
      assert Focus.event(:enter, [:a, :b], :a) == :ignore
    end
  end

  describe "in a headless app" do
    test "Tab order is deterministic and skips unmarked children" do
      machine = Terra.Test.start(Terra.FocusTest.App, width: 20, height: 5)

      assert Terra.Test.state(machine).focus == nil

      Terra.Test.send_keys(machine, [:tab])
      assert Terra.Test.state(machine).focus == :first
      assert Terra.Test.render(machine) =~ "first"

      Terra.Test.send_keys(machine, [:tab])
      assert Terra.Test.state(machine).focus == :second

      Terra.Test.send_keys(machine, [:tab])
      assert Terra.Test.state(machine).focus == :first

      Terra.Test.send_keys(machine, [{:ctrl, :tab}])
      assert Terra.Test.state(machine).focus == :second

      Terra.Test.stop(machine)
    end

    test "the focused child is styled and the unmarked one never is" do
      machine = Terra.Test.start(Terra.FocusTest.App, width: 20, height: 5)
      Terra.Test.send_keys(machine, [:tab])

      assert machine |> Terra.Test.render() |> String.contains?("first")

      view = Terra.FocusTest.App.view(%{focus: :first})
      placements = Terra.View.place(view, {0, 0}, {20, 5})

      assert Enum.any?(placements, fn {_r, _c, g, s} -> g == "f" and s == [reverse: true] end)
      refute Enum.any?(placements, fn {_r, _c, g, s} -> g == "n" and s == [reverse: true] end)

      Terra.Test.stop(machine)
    end
  end
end

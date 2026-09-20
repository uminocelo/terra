defmodule Terra.WidgetTest.ListApp do
  @moduledoc false
  use Terra

  alias Terra.Widget

  @items ["One", "Two", "Three"]

  def init(_opts), do: %{index: 0, chosen: nil}

  def update({:move, index}, state), do: %{state | index: index}
  def update({:chosen, index}, state), do: %{state | chosen: index}
  def update(:cancel, state), do: {:quit, state}
  def update(_msg, state), do: state

  def event_to_msg(event, state), do: Widget.list_event(event, state.index, length(@items))

  def view(state) do
    box(Widget.list(@items, selected: state.index), title: "Pick")
  end
end

defmodule Terra.WidgetTest.InputApp do
  @moduledoc false
  use Terra

  alias Terra.Widget

  def init(_opts), do: %{value: "", cursor: 0, submitted: nil}

  def update({:edit, value, cursor}, state), do: %{state | value: value, cursor: cursor}
  def update({:submit, value}, state), do: %{state | submitted: value}
  def update(:cancel, state), do: {:quit, state}
  def update(_msg, state), do: state

  def event_to_msg(event, state), do: Widget.input_event(event, state.value, state.cursor)

  def view(state) do
    box(hstack([text("> "), Widget.input(state.value, cursor: state.cursor)]))
  end
end

defmodule Terra.WidgetTest do
  use ExUnit.Case, async: true

  alias Terra.Widget
  alias Terra.{Renderer, View}

  defp text(view, width \\ 24, height \\ 4) do
    view |> Renderer.render(width: width, height: height) |> Renderer.to_text()
  end

  describe "list/2" do
    test "marks and highlights the selected row" do
      snapshot = text(Widget.list(["One", "Two", "Three"], selected: 1))

      assert snapshot == "  One\n\u203A Two\n  Three"
    end

    test "the window scrolls so the selection stays visible at a fixed height" do
      view = View.box(Widget.list(["a", "b", "c", "d"], selected: 3, height: 2))
      snapshot = text(view, 8, 4)

      assert snapshot == """
             \u250C──────\u2510
             │  c   │
             │\u203A d   │
             \u2514──────\u2518\
             """

      refute snapshot =~ "a"
      refute snapshot =~ "b"
    end

    test "a fixed height keeps the top rows when the selection is near the start" do
      snapshot = text(Widget.list(["a", "b", "c", "d"], selected: 0, height: 2), 8, 2)
      assert snapshot == "\u203A a\n  b"
    end

    test "an unfocused list underlines instead of reversing" do
      placements =
        View.place(Widget.list(["a", "b"], selected: 0, focused: false), {0, 0}, {8, 2})

      assert Enum.any?(placements, fn {_r, _c, g, s} -> g == "a" and s == [underline: true] end)
      refute Enum.any?(placements, fn {_r, _c, _g, s} -> s == [reverse: true] end)
    end
  end

  describe "list_event/3" do
    test "moves with arrows and j/k, wrapping at both ends" do
      assert Widget.list_event(:down, 0, 3) == {:move, 1}
      assert Widget.list_event(:up, 0, 3) == {:move, 2}
      assert Widget.list_event({:char, "j"}, 2, 3) == {:move, 0}
      assert Widget.list_event({:char, "k"}, 2, 3) == {:move, 1}
      assert Widget.move_index(0, 0, :down) == 0
    end

    test "emits chosen and cancel as data" do
      assert Widget.list_event(:enter, 2, 3) == {:chosen, 2}
      assert Widget.list_event(:esc, 0, 3) == :cancel
      assert Widget.list_event(:tab, 0, 3) == :ignore
    end
  end

  describe "progress/2" do
    test "a 0..1 value fills proportionally" do
      assert text(Widget.progress(0.5, width: 10), 10, 1) == "█████░░░░░"
      assert text(Widget.progress(0.0, width: 10), 10, 1) == "░░░░░░░░░░"
      assert text(Widget.progress(1.0, width: 10), 10, 1) == "██████████"
    end

    test "a 0..100 range needs :max" do
      assert text(Widget.progress(25, max: 100, width: 8), 8, 1) == "██░░░░░░"
      assert Widget.progress_percent(25, max: 100) == 25
      assert Widget.progress_percent(0.42) == 42
    end

    test "out-of-range values are clamped" do
      assert text(Widget.progress(-1, width: 4), 4, 1) == "░░░░"
      assert text(Widget.progress(2, width: 4), 4, 1) == "████"
      assert Widget.progress_percent(5, max: 0) == 0
    end
  end

  describe "spinner/2" do
    test "advances a frame per tick and wraps" do
      assert Widget.spinner_frame(0) == "|"
      assert Widget.spinner_frame(1) == "/"
      assert Widget.spinner_frame(2) == "-"
      assert Widget.spinner_frame(3) == "\\"
      assert Widget.spinner_frame(4) == "|"

      assert text(Widget.spinner(1), 2, 1) == "/"
    end

    test "accepts custom frames" do
      assert Widget.spinner_frame(1, frames: ["a", "b"]) == "b"
      assert Widget.spinner_frame(3, frames: ["a", "b"]) == "b"
    end
  end

  describe "input/2" do
    test "renders the value with a cursor cell at the position" do
      placements = View.place(Widget.input("ab", cursor: 1), {0, 0}, {4, 1})

      assert Enum.any?(placements, fn {_r, _c, g, s} -> g == "b" and s == [reverse: true] end)
      assert text(Widget.input("ab", cursor: 1), 4, 1) == "ab"
    end

    test "shows the placeholder when empty and unfocused shows plain text" do
      assert text(Widget.input("", placeholder: "type"), 8, 1) == "type"
      assert text(Widget.input("hi", focused: false), 4, 1) == "hi"
    end

    test "the default cursor is at the end" do
      assert Widget.cursor("abc") == 3
      assert Widget.cursor("abc", cursor: 1) == 1

      placements = View.place(Widget.input("abc"), {0, 0}, {6, 1})
      refute Enum.any?(placements, fn {_r, _c, g, s} -> g == "c" and s == [reverse: true] end)
    end
  end

  describe "input_event/3" do
    test "inserts, deletes and moves the cursor" do
      assert Widget.input_event({:char, "a"}, "", 0) == {:edit, "a", 1}
      assert Widget.input_event({:char, "b"}, "a", 1) == {:edit, "ab", 2}
      assert Widget.input_event(:backspace, "ab", 2) == {:edit, "a", 1}
      assert Widget.input_event(:backspace, "ab", 0) == {:edit, "ab", 0}
      assert Widget.input_event(:left, "ab", 2) == {:edit, "ab", 1}
      assert Widget.input_event(:right, "ab", 0) == {:edit, "ab", 1}
      assert Widget.input_event(:left, "ab", 0) == {:edit, "ab", 0}
      assert Widget.input_event(:right, "ab", 2) == {:edit, "ab", 2}
    end

    test "submits on enter and cancels on escape" do
      assert Widget.input_event(:enter, "hi", 2) == {:submit, "hi"}
      assert Widget.input_event(:esc, "hi", 2) == :cancel
      assert Widget.input_event(:up, "hi", 2) == :ignore
    end

    test "editing helpers work on graphemes, not bytes" do
      assert Widget.insert("", 0, "\u65E5") == {"\u65E5", 1}
      assert Widget.backspace("\u65E5", 1) == {"", 0}
      assert Widget.insert("a\u65E5", 2, "b") == {"a\u65E5b", 3}
    end
  end

  describe "widgets in a headless app" do
    test "list moves with key sequences and reports the choice" do
      machine = Terra.Test.start(Terra.WidgetTest.ListApp, width: 12, height: 5)

      Terra.Test.send_keys(machine, "jj")
      assert Terra.Test.state(machine).index == 2
      assert Terra.Test.render(machine) =~ "\u203A Three"

      Terra.Test.send_keys(machine, [:up])
      assert Terra.Test.state(machine).index == 1

      Terra.Test.send_keys(machine, [:enter])
      assert Terra.Test.state(machine).chosen == 1

      Terra.Test.stop(machine)
    end

    test "a list cancel quits the app" do
      machine = Terra.Test.start(Terra.WidgetTest.ListApp, width: 12, height: 5)
      ref = Process.monitor(machine)

      Terra.Test.send_keys(machine, [:esc])
      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
    end

    test "the input widget edits with key sequences and submits on enter" do
      machine = Terra.Test.start(Terra.WidgetTest.InputApp, width: 20, height: 3)

      Terra.Test.send_keys(machine, "hi")
      assert Terra.Test.state(machine).value == "hi"
      assert Terra.Test.state(machine).cursor == 2

      Terra.Test.send_keys(machine, [:backspace])
      assert Terra.Test.state(machine).value == "h"

      Terra.Test.send_keys(machine, [:left])
      assert Terra.Test.state(machine).cursor == 0

      Terra.Test.send_keys(machine, "X")
      assert Terra.Test.state(machine).value == "Xh"

      Terra.Test.send_keys(machine, [:enter])
      assert Terra.Test.state(machine).submitted == "Xh"

      Terra.Test.stop(machine)
    end

    test "an input cancel quits the app" do
      machine = Terra.Test.start(Terra.WidgetTest.InputApp, width: 20, height: 3)
      ref = Process.monitor(machine)

      Terra.Test.send_keys(machine, [:esc])
      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
    end
  end
end

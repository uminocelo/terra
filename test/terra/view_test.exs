defmodule Terra.ViewTest do
  use ExUnit.Case, async: true

  alias Terra.View
  alias Terra.Width

  describe "measure/1" do
    test "text uses the widest line and the line count" do
      assert View.measure(View.text("hello")) == {5, 1}
      assert View.measure(View.text("a\nbc")) == {2, 2}
      assert View.measure(View.text("")) == {0, 1}
      assert View.measure(View.text("hi", fg: :green, bold: true)) == {2, 1}
    end

    test "text width counts cells, not codepoints" do
      assert View.measure(View.text("日本")) == {4, 1}
      assert Width.string("日本") == 4
      assert Width.string("e\u0301") == 1
    end

    test "vstack and hstack sum their children" do
      assert View.measure(View.vstack([View.text("ab"), View.text("c")])) == {2, 2}
      assert View.measure(View.vstack([View.text("ab"), View.text("c")], gap: 1)) == {2, 3}
      assert View.measure(View.hstack([View.text("ab"), View.text("c")])) == {3, 1}
      assert View.measure(View.hstack([View.text("ab"), View.text("c")], gap: 1)) == {4, 1}
    end

    test "box adds border and padding" do
      assert View.measure(View.box(View.text("hi"))) == {4, 3}
      assert View.measure(View.box(View.text("hi"), border: false)) == {2, 1}
      assert View.measure(View.box(View.text("hi"), padding: 1)) == {6, 5}
      assert View.measure(View.box(View.text("hi"), padding: [top: 1, left: 2])) == {6, 4}
    end

    test "fixed sizes override the natural size" do
      assert View.measure(View.vstack([View.text("ab")], width: 10, height: 4)) == {10, 4}
      assert View.measure(View.box(View.text("ab"), width: 8, height: 5)) == {8, 5}
    end
  end

  describe "place/3" do
    test "text places graphemes left to right" do
      placements = View.place(View.text("ab"), {0, 0}, {5, 1})
      assert placements == [{0, 0, "a", []}, {0, 1, "b", []}]
    end

    test "text places later lines on later rows" do
      placements = View.place(View.text("a\nb"), {2, 3}, {5, 2})
      assert placements == [{2, 3, "a", []}, {3, 3, "b", []}]
    end

    test "content wider or taller than the area is clipped, not wrapped or crashed" do
      assert View.place(View.text("abcdef"), {0, 0}, {3, 1}) == [
               {0, 0, "a", []},
               {0, 1, "b", []},
               {0, 2, "c", []}
             ]

      assert View.place(View.text("a\nb\nc"), {0, 0}, {1, 2}) == [
               {0, 0, "a", []},
               {1, 0, "b", []}
             ]
    end

    test "wide graphemes advance two columns" do
      placements = View.place(View.text("日本"), {0, 0}, {10, 1})
      assert placements == [{0, 0, "日", []}, {0, 2, "本", []}]
    end

    test "a wide grapheme that would straddle the edge is dropped" do
      placements = View.place(View.text("a日"), {0, 0}, {2, 1})
      assert placements == [{0, 0, "a", []}]
    end

    test "vstack align centers children horizontally" do
      view = View.vstack([View.text("a"), View.text("abc")], align: :center)
      placements = View.place(view, {0, 0}, {5, 2})

      assert {0, 2, "a", []} in placements
      assert {1, 1, "a", []} in placements
    end

    test "vstack gap and right alignment" do
      view = View.vstack([View.text("a"), View.text("b")], gap: 1, align: :right)
      placements = View.place(view, {0, 0}, {4, 4})
      assert {0, 3, "a", []} in placements
      assert {2, 3, "b", []} in placements
    end

    test "hstack align places children vertically" do
      view =
        View.hstack([View.text("a"), View.vstack([View.text("a"), View.text("b")])],
          align: :bottom
        )

      placements = View.place(view, {0, 0}, {4, 3})

      assert {2, 0, "a", []} in placements
      assert {1, 1, "a", []} in placements
      assert {2, 1, "b", []} in placements
    end

    test "box draws a border, then padding, then content" do
      placements = View.place(View.box(View.text("hi"), padding: 1), {0, 0}, {6, 5})

      assert {0, 0, "┌", [fg: :border]} in placements
      assert {0, 5, "┐", [fg: :border]} in placements
      assert {4, 0, "└", [fg: :border]} in placements
      assert {4, 5, "┘", [fg: :border]} in placements
      assert {0, 1, "─", [fg: :border]} in placements
      assert {1, 0, "│", [fg: :border]} in placements

      content = Enum.filter(placements, fn {_r, _c, g, _s} -> g == "h" end)
      assert content == [{2, 2, "h", []}]
    end

    test "box align and valign place content inside the inner area" do
      view = View.box(View.text("x"), width: 5, height: 5, align: :center, valign: :center)
      placements = View.place(view, {0, 0}, {5, 5})

      assert {2, 2, "x", []} in placements

      bottom = View.box(View.text("x"), width: 5, height: 5, valign: :bottom, align: :right)
      assert {3, 3, "x", []} in View.place(bottom, {0, 0}, {5, 5})
    end

    test "a box smaller than 2x2 drops the border" do
      placements = View.place(View.box(View.text("x")), {0, 0}, {1, 1})
      refute Enum.any?(placements, fn {_r, _c, g, _s} -> g in ["┌", "─", "│"] end)
    end

    test "nested vstack-in-box-in-hstack is deterministic" do
      view =
        View.hstack([
          View.box(View.vstack([View.text("a"), View.text("b")])),
          View.text("c")
        ])

      first = View.place(view, {0, 0}, {20, 5})
      second = View.place(view, {0, 0}, {20, 5})
      assert first == second

      texts = Enum.filter(first, fn {_r, _c, g, _s} -> g in ["a", "b", "c"] end)
      assert texts == [{1, 1, "a", []}, {2, 1, "b", []}, {0, 3, "c", []}]
    end

    test "placement never escapes the area" do
      view = View.box(View.vstack([View.text("abcdef"), View.text("ghijkl")]))
      placements = View.place(view, {0, 0}, {6, 4})

      assert Enum.all?(placements, fn {row, col, _g, _s} ->
               row >= 0 and row < 4 and col >= 0 and col < 6
             end)
    end
  end

  defp top_row(view, width \\ 8) do
    view
    |> Terra.Renderer.render(width: width, height: 3)
    |> Terra.Renderer.to_text()
    |> String.split("\n")
    |> hd()
  end

  describe "border styles" do
    test "at least two styles render differently" do
      single = top_row(View.box(View.text("x"), border: :single))
      double = top_row(View.box(View.text("x"), border: :double))
      rounded = top_row(View.box(View.text("x"), border: :rounded))
      thick = top_row(View.box(View.text("x"), border: :thick))
      ascii = top_row(View.box(View.text("x"), border: :ascii))

      assert single == "\u250C\u2500\u2500\u2500\u2500\u2500\u2500\u2510"
      assert String.first(double) == "\u2554"
      assert String.first(rounded) == "\u256D"
      assert String.first(thick) == "\u250F"
      assert ascii == "+------+"

      assert Enum.uniq([single, double, rounded, thick, ascii]) |> length() == 5
    end

    test "the default border is single" do
      assert top_row(View.box(View.text("x"))) ==
               top_row(View.box(View.text("x"), border: :single))
    end

    test "border: false draws no border" do
      placements = View.place(View.box(View.text("x"), border: false), {0, 0}, {3, 1})
      assert placements == [{0, 0, "x", []}]
    end

    test "an unknown border style falls back to single" do
      assert top_row(View.box(View.text("x"), border: :nope)) ==
               top_row(View.box(View.text("x"), border: :single))
    end
  end

  describe "box titles" do
    test "a title is drawn into the top border" do
      top = top_row(View.box(View.text("x"), title: "Hi"), 10)

      assert top =~ " Hi "
      assert String.starts_with?(top, "\u250C")
      assert String.ends_with?(top, "\u2510")
    end

    test "a title widens the natural size so it fits" do
      assert View.measure(View.box(View.text("x"), title: "Hello")) == {9, 3}
    end

    test "a title is clipped to the box width" do
      placements = View.place(View.box(View.text("x"), title: "Much too long"), {0, 0}, {6, 3})
      title_cells = Enum.filter(placements, fn {row, _col, _g, _s} -> row == 0 end)

      assert Enum.all?(title_cells, fn {_row, col, _g, _s} -> col >= 0 and col < 6 end)

      text =
        title_cells
        |> Enum.sort_by(&elem(&1, 1))
        |> Enum.map_join(fn {_r, _c, g, _s} -> g end)

      refute text =~ "long"
    end

    test "a title on a borderless box is ignored" do
      placements =
        View.place(View.box(View.text("x"), border: false, title: "Hi"), {0, 0}, {6, 1})

      assert placements == [{0, 0, "x", []}]
      assert View.measure(View.box(View.text("x"), border: false, title: "Hi")) == {1, 1}
    end
  end
end

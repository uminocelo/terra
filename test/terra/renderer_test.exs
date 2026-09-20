defmodule Terra.Renderer.CaptureBackend do
  @moduledoc false
  @behaviour Terra.Terminal.Backend

  @name __MODULE__

  def start do
    case Agent.start(fn -> [] end, name: @name) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        Agent.update(@name, fn _writes -> [] end)
        pid
    end
  end

  def stop do
    if Process.whereis(@name), do: Agent.stop(@name)
  end

  def output, do: Agent.get(@name, &(&1 |> Enum.reverse() |> IO.iodata_to_binary()))

  @impl true
  def write(data) do
    Agent.update(@name, &[IO.iodata_to_binary(data) | &1])
    :ok
  end

  @impl true
  def encoding, do: :unicode

  @impl true
  def set_encoding(_encoding), do: :ok

  @impl true
  def terminal?, do: true

  @impl true
  def size, do: {:ok, {80, 24}}

  @impl true
  def enter_raw, do: :ok

  @impl true
  def leave_raw, do: :ok

  @impl true
  def set_isig(_flag), do: :ok
end

defmodule Terra.RendererTest do
  use ExUnit.Case, async: true

  alias Terra.Renderer
  alias Terra.Renderer.{CaptureBackend, Grid, Style}
  alias Terra.Terminal
  alias Terra.Terminal.ANSI
  alias Terra.View

  describe "render/2" do
    test "paints a view into a grid of the requested size" do
      grid = Renderer.render(View.text("hi"), width: 5, height: 2)

      assert grid.width == 5
      assert grid.height == 2
      assert Grid.get(grid, 0, 0).grapheme == "h"
      assert Grid.get(grid, 0, 1).grapheme == "i"
      assert Grid.get(grid, 1, 0) == Grid.empty_cell()
    end

    test "defaults to the terminal size" do
      CaptureBackend.start()

      on_exit(fn ->
        Terminal.exit()
        CaptureBackend.stop()
      end)

      Terminal.start(backend: CaptureBackend)

      grid = Renderer.render(View.text("hi"))
      assert {grid.width, grid.height} == {80, 24}
    end

    test "the same view renders to the same grid" do
      view = View.box(View.vstack([View.text("a"), View.text("b")]), padding: 1)

      assert Renderer.render(view, width: 20, height: 10) ==
               Renderer.render(view, width: 20, height: 10)
    end
  end

  describe "to_text/1 snapshots" do
    test "renders a boxed frame as plain text" do
      view = View.box(View.vstack([View.text("Hi"), View.text("bye")]))
      snapshot = view |> Renderer.render(width: 8, height: 5) |> Renderer.to_text()

      assert snapshot == """
             ┌──────┐
             │Hi    │
             │bye   │
             │      │
             └──────┘\
             """
    end

    test "trailing blank lines are trimmed" do
      snapshot = View.text("hi") |> Renderer.render(width: 10, height: 4) |> Renderer.to_text()
      assert snapshot == "hi"
    end

    test "wide graphemes occupy their continuation cell once" do
      grid = Renderer.render(View.text("日本"), width: 6, height: 1)
      assert Grid.get(grid, 0, 0).wide
      assert Grid.get(grid, 0, 1).continuation
      assert Grid.get(grid, 0, 2).grapheme == "本"
      assert Renderer.to_text(grid) == "日本"
    end

    test "a nested layout is deterministic across renders" do
      view =
        View.hstack([
          View.box(View.vstack([View.text("left"), View.text("!")])),
          View.box(View.text("right"))
        ])

      one = view |> Renderer.render(width: 24, height: 6) |> Renderer.to_text()
      two = view |> Renderer.render(width: 24, height: 6) |> Renderer.to_text()
      assert one == two
    end
  end

  describe "patch/2" do
    test "a nil previous frame paints fully" do
      grid = View.text("hi") |> Renderer.render(width: 3, height: 2)
      patch = Renderer.patch(nil, grid)

      assert String.starts_with?(patch, ANSI.clear() <> ANSI.home())
      assert patch == ANSI.clear() <> ANSI.home() <> Renderer.to_ansi(grid)
    end

    test "identical frames produce an empty patch" do
      grid = View.text("hi") |> Renderer.render(width: 8, height: 3)
      assert Renderer.patch(grid, grid) == ""
    end

    test "references to the same grid differ only when a cell changes" do
      before = View.text("hi") |> Renderer.render(width: 8, height: 3)
      after_ = View.text("ho") |> Renderer.render(width: 8, height: 3)

      assert Renderer.patch(before, after_) == ANSI.move(1, 2) <> "o"
    end

    test "a change on a later row includes just that cell and the cursor move" do
      before =
        View.vstack([View.text("aa"), View.text("bb")]) |> Renderer.render(width: 4, height: 2)

      after_ =
        View.vstack([View.text("aa"), View.text("bc")]) |> Renderer.render(width: 4, height: 2)

      assert Renderer.patch(before, after_) == ANSI.move(2, 2) <> "c"
    end

    test "unchanged cells produce no writes" do
      before = View.text("keep me still") |> Renderer.render(width: 20, height: 1)
      after_ = View.text("keep me stilX") |> Renderer.render(width: 20, height: 1)

      patch = Renderer.patch(before, after_)

      refute patch =~ "keep"
      refute patch =~ "me"
      assert patch == ANSI.move(1, 13) <> "X"
    end

    test "adjacent changed cells reuse one cursor move" do
      before = View.text("aaaa") |> Renderer.render(width: 6, height: 1)
      after_ = View.text("aXXa") |> Renderer.render(width: 6, height: 1)

      assert Renderer.patch(before, after_) == ANSI.move(1, 2) <> "XX"
    end

    test "a size change falls back to a full paint" do
      before = View.text("hi") |> Renderer.render(width: 8, height: 3)
      after_ = View.text("hi") |> Renderer.render(width: 4, height: 2)

      assert String.starts_with?(Renderer.patch(before, after_), ANSI.clear() <> ANSI.home())
    end

    test "styles are re-emitted for a changed styled cell" do
      before = View.text("hi") |> Renderer.render(width: 4, height: 1)

      after_ =
        View.hstack([View.text("h"), View.text("!", fg: :red)])
        |> Renderer.render(width: 4, height: 1)

      patch = Renderer.patch(before, after_)

      assert patch == ANSI.move(1, 2) <> Style.to_ansi(fg: :red) <> "!" <> ANSI.reset()
    end

    test "a wide grapheme change writes the wide cell, not its continuation" do
      before = View.text("ab") |> Renderer.render(width: 6, height: 1)
      after_ = View.text("日本") |> Renderer.render(width: 6, height: 1)

      patch = Renderer.patch(before, after_)

      assert patch =~ "日"
      assert patch =~ "本"
      assert String.graphemes(patch) |> Enum.filter(&(&1 == "本")) |> length() == 1
    end
  end

  describe "to_ansi/1" do
    test "moves to each row and writes the cells" do
      ansi = View.text("hi") |> Renderer.render(width: 3, height: 2) |> Renderer.to_ansi()

      assert String.starts_with?(ansi, ANSI.move(1, 1))
      assert ansi =~ "hi "
      assert ansi =~ ANSI.move(2, 1)
    end

    test "styles are emitted as SGR codes and reset" do
      view = View.text("hi", fg: :green, bold: true)
      ansi = view |> Renderer.render(width: 3, height: 1) |> Renderer.to_ansi()

      assert ansi =~ Style.to_ansi(fg: :green, bold: true)
      assert ansi =~ ANSI.reset()
      assert Style.to_ansi(fg: :green, bold: true) == "\e[32;1m"
    end

    test "a style survives a round-trip into the grid" do
      style = [fg: :red, bg: 200, underline: true]
      grid = Renderer.render(View.text("x", style), width: 2, height: 1)

      assert Grid.get(grid, 0, 0).style == style
      assert Style.normalize(Grid.get(grid, 0, 0).style) == "\e[31;48;5;200;4m"
    end

    test "unknown style keys are ignored" do
      assert Style.to_ansi(rainbow: true) == ""
      assert Style.to_ansi(fg: :not_a_colour) == ""
      assert Style.to_ansi(fg: 256) == ""
      assert Style.to_ansi([]) == ""
    end
  end

  describe "frame/2" do
    test "starts with clear and home, then the paint" do
      frame = Renderer.frame(View.text("hi"), width: 4, height: 2)

      assert String.starts_with?(frame, ANSI.clear() <> ANSI.home())
      assert frame =~ "hi"
    end
  end

  describe "paint/2" do
    setup do
      CaptureBackend.start()
      Terminal.start(backend: CaptureBackend)

      on_exit(fn ->
        Terminal.exit()
        CaptureBackend.stop()
      end)

      :ok
    end

    test "writes clear, home and the frame through Terra.Terminal" do
      assert {:ok, bytes} = Renderer.paint(View.box(View.text("hi")), width: 6, height: 3)

      output = CaptureBackend.output()
      assert output =~ ANSI.clear()
      assert output =~ ANSI.home()
      assert output =~ "hi"
      assert output =~ "┌"
      assert bytes == Renderer.frame(View.box(View.text("hi")), width: 6, height: 3)
    end

    test "a full redraw writes the same bytes every time" do
      view = View.text("hi")
      opts = [width: 4, height: 2]

      assert {:ok, first} = Renderer.paint(view, opts)
      assert {:ok, second} = Renderer.paint(view, opts)
      assert first == second
    end
  end

  describe "benchmark" do
    @tag :benchmark
    test "an 80x24 styled frame stays far under the 5 ms budget" do
      view =
        View.box(
          View.vstack(
            for i <- 1..20 do
              View.hstack([View.text("row #{i}", fg: :green), View.text("  ok", dim: true)])
            end
          )
        )

      frames = 50

      {microseconds, _} =
        :timer.tc(fn ->
          for _ <- 1..frames, do: Renderer.frame(view, width: 80, height: 24)
        end)

      average_ms = microseconds / frames / 1000
      assert average_ms < 5
    end
  end

  describe "wide graphemes" do
    @wide "\u65E5"
    @wide2 "\u672C"

    test "a wide grapheme owns its cell and marks the next as a continuation" do
      grid = Renderer.render(View.text(@wide), width: 4, height: 1)

      assert Grid.get(grid, 0, 0).grapheme == @wide
      assert Grid.get(grid, 0, 0).wide
      assert Grid.get(grid, 0, 1).continuation
      assert Grid.get(grid, 0, 1).grapheme == " "
      refute Grid.get(grid, 0, 1).wide
      assert Renderer.to_text(grid) == @wide
    end

    test "two wide graphemes take four cells, each with its own continuation" do
      grid = Renderer.render(View.text(@wide <> @wide2), width: 6, height: 1)

      assert Grid.get(grid, 0, 0).grapheme == @wide
      assert Grid.get(grid, 0, 1).continuation
      assert Grid.get(grid, 0, 2).grapheme == @wide2
      assert Grid.get(grid, 0, 3).continuation
      assert Grid.get(grid, 0, 4) == Grid.empty_cell()
      assert Renderer.to_text(grid) == @wide <> @wide2
    end

    test "narrow text after a wide grapheme starts at the next free cell" do
      view = View.hstack([View.text(@wide), View.text("x")])

      assert View.place(view, {0, 0}, {6, 1}) == [
               {0, 0, @wide, []},
               {0, 2, "x", []}
             ]

      assert Renderer.render(view, width: 6, height: 1) |> Renderer.to_text() == @wide <> "x"
    end

    test "a wide grapheme is dropped when it would straddle the edge" do
      assert Renderer.render(View.text("a" <> @wide), width: 2, height: 1) |> Renderer.to_text() ==
               "a"

      assert Renderer.render(View.text("a" <> @wide), width: 3, height: 1) |> Renderer.to_text() ==
               "a" <> @wide

      assert Renderer.render(View.text(@wide), width: 1, height: 1) |> Renderer.to_text() == ""
    end

    test "the diff writes a wide grapheme once and skips its continuation" do
      before = View.text("xx") |> Renderer.render(width: 4, height: 1)
      after_ = View.text(@wide) |> Renderer.render(width: 4, height: 1)

      assert Renderer.patch(before, after_) == ANSI.move(1, 1) <> @wide
    end

    test "a wide grapheme in a box does not overwrite the border" do
      view = View.box(View.text(@wide <> @wide2))
      snapshot = Renderer.render(view, width: 6, height: 3) |> Renderer.to_text()

      assert snapshot == """
             \u250C────\u2510
             │日本│
             └────┘\
             """
    end
  end
end

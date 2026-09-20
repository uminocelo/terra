defmodule Terra.ThemeTest do
  use ExUnit.Case, async: true

  alias Terra.{Renderer, Theme, View}

  describe "default/0 and normalize/1" do
    test "the default theme resolves every token to nothing" do
      assert Theme.default() == %{fg: nil, bg: nil, accent: :cyan, border: nil}
      assert Theme.resolve_style([fg: :border], Theme.default()) == []
      assert Theme.resolve_style([fg: :accent], Theme.default()) == [fg: :cyan]
    end

    test "normalize fills missing keys from the default" do
      assert Theme.normalize(%{accent: :red}) == %{fg: nil, bg: nil, accent: :red, border: nil}
      assert Theme.normalize(accent: :red) == %{fg: nil, bg: nil, accent: :red, border: nil}
      assert Theme.normalize(nil) == Theme.default()
    end

    test "get reads one key" do
      assert Theme.get(%{border: :blue}, :border) == :blue
      assert Theme.get(nil, :accent) == :cyan
    end
  end

  describe "resolve_style/2" do
    test "leaves concrete colors and attributes alone" do
      style = [fg: :green, bg: 200, bold: true, underline: true]

      assert Theme.resolve_style(style, %{}) == style
      assert Theme.resolve_style(style, nil) == style
    end

    test "resolves theme tokens from the map" do
      theme = %{accent: :magenta, border: :blue, fg: :white, bg: :black}

      assert Theme.resolve_style([fg: :accent], theme) == [fg: :magenta]
      assert Theme.resolve_style([fg: :border], theme) == [fg: :blue]
      assert Theme.resolve_style([bg: :accent], theme) == [bg: :magenta]
      assert Theme.resolve_style([fg: :fg], theme) == [fg: :white]
    end

    test "drops a token the theme has no value for" do
      assert Theme.resolve_style([fg: :border, bold: true], %{}) == [bold: true]
      assert Theme.resolve_style([fg: nil], %{}) == []
    end
  end

  describe "the renderer reads the theme" do
    defp ansi(view, opts) do
      view |> Renderer.render(opts) |> Renderer.to_ansi()
    end

    test "no theme and the default theme render the same bytes" do
      view = View.box(View.text("hi", fg: :accent))

      assert ansi(view, width: 10, height: 3) ==
               ansi(view, width: 10, height: 3, theme: Theme.default())
    end

    test "accent text picks up the theme accent" do
      view = View.text("hi", fg: :accent)

      assert ansi(view, width: 4, height: 1) =~ "\e[36m"
      assert ansi(view, width: 4, height: 1, theme: %{accent: :red}) =~ "\e[31m"
    end

    test "borders pick up the theme border color" do
      view = View.box(View.text("x"))

      refute ansi(view, width: 6, height: 3) =~ "\e[34m"
      assert ansi(view, width: 6, height: 3, theme: %{border: :blue}) =~ "\e[34m"
    end

    test "a themed border keeps the box glyphs and the reset" do
      ansi = ansi(View.box(View.text("x")), width: 6, height: 3, theme: %{border: :blue})

      assert ansi =~ "\u250C"
      assert ansi =~ "\e[34m"
      assert ansi =~ "\e[0m"
    end

    test "widgets read the map too" do
      bar = Terra.Widget.progress(1.0, width: 4)

      assert ansi(bar, width: 4, height: 1) =~ "\e[36m"
      assert ansi(bar, width: 4, height: 1, theme: %{accent: :yellow}) =~ "\e[33m"
    end

    test "Terra.Test.render/2 forwards the theme" do
      view = View.text("hi")

      assert Terra.Test.render(view, width: 4, height: 1) ==
               Terra.Test.render(view, width: 4, height: 1, theme: %{fg: :red})
    end
  end
end

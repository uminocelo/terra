defmodule Terra.Renderer.Style do
  @moduledoc """
  Turns a style keyword list into ANSI SGR codes.

  Pure data, no IO. Styles are normalized to a fixed order (foreground, background,
  then attributes) so the same style always produces the same bytes, which is what
  makes renderer snapshots stable.

  Supported keys:

  - `:fg` / `:bg` with a named colour (`:black` .. `:white`, `:bright_*`) or an
    integer `0..255` for the 256-colour palette
  - `:bold`, `:dim`, `:italic`, `:underline`, `:reverse`

  Unknown keys and invalid values are ignored rather than raising, so a bad style
  cannot take down a frame.
  """

  @named %{
    black: 30,
    red: 31,
    green: 32,
    yellow: 33,
    blue: 34,
    magenta: 35,
    cyan: 36,
    white: 37,
    bright_black: 90,
    bright_red: 91,
    bright_green: 92,
    bright_yellow: 93,
    bright_blue: 94,
    bright_magenta: 95,
    bright_cyan: 96,
    bright_white: 97
  }

  @attributes %{bold: 1, dim: 2, italic: 3, underline: 4, reverse: 7}

  @doc """
  Returns the SGR sequence for a style, or an empty binary when there is nothing to
  set.
  """
  @spec to_ansi(keyword) :: binary
  def to_ansi(style) when is_list(style) do
    codes =
      Enum.flat_map([foreground(style), background(style), attributes(style)], & &1)

    case codes do
      [] -> ""
      codes -> "\e[" <> Enum.join(codes, ";") <> "m"
    end
  end

  @doc "Returns a normalized, comparable key for a style."
  @spec normalize(keyword) :: binary
  def normalize(style) when is_list(style), do: to_ansi(style)

  defp foreground(style), do: colour(:fg, Keyword.get(style, :fg), 0)
  defp background(style), do: colour(:bg, Keyword.get(style, :bg), 10)

  defp colour(_key, nil, _offset), do: []

  defp colour(:fg, value, _offset) when is_integer(value) and value in 0..255,
    do: ["38;5;#{value}"]

  defp colour(:bg, value, _offset) when is_integer(value) and value in 0..255,
    do: ["48;5;#{value}"]

  defp colour(_key, value, offset) when is_atom(value) do
    case Map.get(@named, value) do
      nil -> []
      code -> [Integer.to_string(code + offset)]
    end
  end

  defp colour(_key, _value, _offset), do: []

  defp attributes(style) do
    @attributes
    |> Enum.filter(fn {key, _code} -> Keyword.get(style, key) == true end)
    |> Enum.map(fn {_key, code} -> Integer.to_string(code) end)
  end
end

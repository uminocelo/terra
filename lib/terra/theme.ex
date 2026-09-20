defmodule Terra.Theme do
  @moduledoc """
  A small color map that views read at render time.

  A theme is a plain map with four keys:

  | Key | Meaning |
  | --- | --- |
  | `:fg` | default foreground (nil means the terminal default) |
  | `:bg` | default background (nil means the terminal default) |
  | `:accent` | highlight color, used by `fg: :accent` |
  | `:border` | box border color, used by `Terra.View`'s borders |

  Values are the same as anywhere else: a named color (`:red`, `:bright_cyan`), a
  `0..255` palette index, or `nil` for "leave it to the terminal".

  Primitives read the map by using a key as a style value:

      text("hi", fg: :accent)
      box(content, border: :double)     # borders use :border

  `resolve_style/2` turns those tokens into concrete colors, dropping a style entry
  when the theme has `nil` for it. That is why the default theme changes nothing:

      Terra.Theme.default()
      #=> %{fg: nil, bg: nil, accent: :cyan, border: nil}
  """

  @default %{fg: nil, bg: nil, accent: :cyan, border: nil}
  @tokens [:fg, :bg, :accent, :border]

  @type t :: %{
          fg: term,
          bg: term,
          accent: term,
          border: term
        }

  @doc "The theme used when none is configured. Every token resolves to nothing."
  @spec default() :: t
  def default, do: @default

  @doc "Fills in any missing keys from the default theme. Accepts a map, keyword, or nil."
  @spec normalize(t | keyword | nil) :: t
  def normalize(nil), do: @default
  def normalize(theme) when is_map(theme), do: Map.merge(@default, theme)
  def normalize(theme) when is_list(theme), do: Map.merge(@default, Map.new(theme))

  @doc "Reads one theme key."
  @spec get(t | keyword | nil, atom) :: term
  def get(theme, key), do: normalize(theme) |> Map.get(key)

  @doc """
  Resolves theme tokens in a style keyword list.

  An entry whose value is `:fg`, `:bg`, `:accent` or `:border` is replaced by that
  theme color; when the theme value is `nil` the entry is dropped. Everything else
  passes through untouched.
  """
  @spec resolve_style(keyword, t | keyword | nil) :: keyword
  def resolve_style(style, theme) when is_list(style) do
    theme = normalize(theme)

    Enum.flat_map(style, fn
      {_key, nil} ->
        []

      {key, value} when value in @tokens ->
        case Map.get(theme, value) do
          nil -> []
          resolved -> [{key, resolved}]
        end

      entry ->
        [entry]
    end)
  end
end

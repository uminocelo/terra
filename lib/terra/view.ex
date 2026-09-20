defmodule Terra.View do
  @moduledoc """
  Layout primitives: plain data, measured and placed with no terminal involved.

  A view is a tagged tuple. Building one touches nothing: `text/2`, `vstack/2`,
  `hstack/2` and `box/2` just assemble data. `measure/1` returns the natural size in
  cells, and `place/3` turns a view into a flat list of placements for a renderer:

      {row, col, grapheme, style}

  Rows and columns are 0-based, so a renderer only has to offset them by one for
  ANSI. Placement clips to the available area: content that does not fit is
  dropped, never wrapped or crashed on.

  ## Primitives

      text("hi", fg: :green)
      vstack([a, b], gap: 1)
      hstack([left, right], align: :center)
      box(content, padding: 1, align: :center)

  Options:

  | Option | Primitives | Meaning |
  | --- | --- | --- |
  | `:width`, `:height` | all | fixed size, overriding the natural one |
  | `:gap` | stacks | blank cells between children (default 0) |
  | `:align` | `vstack`, `box` | horizontal: `:left`, `:center`, `:right` |
  | `:align` | `hstack` | vertical: `:top`, `:center`, `:bottom` |
  | `:valign` | `box` | vertical placement of content: `:top`, `:center`, `:bottom` |
  | `:padding` | `box` | integer or `[top:, right:, bottom:, left:]`, default 0 |
  | `:border` | `box` | `:single` (default), `:double`, `:rounded`, `:thick`, `:ascii`, or `false` |
  | `:title` | `box` | a label placed on the top border |

  `box/1` accepts one view or a list; a list is stacked vertically, so
  `box([a, b])` is `box(vstack([a, b]))`. A `:title` is drawn into the top border
  and widens the natural size when it would not otherwise fit. Borders are dropped
  when the box is smaller than 2x2 cells.

  A box is placed in the area it is given, so an unsized root `box` fills the
  whole screen. Give it `:width`/`:height` when you want it compact.
  """

  alias Terra.Width

  @borders %{
    single: {"\u250C", "\u2510", "\u2514", "\u2518", "\u2500", "\u2502"},
    double: {"\u2554", "\u2557", "\u255A", "\u255D", "\u2550", "\u2551"},
    rounded: {"\u256D", "\u256E", "\u2570", "\u256F", "\u2500", "\u2502"},
    thick: {"\u250F", "\u2513", "\u2517", "\u251B", "\u2501", "\u2503"},
    ascii: {"+", "+", "+", "+", "-", "|"}
  }

  @type style :: keyword
  @type t ::
          {:text, binary, style}
          | {:vstack, [t], keyword}
          | {:hstack, [t], keyword}
          | {:box, t, keyword}
          | {:focus, term, t}

  @type placement :: {non_neg_integer, non_neg_integer, binary, style}

  @doc "A single line of plain text."
  @spec text(binary) :: t
  def text(string) when is_binary(string), do: {:text, string, []}

  @doc "Text with a style, e.g. `text(\"hi\", fg: :green, bold: true)`."
  @spec text(binary, style) :: t
  def text(string, style) when is_binary(string) and is_list(style), do: {:text, string, style}

  @doc "Stacks children top to bottom."
  @spec vstack([t]) :: t
  def vstack(children) when is_list(children), do: {:vstack, children, []}

  @doc "Stacks children top to bottom with options."
  @spec vstack([t], keyword) :: t
  def vstack(children, opts) when is_list(children) and is_list(opts),
    do: {:vstack, children, opts}

  @doc "Lays children left to right."
  @spec hstack([t]) :: t
  def hstack(children) when is_list(children), do: {:hstack, children, []}

  @doc "Lays children left to right with options."
  @spec hstack([t], keyword) :: t
  def hstack(children, opts) when is_list(children) and is_list(opts),
    do: {:hstack, children, opts}

  @doc "A bordered container around one view, or around a vertical stack of views."
  @spec box(t | [t]) :: t
  def box(content), do: box(content, [])

  @doc "A bordered container with options."
  @spec box(t | [t], keyword) :: t
  def box(children, opts) when is_list(children) and is_list(opts),
    do: {:box, vstack(children), opts}

  def box(view, opts) when is_list(opts), do: {:box, view, opts}

  @doc """
  Natural size in `{columns, rows}`.

  Fixed `:width`/`:height` options override the natural size.
  """
  @spec measure(t) :: {non_neg_integer, non_neg_integer}
  def measure({:text, string, _style}) do
    lines = lines(string)
    widths = Enum.map(lines, &Width.string/1)
    {Enum.max(widths, fn -> 0 end), length(lines)}
  end

  def measure({:vstack, children, opts}) do
    {width, height} = stack_size(children, :vertical, opts)
    override({width, height}, opts)
  end

  def measure({:hstack, children, opts}) do
    {width, height} = stack_size(children, :horizontal, opts)
    override({width, height}, opts)
  end

  def measure({:focus, _id, child}), do: measure(child)

  def measure({:box, child, opts}) do
    {glyphs, padding} = frame(opts)
    {top, right, bottom, left} = padding
    {cw, ch} = measure(child)
    border = border_width(glyphs)
    width = cw + 2 * border + left + right
    height = ch + 2 * border + top + bottom
    width = if glyphs, do: max(width, title_min_width(opts[:title])), else: width
    override({width, height}, opts)
  end

  @doc """
  Places a view inside the area starting at `{row, col}`, `{width, height}` in size.

  Returns a list of `{row, col, grapheme, style}`. Anything outside the area or the
  view's own fixed size is clipped.
  """
  @spec place(t, {non_neg_integer, non_neg_integer}, {non_neg_integer, non_neg_integer}) ::
          [placement]
  def place(view, {row, col}, {width, height}) do
    do_place(view, row, col, width, height)
  end

  defp do_place({:focus, _id, child}, row, col, width, height),
    do: do_place(child, row, col, width, height)

  defp do_place({:text, string, style}, row, col, width, height) do
    lines(string)
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} -> place_line(line, style, row + index, col, width) end)
    |> Enum.filter(fn {placed_row, _col, _g, _s} -> placed_row < row + height end)
  end

  defp do_place({:vstack, children, opts}, row, col, width, height),
    do: place_vstack(children, opts, row, col, width, height)

  defp do_place({:hstack, children, opts}, row, col, width, height),
    do: place_hstack(children, opts, row, col, width, height)

  defp do_place({:box, child, opts}, row, col, width, height) do
    {glyphs, {top, right, bottom, left}} = frame(opts)
    border = border_width(glyphs)

    inner_row = row + border + top
    inner_col = col + border + left
    inner_width = max(width - 2 * border - left - right, 0)
    inner_height = max(height - 2 * border - top - bottom, 0)
    {cw, ch} = measure(child)

    content_row = align_y(opts[:valign] || :top, inner_row, inner_height, ch)
    content_col = align_x(opts[:align] || :left, inner_col, inner_width, cw)

    border_placements(glyphs, opts[:title], row, col, width, height) ++
      do_place(child, content_row, content_col, inner_width, inner_height)
  end

  defp place_vstack(children, opts, row, col, width, height) do
    gap = gap(opts)
    align = opts[:align] || :left

    {placements, _y} =
      Enum.reduce(children, {[], row}, fn child, {acc, y} ->
        {cw, ch} = measure(child)
        x = align_x(align, col, width, cw)
        remaining = max(height - (y - row), 0)
        {acc ++ do_place(child, y, x, width, remaining), y + ch + gap}
      end)

    placements
  end

  defp place_hstack(children, opts, row, col, width, height) do
    gap = gap(opts)
    align = opts[:align] || :top

    {placements, _x} =
      Enum.reduce(children, {[], col}, fn child, {acc, x} ->
        {cw, ch} = measure(child)
        y = align_y(align, row, height, ch)
        remaining = max(width - (x - col), 0)
        {acc ++ do_place(child, y, x, remaining, height), x + cw + gap}
      end)

    placements
  end

  defp place_line(line, style, row, col, width) do
    right = col + width

    line
    |> String.graphemes()
    |> Enum.reduce({[], col}, fn grapheme, {acc, x} ->
      grapheme_width = Width.grapheme(grapheme)

      if x + grapheme_width > right do
        {acc, x}
      else
        {[{row, x, grapheme, style} | acc], x + grapheme_width}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp stack_size(children, direction, opts) do
    gap = gap(opts)
    sizes = Enum.map(children, &measure/1)

    case sizes do
      [] ->
        {0, 0}

      _ ->
        main =
          Enum.reduce(sizes, 0, fn size, acc -> acc + main_axis(size, direction) end) +
            gap * (length(sizes) - 1)

        cross =
          sizes
          |> Enum.map(&cross_axis(&1, direction))
          |> Enum.max()

        case direction do
          :vertical -> {cross, main}
          :horizontal -> {main, cross}
        end
    end
  end

  defp main_axis({_width, height}, :vertical), do: height
  defp main_axis({width, _height}, :horizontal), do: width
  defp cross_axis({width, _height}, :vertical), do: width
  defp cross_axis({_width, height}, :horizontal), do: height

  defp border_placements(nil, _title, _row, _col, _width, _height), do: []

  defp border_placements(_glyphs, _title, _row, _col, width, height) when width < 2 or height < 2,
    do: []

  defp border_placements(glyphs, title, row, col, width, height) do
    {top_left, top_right, bottom_left, bottom_right, horizontal, vertical} = glyphs
    last_row = row + height - 1
    last_col = col + width - 1

    corners =
      for {r, c, glyph} <- [
            {row, col, top_left},
            {row, last_col, top_right},
            {last_row, col, bottom_left},
            {last_row, last_col, bottom_right}
          ],
          do: {r, c, glyph, [fg: :border]}

    horizontals =
      for x <- inner_range(col + 1, last_col - 1),
          r <- [row, last_row],
          do: {r, x, horizontal, [fg: :border]}

    verticals =
      for y <- inner_range(row + 1, last_row - 1),
          c <- [col, last_col],
          do: {y, c, vertical, [fg: :border]}

    corners ++ horizontals ++ title_placements(title, row, col, width) ++ verticals
  end

  defp title_placements(title, row, col, width) when is_binary(title) and byte_size(title) > 0 do
    last_col = col + width - 1

    (" " <> title <> " ")
    |> String.graphemes()
    |> Enum.reduce({[], col + 2}, fn grapheme, {acc, x} ->
      grapheme_width = Width.grapheme(grapheme)

      if x + grapheme_width > last_col do
        {acc, x}
      else
        {[{row, x, grapheme, [fg: :border]} | acc], x + grapheme_width}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp title_placements(_title, _row, _col, _width), do: []

  defp title_min_width(title) when is_binary(title), do: Width.string(title) + 4
  defp title_min_width(_title), do: 0

  defp border_width(nil), do: 0
  defp border_width(_glyphs), do: 1

  defp inner_range(first, last) when first > last, do: []
  defp inner_range(first, last), do: first..last

  defp lines(string), do: String.split(string, "\n")

  defp gap(opts), do: max(Keyword.get(opts, :gap, 0), 0)

  defp override({width, height}, opts) do
    {Keyword.get(opts, :width, width), Keyword.get(opts, :height, height)}
  end

  defp frame(opts) do
    {border_glyphs(opts), padding(Keyword.get(opts, :padding, 0))}
  end

  defp border_glyphs(opts) do
    case Keyword.get(opts, :border, true) do
      false -> nil
      true -> @borders.single
      style -> Map.get(@borders, style, @borders.single)
    end
  end

  defp padding(value) when is_integer(value) and value >= 0, do: {value, value, value, value}

  defp padding(opts) when is_list(opts) do
    {
      Keyword.get(opts, :top, 0),
      Keyword.get(opts, :right, 0),
      Keyword.get(opts, :bottom, 0),
      Keyword.get(opts, :left, 0)
    }
  end

  defp align_x(:center, x, available, content), do: x + div(max(available - content, 0), 2)
  defp align_x(:right, x, available, content), do: x + max(available - content, 0)
  defp align_x(_left, x, _available, _content), do: x

  defp align_y(:center, y, available, content), do: y + div(max(available - content, 0), 2)
  defp align_y(:bottom, y, available, content), do: y + max(available - content, 0)
  defp align_y(_top, y, _available, _content), do: y
end

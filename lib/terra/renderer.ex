defmodule Terra.Renderer do
  @moduledoc """
  Paints a `Terra.View` frame into a cell grid and out to ANSI.

  A frame is described by two grids: the previous frame and the current one.
  `patch/2` compares them and writes only the cells that changed, each preceded by
  a cursor move when the terminal is not already in the right place. The first
  frame has no previous grid, so `patch(nil, grid)` still clears the screen, homes
  the cursor, and paints every cell.

  ## Sizes

  `:width` and `:height` default to the current terminal size (with the same
  fallbacks as `Terra.Terminal.size/0`: tty, then `COLUMNS`/`LINES`, then 80x24).
  When the size changes between frames, `patch/2` falls back to a full repaint,
  which is also what keeps a shrink from leaving old cells on screen.

  ## Snapshots

  `render/2` returns the grid, `to_ansi/1` the painted ANSI, `frame/2` the clear +
  home + paint sequence, and `to_text/1` a plain-text rendering. The last one is
  what headless tests assert on: no cursor moves, no styles, one line per row with
  trailing blanks trimmed.

      grid = Terra.Renderer.render(box(text("hi")), width: 12, height: 3)
      Terra.Renderer.to_text(grid)

  ## Themes

  `:theme` (a `Terra.Theme` map, or nil for the default) resolves style tokens such
  as `fg: :accent` and the `:border` color used by `Terra.View`'s borders. The
  default theme resolves every token to nothing, so rendering is unchanged.

  ## Painting

  `paint/2` is the only function that touches the terminal, and it goes through
  `Terra.Terminal`'s clear/home helpers so the live path and the escape helpers
  stay in one place. The runtime drives the diffed path with `patch/2`.
  """

  alias Terra.Renderer.{Grid, Style}
  alias Terra.Terminal.ANSI
  alias Terra.{Theme, View}

  @doc """
  Paints `view` into a grid of the requested (or terminal) size.
  """
  @spec render(View.t(), keyword) :: Grid.t()
  def render(view, opts \\ []) do
    {width, height} = size(opts)
    theme = Theme.normalize(Keyword.get(opts, :theme))
    placements = View.place(view, {0, 0}, {width, height})

    Enum.reduce(placements, Grid.new(width, height), fn {row, col, grapheme, style}, grid ->
      Grid.put(grid, row, col, grapheme, Theme.resolve_style(style, theme))
    end)
  end

  @doc """
  Returns the full-redraw byte sequence: clear, home, then every cell.
  """
  @spec frame(View.t(), keyword) :: binary
  def frame(view, opts \\ []) do
    view
    |> render(opts)
    |> to_ansi()
    |> then(&(ANSI.clear() <> ANSI.home() <> &1))
  end

  @doc """
  Paints a full frame to the terminal through `Terra.Terminal`.

  Returns the frame bytes that were written.
  """
  @spec paint(View.t(), keyword) :: {:ok, binary} | {:error, term}
  def paint(view, opts \\ []) do
    grid = render(view, opts)
    bytes = to_ansi(grid)

    with :ok <- Terra.Terminal.clear(),
         :ok <- Terra.Terminal.home() do
      case Terra.Terminal.write(bytes) do
        :ok -> {:ok, ANSI.clear() <> ANSI.home() <> bytes}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns the bytes that turn `previous` into `current`.

  `patch(nil, current)` paints fully: clear, home, then every cell. Otherwise only
  cells that differ are written. Two identical grids of the same size produce an
  empty binary; a size change falls back to a full paint.
  """
  @spec patch(Grid.t() | nil, Grid.t()) :: binary
  def patch(nil, %Grid{} = current), do: ANSI.clear() <> ANSI.home() <> to_ansi(current)

  def patch(%Grid{} = previous, %Grid{} = current) do
    if previous.width != current.width or previous.height != current.height do
      patch(nil, current)
    else
      diff(previous, current)
    end
  end

  @doc "Returns the ANSI bytes for a grid, one cursor move per row."
  @spec to_ansi(Grid.t()) :: binary
  def to_ansi(%Grid{} = grid) do
    0..(grid.height - 1)
    |> Enum.map(fn row -> [ANSI.move(row + 1, 1) | row_ansi(grid, row)] end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns a plain-text snapshot of a grid: one line per row, trailing blanks
  trimmed, trailing blank lines removed.
  """
  @spec to_text(Grid.t()) :: binary
  def to_text(%Grid{} = grid) do
    0..(grid.height - 1)
    |> Enum.map(fn row -> String.trim_trailing(row_text(grid, row)) end)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  @doc """
  Returns the size a render would use.

  The terminal is only queried for the dimensions that were not given, so a call
  with both `:width` and `:height` never touches the terminal at all.
  """
  @spec size(keyword) :: {pos_integer, pos_integer}
  def size(opts \\ []) do
    width = Keyword.get(opts, :width)
    height = Keyword.get(opts, :height)

    if width && height do
      {width, height}
    else
      {columns, rows} = Terra.Terminal.size()
      {width || columns, height || rows}
    end
  end

  defp row_ansi(grid, row) do
    Enum.map(0..(grid.width - 1), fn col -> cell_ansi(grid, row, col) end)
  end

  defp diff(previous, current) do
    {parts, _cursor} =
      Enum.reduce(0..(current.height - 1), {[], :unknown}, fn row, {parts, cursor} ->
        Enum.reduce(0..(current.width - 1), {parts, cursor}, fn col, {parts, cursor} ->
          cell = Grid.get(current, row, col)

          cond do
            cell.continuation -> {parts, cursor}
            Grid.get(previous, row, col) == cell -> {parts, cursor}
            true -> write_cell(parts, cursor, row, col, cell, current.width)
          end
        end)
      end)

    IO.iodata_to_binary(parts)
  end

  defp write_cell(parts, cursor, row, col, cell, width) do
    {move, cursor} = cursor_to(cursor, row, col)
    parts = [parts, move, cell_bytes(cell)]
    {parts, advance(cursor, row, col, cell, width)}
  end

  defp cursor_to({row, col}, row, col), do: {"", {row, col}}

  defp cursor_to(_cursor, row, col), do: {ANSI.move(row + 1, col + 1), {row, col}}

  defp advance(_cursor, row, col, cell, width) do
    next = col + if cell.wide, do: 2, else: 1
    if next >= width, do: :unknown, else: {row, next}
  end

  defp cell_bytes(cell) do
    if cell.style == [] do
      cell.grapheme
    else
      [Style.to_ansi(cell.style), cell.grapheme, ANSI.reset()]
    end
  end

  defp cell_ansi(grid, row, col) do
    cell = Grid.get(grid, row, col)
    if cell.continuation, do: [], else: cell_bytes(cell)
  end

  defp row_text(grid, row) do
    Enum.reduce(0..(grid.width - 1), [], fn col, acc ->
      cell = Grid.get(grid, row, col)
      if cell.continuation, do: acc, else: [acc, cell.grapheme]
    end)
    |> IO.iodata_to_binary()
  end
end

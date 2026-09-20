defmodule Terra.Renderer.Grid do
  @moduledoc """
  The 2D cell buffer a frame is painted into.

  A cell holds one grapheme and its style. Wide graphemes (width 2) own their cell
  and mark the next column as a continuation, so painting never writes a second
  grapheme into the space a wide glyph already covers. Empty cells read back as a
  single space with no style.

  Cells are keyed by `{row, col}`, both 0-based, in a plain map. Writes outside the
  grid are ignored, which is how clipping stays total: no caller has to check
  bounds.
  """

  alias Terra.Width

  defstruct width: 0, height: 0, cells: %{}

  @type cell :: %{
          grapheme: binary,
          style: keyword,
          wide: boolean,
          continuation: boolean
        }

  @type t :: %__MODULE__{
          width: non_neg_integer,
          height: non_neg_integer,
          cells: %{{non_neg_integer, non_neg_integer} => cell}
        }

  @doc "Builds an empty grid."
  @spec new(non_neg_integer, non_neg_integer) :: t
  def new(width, height) when width >= 0 and height >= 0 do
    %__MODULE__{width: width, height: height}
  end

  @doc "The cell used for every position that was never written."
  @spec empty_cell() :: cell
  def empty_cell, do: %{grapheme: " ", style: [], wide: false, continuation: false}

  @doc "Reads a cell. Positions outside the grid read back as empty."
  @spec get(t, integer, integer) :: cell
  def get(grid, row, col) do
    Map.get(grid.cells, {row, col}, empty_cell())
  end

  @doc """
  Writes a grapheme, marking the next column as a continuation when it is wide.

  Returns the grid unchanged when the position is outside it.
  """
  @spec put(t, integer, integer, binary, keyword) :: t
  def put(grid, row, col, grapheme, style \\ []) do
    if inside?(grid, row, col) do
      width = Width.grapheme(grapheme)

      cells =
        Map.put(grid.cells, {row, col}, %{
          empty_cell()
          | grapheme: grapheme,
            style: style,
            wide: width == 2
        })

      cells =
        if width == 2 and inside?(grid, row, col + 1) do
          Map.put(cells, {row, col + 1}, %{empty_cell() | continuation: true})
        else
          cells
        end

      %{grid | cells: cells}
    else
      grid
    end
  end

  defp inside?(%__MODULE__{width: width, height: height}, row, col) do
    row >= 0 and row < height and col >= 0 and col < width
  end
end

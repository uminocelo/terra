defmodule Terra.Terminal.ANSI do
  @moduledoc """
  ANSI escape sequences Terra emits.

  Pure data, no IO. `Terra.Terminal` turns these into writes; the terminal owner
  uses them for the restore sequence.
  """

  @doc "Enters (`true`) or leaves (`false`) the alternate screen buffer."
  @spec alt_screen(boolean) :: binary
  def alt_screen(true), do: "\e[?1049h"
  def alt_screen(false), do: "\e[?1049l"

  @doc "Hides or shows the cursor."
  @spec cursor(:hide | :show) :: binary
  def cursor(:hide), do: "\e[?25l"
  def cursor(:show), do: "\e[?25h"

  @doc "Resets all character attributes."
  @spec reset() :: binary
  def reset, do: "\e[0m"

  @doc "Clears the screen."
  @spec clear() :: binary
  def clear, do: "\e[2J"

  @doc "Moves the cursor to the home position."
  @spec home() :: binary
  def home, do: "\e[H"

  @doc "Moves the cursor to `row`/`col`, both 1-based."
  @spec move(pos_integer, pos_integer) :: binary
  def move(row, col), do: "\e[#{row};#{col}H"
end

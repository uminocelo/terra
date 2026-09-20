defmodule Terra.Width do
  @moduledoc """
  Display width of graphemes, in terminal cells.

  Terra measures in columns, not codepoints. A grapheme is 2 columns wide when any
  of its codepoints is in an East Asian Wide or Fullwidth block (or is a common
  emoji), 0 when it is only combining marks or zero-width controls, and 1
  otherwise.

  This is a practical approximation of Unicode East Asian Width, not a full UAX
  #11 implementation: the ranges below cover CJK, Hangul, fullwidth forms and
  emoji, which is what the cell grid has to get right to avoid overlapping the
  next cell.
  """

  @zero_width [0x200B, 0x200C, 0x200D, 0xFEFF]

  @doc "Returns the display width of a single grapheme."
  @spec grapheme(binary) :: 0 | 1 | 2
  def grapheme(""), do: 0

  def grapheme(grapheme) when is_binary(grapheme) do
    codepoints = String.to_charlist(grapheme)

    cond do
      codepoints == [] -> 0
      Enum.all?(codepoints, &zero_width?/1) -> 0
      Enum.any?(codepoints, &wide?/1) -> 2
      true -> 1
    end
  end

  @doc "Returns the display width of a string."
  @spec string(binary) :: non_neg_integer
  def string(binary) when is_binary(binary) do
    binary
    |> String.graphemes()
    |> Enum.reduce(0, fn grapheme, total -> total + grapheme(grapheme) end)
  end

  @doc "Returns true when a codepoint occupies no cell."
  @spec zero_width?(non_neg_integer) :: boolean
  def zero_width?(codepoint) do
    codepoint in @zero_width or
      codepoint in 0x0300..0x036F or
      codepoint in 0x1AB0..0x1AFF or
      codepoint in 0x1DC0..0x1DFF or
      codepoint in 0x20D0..0x20FF or
      codepoint in 0xFE00..0xFE0F or
      codepoint in 0xFE20..0xFE2F
  end

  @doc "Returns true when a codepoint occupies two cells."
  @spec wide?(non_neg_integer) :: boolean
  def wide?(codepoint) do
    codepoint in 0x1100..0x115F or
      codepoint in 0x2E80..0x303E or
      codepoint in 0x3041..0x33FF or
      codepoint in 0x3400..0x4DBF or
      codepoint in 0x4E00..0x9FFF or
      codepoint in 0xA000..0xA4CF or
      codepoint in 0xAC00..0xD7A3 or
      codepoint in 0xF900..0xFAFF or
      codepoint in 0xFE30..0xFE6F or
      codepoint in 0xFF00..0xFF60 or
      codepoint in 0xFFE0..0xFFE6 or
      codepoint in 0x1F300..0x1F64F or
      codepoint in 0x1F900..0x1F9FF or
      codepoint in 0x20000..0x2FFFD or
      codepoint in 0x30000..0x3FFFD
  end
end

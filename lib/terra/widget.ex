defmodule Terra.Widget do
  @moduledoc """
  Stateless widgets built from parent-owned state.

  A widget is a function from your state to a `Terra.View`, plus pure helpers for
  the state transitions. Nothing here runs a loop, spawns a process, or owns state:
  each widget reads the values you pass in and returns values you store, so widgets
  compose with any `Terra.App` and stay testable without a terminal.

  Each widget also has an event helper that turns runtime events into documented
  values for the parent to handle, including OutMsg-style ones such as
  `{:chosen, index}` and `:cancel`.

  ## List

      Terra.Widget.list(["One", "Two"], selected: 1, height: 2)
      Terra.Widget.list_event(:down, index, count)

  `list_event/3-4` returns `{:move, index}`, `{:chosen, index}`, `:cancel`, or
  `:ignore`. The parent decides what to do with them, and owns the index.

  ## Progress and spinner

      Terra.Widget.progress(0.4)          # 0..1 by default
      Terra.Widget.progress(40, max: 100) # 0..100 with :max
      Terra.Widget.spinner(tick)          # advances on each tick

  ## Input

      Terra.Widget.input(value, cursor: cursor, focused: true)
      Terra.Widget.input_event(event, value, cursor)

  `input_event/3-4` returns `{:edit, value, cursor}` for a change, `{:submit, value}`
  on Enter (the documented message to hand to `update/2`), `:cancel` on Escape, or
  `:ignore`. `insert/3`, `backspace/2` and `move_cursor/3` are available directly.
  """

  alias Terra.View

  @marker "› "
  @blank "  "
  @spinner_frames ["|", "/", "-", "\\"]
  @filled "█"
  @empty "░"

  @doc """
  Renders a list, highlighting `:selected`.

  Options:

  - `:selected` — index of the highlighted row (default 0)
  - `:height` — visible rows; the window scrolls so the selection stays visible
  - `:focused` — when false the highlight is dimmer (default true)
  - `:marker` / `:blank` — prefixes for the selected and unselected rows
  """
  @spec list([term], keyword) :: View.t()
  def list(items, opts \\ []) do
    labels = Enum.map(items, &to_string/1)
    count = length(labels)
    selected = Keyword.get(opts, :selected, 0) || 0
    height = Keyword.get(opts, :height)
    focused = Keyword.get(opts, :focused, true)
    marker = Keyword.get(opts, :marker, @marker)
    blank = Keyword.get(opts, :blank, @blank)

    offset = window_offset(selected, count, height)

    labels
    |> Enum.with_index()
    |> Enum.drop(offset)
    |> maybe_take(height)
    |> Enum.map(fn {label, index} ->
      prefix = if index == selected, do: marker, else: blank
      View.text(prefix <> label, row_style(index == selected, focused))
    end)
    |> View.vstack()
  end

  @doc """
  Turns a list event into a documented value for the parent.

  Returns `{:move, index}` for up/down (and `k`/`j`), `{:chosen, index}` for Enter,
  `:cancel` for Escape, or `:ignore` for anything else.
  """
  @spec list_event(
          Terra.event(),
          non_neg_integer,
          non_neg_integer,
          keyword
        ) :: {:move, non_neg_integer} | {:chosen, non_neg_integer} | :cancel | :ignore
  def list_event(event, index, count, _opts \\ [])

  def list_event(event, index, count, _opts) when event in [:up, {:char, "k"}],
    do: {:move, move_index(index, count, :up)}

  def list_event(event, index, count, _opts) when event in [:down, {:char, "j"}],
    do: {:move, move_index(index, count, :down)}

  def list_event(:enter, index, _count, _opts), do: {:chosen, index}
  def list_event(:esc, _index, _count, _opts), do: :cancel
  def list_event(_event, _index, _count, _opts), do: :ignore

  @doc "Moves a list index, wrapping at both ends."
  @spec move_index(integer, non_neg_integer, :up | :down) :: non_neg_integer
  def move_index(_index, 0, _direction), do: 0

  def move_index(index, count, :down), do: rem(index + 1, count)
  def move_index(index, count, :up), do: rem(index - 1 + count, count)

  @doc """
  Renders a progress bar.

  `value` runs from `0` to `:max` (default `1`, so `0..1`). Pass `max: 100` for
  percentages. Values outside the range are clamped. The bar is `:width` cells
  wide (default 20).
  """
  @spec progress(number, keyword) :: View.t()
  def progress(value, opts \\ []) do
    max = Keyword.get(opts, :max, 1)
    width = Keyword.get(opts, :width, 20)
    style = Keyword.get(opts, :style, fg: :accent)
    filled_glyph = Keyword.get(opts, :filled, @filled)
    empty_glyph = Keyword.get(opts, :empty, @empty)

    filled = filled_cells(value, max, width)

    bar =
      String.duplicate(filled_glyph, filled) <>
        String.duplicate(empty_glyph, width - filled)

    View.text(bar, style)
  end

  @doc "Returns the percentage a progress value represents, for a label."
  @spec progress_percent(number, keyword) :: non_neg_integer
  def progress_percent(value, opts \\ []) do
    max = Keyword.get(opts, :max, 1)
    if max <= 0, do: 0, else: round(clamp_ratio(value / max) * 100)
  end

  @doc "Returns the spinner frame for a tick count."
  @spec spinner_frame(integer, keyword) :: binary
  def spinner_frame(tick, opts \\ []) do
    frames = Keyword.get(opts, :frames, @spinner_frames)
    Enum.at(frames, rem(abs(tick), length(frames)))
  end

  @doc "Renders the spinner frame for a tick count. Advance the tick on each tick."
  @spec spinner(integer, keyword) :: View.t()
  def spinner(tick, opts \\ []) do
    View.text(spinner_frame(tick, opts), Keyword.get(opts, :style, []))
  end

  @doc """
  Renders a single-line text input.

  Options:

  - `:cursor` — grapheme index of the cursor (default: end of the value)
  - `:focused` — draw the cursor cell (default true)
  - `:placeholder` — shown, dimmed, when the value is empty
  """
  @spec input(binary, keyword) :: View.t()
  def input(value, opts \\ []) when is_binary(value) do
    graphemes = String.graphemes(value)
    position = value |> cursor(opts) |> clamp(length(graphemes))
    focused = Keyword.get(opts, :focused, true)
    placeholder = Keyword.get(opts, :placeholder)

    cond do
      not focused ->
        View.text(value)

      value == "" and is_binary(placeholder) ->
        View.text(placeholder, dim: true)

      true ->
        {left, right} = Enum.split(graphemes, position)

        {cursor_cell, rest} =
          case right do
            [head | tail] -> {head, tail}
            [] -> {" ", []}
          end

        View.hstack([
          View.text(Enum.join(left)),
          View.text(cursor_cell, reverse: true),
          View.text(Enum.join(rest))
        ])
    end
  end

  @doc "Returns the cursor index an `input/2` call would use."
  @spec cursor(binary, keyword) :: non_neg_integer
  def cursor(value, opts \\ []) when is_binary(value) do
    case Keyword.get(opts, :cursor) do
      nil -> String.length(value)
      index -> index
    end
  end

  @doc """
  Handles one runtime event for a text input.

  Returns:

  - `{:edit, value, cursor}` when the value or cursor changed
  - `{:submit, value}` on Enter, the documented message the parent handles
  - `:cancel` on Escape
  - `:ignore` for everything else
  """
  @spec input_event(Terra.event(), binary, non_neg_integer, keyword) ::
          {:edit, binary, non_neg_integer} | {:submit, binary} | :cancel | :ignore
  def input_event(event, value, cursor, _opts \\ [])

  def input_event({:char, grapheme}, value, cursor, _opts) do
    {value, cursor} = insert(value, cursor, grapheme)
    {:edit, value, cursor}
  end

  def input_event(:backspace, value, cursor, _opts) do
    {value, cursor} = backspace(value, cursor)
    {:edit, value, cursor}
  end

  def input_event(:left, value, cursor, _opts),
    do: {:edit, value, move_cursor(value, cursor, :left)}

  def input_event(:right, value, cursor, _opts),
    do: {:edit, value, move_cursor(value, cursor, :right)}

  def input_event(:enter, value, _cursor, _opts), do: {:submit, value}
  def input_event(:esc, _value, _cursor, _opts), do: :cancel
  def input_event(_event, _value, _cursor, _opts), do: :ignore

  @doc "Inserts a grapheme at the cursor. Returns `{value, cursor}`."
  @spec insert(binary, non_neg_integer, binary) :: {binary, non_neg_integer}
  def insert(value, cursor, grapheme) when is_binary(value) and is_binary(grapheme) do
    graphemes = String.graphemes(value)
    cursor = clamp(cursor, length(graphemes))
    {left, right} = Enum.split(graphemes, cursor)
    {Enum.join(left ++ [grapheme] ++ right), cursor + String.length(grapheme)}
  end

  @doc "Deletes the grapheme before the cursor. Returns `{value, cursor}`."
  @spec backspace(binary, non_neg_integer) :: {binary, non_neg_integer}
  def backspace(value, cursor) when is_binary(value) do
    graphemes = String.graphemes(value)
    cursor = clamp(cursor, length(graphemes))

    if cursor == 0 do
      {value, 0}
    else
      {left, right} = Enum.split(graphemes, cursor)
      {Enum.join(List.delete_at(left, -1) ++ right), cursor - 1}
    end
  end

  @doc "Moves the cursor one grapheme left or right, clamped to the value."
  @spec move_cursor(binary, non_neg_integer, :left | :right) :: non_neg_integer
  def move_cursor(value, cursor, direction) when is_binary(value) do
    size = String.length(value)

    case direction do
      :left -> clamp(cursor - 1, size)
      :right -> clamp(cursor + 1, size)
    end
  end

  defp row_style(true, true), do: [reverse: true]
  defp row_style(true, false), do: [underline: true]
  defp row_style(false, _focused), do: []

  defp window_offset(_selected, count, _height) when count == 0, do: 0
  defp window_offset(_selected, _count, nil), do: 0

  defp window_offset(selected, count, height) do
    selected
    |> max(0)
    |> min(count - 1)
    |> Kernel.-(height - 1)
    |> max(0)
    |> min(max(count - height, 0))
  end

  defp maybe_take(list, nil), do: list
  defp maybe_take(list, height), do: Enum.take(list, height)

  defp filled_cells(_value, max, _width) when max <= 0, do: 0

  defp filled_cells(value, max, width) do
    round(width * clamp_ratio(value / max))
  end

  defp clamp_ratio(ratio) when ratio < 0, do: 0.0
  defp clamp_ratio(ratio) when ratio > 1, do: 1.0
  defp clamp_ratio(ratio), do: ratio

  defp clamp(index, _length) when index < 0, do: 0
  defp clamp(index, length) when index > length, do: length
  defp clamp(index, _length), do: index
end

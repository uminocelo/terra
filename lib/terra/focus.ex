defmodule Terra.Focus do
  @moduledoc """
  Parent-owned focus for marked children.

  Focus is a value, like everything else: you keep the focused id in your state and
  mark the children that can take focus with `focus/2`. `ids/1` walks a view in
  layout order, so Tab order is deterministic and only marked children participate.

      def view(state) do
        vstack([
          Focus.focus(:name, Widget.input(state.name, focused: Focus.focused?(:name, state.focus))),
          Focus.focus(:save, Widget.list(["Save"], selected: 0))
        ])
      end

  Then map the keys in `event_to_msg/2`:

      def event_to_msg(event, state), do: Focus.event(event, Focus.ids(view_of(state)), state.focus)

  `event/3` returns `{:focus, id}` for Tab and Shift-Tab, or `:ignore`. Shift-Tab
  arrives as `{:ctrl, :tab}` because the runtime event union has no shift modifier.
  """

  @doc "Marks a view as focusable under `id`."
  @spec focus(term, Terra.View.t()) :: Terra.View.t()
  def focus(id, view), do: {:focus, id, view}

  @doc "Collects focus ids in layout order."
  @spec ids(Terra.View.t()) :: [term]
  def ids({:focus, id, child}), do: [id | ids(child)]
  def ids({:vstack, children, _opts}), do: Enum.flat_map(children, &ids/1)
  def ids({:hstack, children, _opts}), do: Enum.flat_map(children, &ids/1)
  def ids({:box, child, _opts}), do: ids(child)
  def ids({:text, _string, _style}), do: []

  @doc "Returns the id after `current`, wrapping. `nil` starts at the first id."
  @spec next([term], term) :: term | nil
  def next(ids, current), do: move(ids, current, :next)

  @doc "Returns the id before `current`, wrapping. `nil` starts at the last id."
  @spec previous([term], term) :: term | nil
  def previous(ids, current), do: move(ids, current, :previous)

  @doc "Moves focus forward or backward through the ids."
  @spec move([term], term, :next | :previous) :: term | nil
  def move([], _current, _direction), do: nil

  def move(ids, nil, :next), do: hd(ids)
  def move(ids, nil, :previous), do: List.last(ids)

  def move(ids, current, direction) do
    count = length(ids)

    case Enum.find_index(ids, &(&1 == current)) do
      nil -> if direction == :next, do: hd(ids), else: List.last(ids)
      index when direction == :next -> Enum.at(ids, rem(index + 1, count))
      index -> Enum.at(ids, rem(index - 1 + count, count))
    end
  end

  @doc "Returns true when `id` is the focused id."
  @spec focused?(term, term) :: boolean
  def focused?(id, current), do: id == current

  @doc """
  Maps Tab and Shift-Tab to `{:focus, id}`, and everything else to `:ignore`.

  A Tab with no marked children returns `{:focus, nil}`; treat that as no change.
  """
  @spec event(Terra.event(), [term], term) :: {:focus, term} | :ignore
  def event(:tab, ids, current), do: {:focus, next(ids, current)}
  def event({:ctrl, :tab}, ids, current), do: {:focus, previous(ids, current)}
  def event(_event, _ids, _current), do: :ignore
end

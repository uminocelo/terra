# The todo wizard used by examples/todo.exs.
#
# Kept in its own file so tests can load the app without taking a terminal.

defmodule Todo do
  @moduledoc """
  A small todo list: an input and a list, switched with Tab, plus a delete confirm.

  This is the shape the v0.2 widgets are for: one `Terra.App`, two focusable
  children, and no nested runtime. `Terra.Widget` renders the input and the list;
  the state (draft, cursor, selection, focus) lives here and `update/2` owns it.
  """

  use Terra

  alias Terra.{Focus, Widget}

  @list_height 5

  @impl Terra.App
  def init(_opts) do
    %{todos: [], draft: "", cursor: 0, focus: :input, selected: 0, confirming: nil}
  end

  @impl Terra.App
  def event_to_msg(event, state) do
    case Focus.event(event, Focus.ids(view(state)), state.focus) do
      {:focus, id} -> {:focus, id}
      :ignore -> event
    end
  end

  @impl Terra.App
  def update({:focus, id}, state), do: %{state | focus: id}

  # Confirm deletion first: it takes precedence over the focused widget.
  def update(:enter, %{confirming: index} = state) when is_integer(index), do: delete(state, index)
  def update({:char, "y"}, %{confirming: index} = state) when is_integer(index), do: delete(state, index)
  def update({:char, "n"}, %{confirming: index} = state) when is_integer(index), do: %{state | confirming: nil}
  def update(:esc, %{confirming: index} = state) when is_integer(index), do: %{state | confirming: nil}

  # Typing goes to the input widget while it has focus.
  def update(event, %{focus: :input} = state) do
    case Widget.input_event(event, state.draft, state.cursor) do
      {:edit, draft, cursor} -> %{state | draft: draft, cursor: cursor}
      {:submit, draft} -> add(state, draft)
      :cancel -> {:quit, state}
      :ignore -> update_global(event, state)
    end
  end

  def update(event, %{focus: :list} = state), do: update_list(event, state)
  def update(event, state), do: update_global(event, state)

  @impl Terra.App
  def view(state) do
    box(
      vstack([
        text("Todos", bold: true),
        Focus.focus(:input, input_row(state)),
        text(""),
        Focus.focus(:list, list_row(state)),
        text(""),
        footer(state)
      ]),
      title: "Todo",
      border: :rounded,
      padding: [top: 0, right: 2, bottom: 0, left: 1]
    )
  end

  defp input_row(state) do
    hstack([
      text("> ", fg: :accent),
      Widget.input(state.draft,
        cursor: state.cursor,
        focused: state.focus == :input,
        placeholder: "type a todo, Enter to add"
      )
    ])
  end

  defp list_row(%{todos: []} = _state), do: text("nothing yet", dim: true)
  defp list_row(state), do: Widget.list(state.todos, selected: state.selected, focused: state.focus == :list, height: @list_height)

  defp footer(%{confirming: index} = state) when is_integer(index) do
    todo = Enum.at(state.todos, index, "")
    text("Delete \"#{todo}\"? y/n", fg: :red)
  end

  defp footer(_state) do
    text("Tab switch  Enter add/confirm  d delete  Esc quit", dim: true)
  end

  defp update_list(:up, state), do: %{state | selected: Widget.move_index(state.selected, count(state), :up)}
  defp update_list(:down, state), do: %{state | selected: Widget.move_index(state.selected, count(state), :down)}

  defp update_list(:enter, %{todos: []} = state), do: state
  defp update_list(:enter, state), do: %{state | confirming: state.selected}

  defp update_list({:char, "d"}, %{todos: []} = state), do: state
  defp update_list({:char, "d"}, state), do: %{state | confirming: state.selected}

  defp update_list({:char, "q"}, state), do: {:quit, state}
  defp update_list(:esc, state), do: {:quit, state}
  defp update_list(event, state), do: update_global(event, state)

  defp update_global(:esc, state), do: {:quit, state}
  defp update_global({:up, _}, state), do: %{state | focus: :list}
  defp update_global(_event, state), do: state

  defp add(state, draft) do
    case String.trim(draft) do
      "" -> state
      todo -> %{state | todos: state.todos ++ [todo], draft: "", cursor: 0, selected: length(state.todos)}
    end
  end

  defp delete(state, index) do
    %{state | todos: List.delete_at(state.todos, index), selected: 0, confirming: nil}
  end

  defp count(state), do: length(state.todos)
end
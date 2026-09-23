# The mix test watcher used by examples/test_watcher.exs.
#
# Kept in its own file so tests can load the app without taking a terminal.

defmodule TestWatcher.MixTest do
  @moduledoc """
  Pure parser for `mix test --no-color` output.

  Turns ExUnit's plain text into a failure list plus counts. No IO, no
  processes: feed it lines, get data back.
  """

  @failure_header ~r/^\s*\d+\)\s+(?:test|doctest)\s+/
  @location ~r/^\s+(\S+\.exs?):(\d+)\s*$/
  @stacktrace ~r/^\s*stacktrace:/
  @summary ~r/^(\d+) tests?, (\d+) failures?/

  @doc """
  Parses output `lines` into a result map.

  Returns `%{failures: failures, total: t, failed: f, passed: p}` where each
  failure is `%{name, file, line, assertion}` and `assertion` is the text
  between the location line and the stacktrace, trimmed of blank edges. A
  passing suite yields an empty failure list and `passed == total`.
  """
  @spec parse([binary]) :: %{
          failures: [%{name: binary, file: binary | nil, line: pos_integer | nil, assertion: binary}],
          total: non_neg_integer,
          failed: non_neg_integer,
          passed: non_neg_integer
        }
  def parse(lines) when is_list(lines) do
    failures = failures(lines)
    {total, failed} = summary(lines, length(failures))
    %{failures: failures, total: total, failed: failed, passed: max(total - failed, 0)}
  end

  defp failures(lines) do
    for {line, index} <- Enum.with_index(lines), line =~ @failure_header do
      block =
        lines
        |> Enum.drop(index + 1)
        |> Enum.take_while(fn rest -> not (rest =~ @failure_header or rest =~ @summary) end)

      {file, line_number} = location(block)

      %{
        name: String.replace(line, ~r/^\s*\d+\)\s+/, ""),
        file: file,
        line: line_number,
        assertion: assertion(block)
      }
    end
  end

  defp location(block) do
    case Enum.find(block, &(&1 =~ @location)) do
      nil ->
        {nil, nil}

      line ->
        [_, file, line_number] = Regex.run(@location, line)
        {file, String.to_integer(line_number)}
    end
  end

  defp assertion(block) do
    block
    |> Enum.drop_while(&(not (&1 =~ @location)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not (&1 =~ @stacktrace)))
    |> trim_blank_edges()
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
  end

  defp trim_blank_edges(lines) do
    lines
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end

  defp summary(lines, default) do
    case Enum.find_value(Enum.reverse(lines), &Regex.run(@summary, &1)) do
      [_, total, failed] -> {String.to_integer(total), String.to_integer(failed)}
      nil -> {default, default}
    end
  end
end

defmodule TestWatcher do
  @moduledoc """
  A mix test watcher: runs the suite through a port command, lists failures,
  and shows the selected assertion in a pane.

  `r` re-runs, `j`/`k` or the arrows select a failure, Ctrl+D/Ctrl+U scroll the
  assertion pane, `q`/Esc/Ctrl+C quits. The suite runs as data (`{:port, cmd,
  msg}` returned from `init/1` and `update/2`); output arrives as the `:ran`
  message, never through `view/1`.
  """

  use Terra

  alias Terra.Widget

  @command "mix test --no-color"
  @tick_ms 150
  @chrome_rows 6

  defstruct status: :idle,
            command: nil,
            ticks: 0,
            failures: [],
            passed: 0,
            failed: 0,
            total: 0,
            selected: 0,
            scroll: 0,
            width: 80,
            height: 24,
            error: nil

  @impl Terra.App
  def init(opts) do
    state = %__MODULE__{command: Keyword.get(opts, :command, @command)}
    run(state)
  end

  @impl Terra.App
  def update(:tick, %{status: :running} = state), do: {%{state | ticks: state.ticks + 1}, [{:tick, @tick_ms, :tick}]}
  def update(:tick, state), do: state

  def update({:ran, {:ok, {lines, _status}}}, state) do
    result = TestWatcher.MixTest.parse(lines)

    %{state | status: :done, failures: result.failures, passed: result.passed, failed: result.failed,
              total: result.total, selected: 0, scroll: 0, error: nil}
  end

  def update({:ran, {:error, reason}}, state) do
    %{state | status: :error, error: inspect(reason)}
  end

  def update({:resize, width, height}, state) do
    state = %{state | width: width, height: height}
    %{state | scroll: min(state.scroll, max_scroll(state))}
  end

  def update(event, state) when event in [:up, :down, {:char, "j"}, {:char, "k"}] do
    direction = if event in [:up, {:char, "k"}], do: :up, else: :down
    selected = Widget.move_index(state.selected, length(state.failures), direction)
    %{state | selected: selected, scroll: 0}
  end

  def update({:ctrl, :d}, state), do: scroll(state, div(body_height(state), 2))
  def update({:ctrl, :u}, state), do: scroll(state, -div(body_height(state), 2))

  def update({:char, "r"}, %{status: status} = state) when status != :running do
    run(%{state | selected: 0, scroll: 0, error: nil})
  end

  def update({:char, "q"}, state), do: {:quit, state}
  def update(:esc, state), do: {:quit, state}
  def update(_event, state), do: state

  @impl Terra.App
  def view(state) do
    box(
      vstack([
        header(state),
        text(""),
        body(state),
        text(""),
        text("j/k move  ctrl+d/u scroll pane  r re-run  q quit", dim: true)
      ]),
      title: "mix test",
      border: :rounded,
      padding: [top: 0, right: 2, bottom: 0, left: 1]
    )
  end

  defp run(%{command: nil} = state), do: state

  defp run(%{command: command} = state) do
    {%{state | status: :running, ticks: 0}, [{:port, command, :ran}, {:tick, @tick_ms, :tick}]}
  end

  defp header(%{status: :running}), do: text("running the suite…", fg: :accent)

  defp header(%{status: :done} = state) do
    text("#{state.failed} failures, #{state.passed} passed of #{state.total}", bold: true)
  end

  defp header(%{status: :error} = state), do: text("could not run: #{state.error}", fg: :red)
  defp header(%{status: :idle}), do: text("press r to run the suite", dim: true)

  defp body(%{status: :running} = state) do
    vstack([
      hstack([Widget.spinner(state.ticks), text(" mix test --no-color")]),
      Widget.progress(rem(state.ticks * 7, 101), max: 100, width: min(40, max(state.width - 8, 10)))
    ])
  end

  defp body(%{status: :done, failures: []} = state) do
    text("all #{state.passed} tests passed", fg: :green)
  end

  defp body(%{status: :done} = state) do
    hstack([failure_list(state), assertion_pane(state)], gap: 2)
  end

  defp body(%{status: :error} = state), do: text(state.error || "unknown error", fg: :red)
  defp body(%{status: :idle}), do: text("no results yet", dim: true)

  defp failure_list(state) do
    labels =
      Enum.map(state.failures, fn failure ->
        "#{failure.name} (#{failure.file}:#{failure.line})"
        |> truncate(list_width(state))
      end)

    Widget.list(labels, selected: state.selected, height: body_height(state))
  end

  defp assertion_pane(state) do
    case Enum.at(state.failures, state.selected) do
      nil ->
        text("")

      failure ->
        visible =
          failure.assertion
          |> String.split("\n")
          |> Enum.drop(state.scroll)
          |> Enum.take(pane_lines(state))

        vstack([text("#{failure.file}:#{failure.line}", bold: true), text("")] ++ Enum.map(visible, &text/1))
    end
  end

  defp truncate(label, width) do
    if String.length(label) <= width do
      label
    else
      String.slice(label, 0, max(width - 1, 0)) <> "…"
    end
  end

  defp list_width(state), do: max(div(state.width, 2) - 4, 10)

  defp pane_lines(state), do: max(body_height(state) - 2, 1)

  defp scroll(state, delta) do
    %{state | scroll: (state.scroll + delta) |> max(0) |> min(max_scroll(state))}
  end

  defp max_scroll(state) do
    case Enum.at(state.failures, state.selected) do
      nil -> 0
      failure -> max(String.split(failure.assertion, "\n") |> length() |> Kernel.-(pane_lines(state)), 0)
    end
  end

  defp body_height(state), do: max(state.height - @chrome_rows, 1)
end

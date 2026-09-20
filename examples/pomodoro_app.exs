# The pomodoro timer used by examples/pomodoro.exs.
#
# Kept in its own file so tests can load the app without taking a terminal.

defmodule Pomodoro do
  @moduledoc """
  A pomodoro timer: focus and break phases, a progress bar, and a spinner.

  A tiny state machine driven by `{:tick, ms, msg}`. Every tick either counts the
  phase down, or switches phase; the runtime keeps rescheduling because `update/2`
  returns a fresh command. Space pauses, `q` quits.
  """

  use Terra

  alias Terra.Widget

  @frames ["|", "/", "-", "\\"]
  @default_tick_ms 1_000
  @default_focus_seconds 25 * 60
  @default_break_seconds 5 * 60

  @impl Terra.App
  def init(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    focus = Keyword.get(opts, :focus_seconds, @default_focus_seconds)
    break = Keyword.get(opts, :break_seconds, @default_break_seconds)

    state = %{
      phase: :focus,
      running: true,
      remaining: focus,
      focus: focus,
      break: break,
      cycles: 0,
      clock: 0,
      tick_ms: tick_ms
    }

    {state, [{:tick, tick_ms, :tick}]}
  end

  @impl Terra.App
  def update(:tick, state), do: {step(%{state | clock: state.clock + 1}), [{:tick, state.tick_ms, :tick}]}
  def update({:char, " "}, state), do: %{state | running: not state.running}
  def update({:char, "q"}, state), do: {:quit, state}
  def update(:esc, state), do: {:quit, state}
  def update(_event, state), do: state

  @impl Terra.App
  def view(state) do
    total = if state.phase == :focus, do: state.focus, else: state.break
    elapsed = 1 - state.remaining / total

    box(
      vstack([
        text("#{label(state.phase)}  #{format(state.remaining)}", bold: true, fg: :accent),
        Widget.progress(elapsed, width: 24),
        hstack([
          Widget.spinner(state.clock, frames: @frames, style: [fg: :accent]),
          text("  cycles: #{state.cycles}", dim: true),
          text(if(state.running, do: "  running", else: "  paused"), dim: true)
        ]),
        text("space pause/resume  q quit", dim: true)
      ]),
      title: "Pomodoro",
      border: :double,
      padding: 1
    )
  end

  defp step(%{running: false} = state), do: state
  defp step(%{remaining: remaining} = state) when remaining > 1, do: %{state | remaining: remaining - 1}

  defp step(%{phase: :focus} = state) do
    %{state | phase: :break, remaining: state.break, cycles: state.cycles + 1}
  end

  defp step(%{phase: :break} = state), do: %{state | phase: :focus, remaining: state.focus}

  defp label(:focus), do: "Focus"
  defp label(:break), do: "Break"

  defp format(seconds) do
    "#{div(seconds, 60) |> pad()}:#{rem(seconds, 60) |> pad()}"
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
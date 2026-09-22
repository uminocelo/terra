defmodule Terra.App do
  @moduledoc """
  The Elm loop a Terra app implements.

  An app is a plain module with three callbacks and one optional one. `use Terra`
  marks the module as an implementation, imports `Terra.View` so `text/2`,
  `vstack/2`, `hstack/2` and `box/2` are available unqualified, and provides the
  default `event_to_msg/2`.

  ## State and messages

  `init/1` returns the initial state, or `{state, commands}` when the app wants to
  schedule work immediately. `update/2` is pure: it receives one message and the
  current state and returns the next state, or `{:quit, state}`, or
  `{state, commands}`. There is deliberately no `{:noreply, state}` shape; if you
  do not want to change anything, return the state unchanged.

  Keys and other terminal input arrive as the small runtime event union, never as
  raw bytes. `event_to_msg/2` maps an event to your own message (or returns
  `:ignore` to drop it); the default passes the event through unchanged.

  ## Commands are data

  A command is a value the runtime executes, not a function you call:

      {:tick, ms, msg}
      {:read_file, path, msg}
      {:port, cmd, msg}

  After `ms` milliseconds the runtime delivers `msg` to `update/2`. File and
  port commands deliver `{msg, {:ok, data} | {:error, reason}}` instead; see
  `Terra.Command` for the exact shapes. `init/1` may return commands so a
  monitor or spinner can start polling immediately.
  """

  @type state :: term
  @type command :: Terra.Command.t()

  @doc "Returns the initial state, or `{state, commands}`."
  @callback init(keyword) :: state | {state, [command]}

  @doc """
  Applies one message.

  Returns the next state, `{:quit, state}` to stop the app, or
  `{state, commands}` to keep running and schedule more work.
  """
  @callback update(term, state) :: state | {:quit, state} | {state, [command]}

  @doc "Renders the current state as a `Terra.View`."
  @callback view(state) :: Terra.View.t()

  @doc """
  Maps a runtime event to an app message, or `:ignore` to drop it.

  Optional. The default returns the event unchanged, so apps that are happy to
  match on `{:char, "j"}` can skip it.
  """
  @callback event_to_msg(Terra.Input.event(), state) :: term | :ignore

  @optional_callbacks event_to_msg: 2
end

defmodule Terra.Input.Backend do
  @moduledoc """
  Boundary between `Terra.Input` and the operating system.

  The default implementation is `Terra.Input.TTY`, which reads stdin one byte at a
  time in raw mode. Tests substitute their own module implementing this callback
  so the reader loop and event emission can be exercised without a TTY.
  """

  @doc """
  Reads the next chunk of input bytes, blocking at most `timeout` milliseconds.

  Returns `{:ok, bytes}` with one or more bytes, `:eof` when the input is closed,
  or `{:error, reason}`.
  """
  @callback read(timeout) :: {:ok, binary} | :eof | {:error, term}
end

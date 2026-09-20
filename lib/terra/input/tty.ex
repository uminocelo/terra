defmodule Terra.Input.TTY do
  @moduledoc """
  Default `Terra.Input.Backend`, reading stdin one byte at a time.

  `IO.binread/2` returns as soon as a key is pressed once the terminal is in raw
  mode, so there is no line buffering. Bytes are read with the device encoding the
  terminal owner set (`:latin1`), which keeps multi-byte UTF-8 transparent to the
  parser.

  Raw mode is not this module's job: `Terra.Terminal.enter/1` sets it up. Reading
  blocks the calling process until a key arrives; `Terra.Input` runs the reads in
  a dedicated process so the rest of the application stays responsive.
  """

  @behaviour Terra.Input.Backend

  @impl true
  def read(_timeout) do
    case IO.binread(:stdio, 1) do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      data when is_binary(data) -> {:ok, data}
    end
  rescue
    _error -> {:error, :enotsup}
  end
end

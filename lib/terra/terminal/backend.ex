defmodule Terra.Terminal.Backend do
  @moduledoc """
  Boundary between `Terra.Terminal` and the operating system.

  The default implementation is `Terra.Terminal.TTY`. Tests substitute their
  own module implementing these callbacks, so terminal ownership, raw mode,
  escape sequences and restore can be exercised without a real TTY.
  """

  @doc "Writes bytes to the terminal."
  @callback write(iodata) :: :ok | {:error, term}

  @doc "Returns the current device encoding, or nil when unknown."
  @callback encoding() :: atom | nil

  @doc "Sets the device encoding. `:latin1` keeps input bytes transparent."
  @callback set_encoding(atom) :: :ok | {:error, term}

  @doc "Returns true when the device is a terminal."
  @callback terminal?() :: boolean

  @doc "Returns the terminal size in columns and rows."
  @callback size() :: {:ok, {pos_integer, pos_integer}} | {:error, term}

  @doc "Puts the terminal in raw input mode."
  @callback enter_raw() :: :ok | {:error, term}

  @doc "Returns the terminal to cooked input mode."
  @callback leave_raw() :: :ok | {:error, term}

  @doc """
  Enables or disables the tty `ISIG` flag.

  Raw input mode as set up by OTP keeps `ISIG` on, so Ctrl+C never reaches the
  application as a byte. Turning it off is what makes Ctrl+C readable.
  """
  @callback set_isig(:on | :off) :: :ok | {:error, term}
end

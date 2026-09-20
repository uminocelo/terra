defmodule Terra.Terminal do
  @moduledoc """
  Owns the terminal while an app runs and gives it back on every exit path.

  ## The restore contract

  `enter/1` puts the terminal in raw mode, switches to the alternate screen, and
  hides the cursor. From that point on, the terminal child process
  (`Terra.Terminal.Owner`) watches for every way out it can observe:

  - `exit/0` (also available as `restore/0`)
  - `:quit` or `:interrupt` handled by the runtime
  - a raised callback, by the runtime restoring and re-raising
  - the death of the process that called `enter/1` (monitored)
  - a linked process death or the owner terminating (both restore)

  Restoring means: reset attributes, show the cursor, leave the alternate
  screen, re-enable the tty `ISIG` flag, restore the previous device encoding,
  and return to cooked input mode. It is idempotent, so an extra `exit/0` after
  a crash is harmless.

  What cannot be observed: `:kill`, a VM crash, or `SIGINT` delivered from
  outside the terminal. Ctrl+C is handled as a byte (`{:interrupt}`) instead,
  which is why `enter/1` disables `ISIG`: raw mode as set up by OTP leaves it
  on, and with it on the tty swallows Ctrl+C without telling anyone.

  ## Size

  Size comes from `:io.columns/1` and `:io.rows/1` on `:standard_error`, which
  is a real tty even when stdout is redirected. Fallbacks, in order:
  `COLUMNS`/`LINES`, then 80x24. See `Terra.Terminal.TTY.size_from_env/0`.

  ## Testing

  Pass a `:backend` implementing `Terra.Terminal.Backend` to exercise the flow
  without a TTY:

      Terra.Terminal.enter(backend: MyCaptureBackend)
  """

  alias Terra.Terminal.{ANSI, Owner, TTY}

  @type info :: Owner.info()

  @doc """
  Starts the terminal owner process.

  The calling process becomes the owner and is monitored, so its death restores
  the terminal. Options: `:backend` (default `Terra.Terminal.TTY`) and `:owner`.
  """
  @spec start(keyword) :: GenServer.on_start()
  def start(opts \\ []), do: Owner.start(opts)

  @doc """
  Takes the terminal: raw mode, alternate screen, hidden cursor.

  Returns `{:ok, info}` where `info.raw?` reports whether raw input mode was
  actually available, and `info.size` the terminal size in `{columns, rows}`.
  Calling `enter/1` twice returns the same info without doing anything twice.
  """
  @spec enter(keyword) :: {:ok, info} | {:error, term}
  def enter(opts \\ []), do: Owner.enter(opts)

  @doc "Restores the terminal and stops the owner. Safe to call when nothing is running."
  @spec exit() :: :ok
  def exit, do: Owner.exit()

  @doc "Alias for `exit/0`, for call sites that read better as a restore."
  @spec restore() :: :ok
  def restore, do: Owner.exit()

  @doc "Stops the owner, restoring the terminal first."
  @spec stop() :: :ok
  def stop, do: Owner.stop()

  @doc "Returns terminal ownership info, or nil when no owner is running."
  @spec info() :: info | nil
  def info, do: Owner.info()

  @doc "Returns true when raw input mode is active."
  @spec raw?() :: boolean
  def raw?, do: match?(%{raw?: true}, info())

  @doc "Returns true when the terminal is currently held."
  @spec entered?() :: boolean
  def entered?, do: match?(%{entered?: true}, info())

  @doc """
  Writes raw bytes to the terminal.

  Prefer one call per frame: every call is a message to the owner process.
  """
  @spec write(iodata) :: :ok | {:error, term}
  def write(data), do: Owner.write(data)

  @doc "Returns the terminal size as `{columns, rows}`."
  @spec size() :: {pos_integer, pos_integer}
  def size do
    case Owner.size() do
      nil -> fallback_size()
      size -> size
    end
  end

  @doc "Returns the terminal width in columns."
  @spec columns() :: pos_integer
  def columns, do: size() |> elem(0)

  @doc "Returns the terminal height in rows."
  @spec rows() :: pos_integer
  def rows, do: size() |> elem(1)

  @doc "Enters (`true`) or leaves (`false`) the alternate screen."
  @spec alt_screen(boolean) :: :ok | {:error, term}
  def alt_screen(flag) when is_boolean(flag), do: write(ANSI.alt_screen(flag))

  @doc "Hides or shows the cursor."
  @spec cursor(:hide | :show) :: :ok | {:error, term}
  def cursor(flag) when flag in [:hide, :show], do: write(ANSI.cursor(flag))

  @doc "Hides the cursor."
  @spec hide_cursor() :: :ok | {:error, term}
  def hide_cursor, do: cursor(:hide)

  @doc "Shows the cursor."
  @spec show_cursor() :: :ok | {:error, term}
  def show_cursor, do: cursor(:show)

  @doc "Resets all character attributes."
  @spec reset() :: :ok | {:error, term}
  def reset, do: write(ANSI.reset())

  @doc "Clears the screen. The renderer pairs this with `home/0` for a full redraw."
  @spec clear() :: :ok | {:error, term}
  def clear, do: write(ANSI.clear())

  @doc "Moves the cursor to the home position."
  @spec home() :: :ok | {:error, term}
  def home, do: write(ANSI.home())

  @doc "Moves the cursor to `row`/`col`, both 1-based."
  @spec move(pos_integer, pos_integer) :: :ok | {:error, term}
  def move(row, col), do: write(ANSI.move(row, col))

  defp fallback_size do
    TTY.size() |> elem(1)
  end
end

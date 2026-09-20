defmodule Terra.Terminal.TTY do
  @moduledoc """
  Default `Terra.Terminal.Backend`, built on OTP only.

  Raw mode comes from `:shell.start_interactive({:noshell, :raw})` (OTP 28+).
  The tty `ISIG` flag is changed with `stty`, spawned through a port opened with
  `:nouse_stdio` so the child inherits this VM's stdin, which is the tty. That
  indirection is needed because `/dev/tty` is not reachable from a port child
  when the VM has no controlling terminal to hand it.
  """

  @behaviour Terra.Terminal.Backend

  @default_size {80, 24}
  @stty_timeout 2_000

  @impl true
  def write(data), do: IO.binwrite(:stdio, data)

  @impl true
  def encoding do
    :io.getopts(:standard_io)[:encoding]
  rescue
    _error -> nil
  end

  @impl true
  def set_encoding(encoding) do
    :io.setopts(:standard_io, encoding: encoding)
  rescue
    _error -> {:error, :enotsup}
  end

  @impl true
  def terminal? do
    :io.getopts(:standard_io)[:terminal] == true
  rescue
    _error -> false
  end

  @impl true
  @doc """
  Never fails: when the tty does not answer, `COLUMNS`/`LINES` are used, then 80x24.
  """
  @spec size() :: {:ok, {pos_integer, pos_integer}}
  def size do
    case {columns(:standard_error), rows(:standard_error)} do
      {{:ok, cols}, {:ok, rows}} -> {:ok, {cols, rows}}
      _other -> size_from_env()
    end
  end

  @doc """
  Size fallback used when the tty does not answer `:io.columns/1`.

  Order: `COLUMNS`/`LINES`, then 80x24. The tty itself is asked on
  `:standard_error`, which stays a real terminal even when stdout is redirected.
  """
  @spec size_from_env() :: {:ok, {pos_integer, pos_integer}}
  def size_from_env do
    case {env_int("COLUMNS"), env_int("LINES")} do
      {{:ok, cols}, {:ok, rows}} -> {:ok, {cols, rows}}
      _other -> {:ok, @default_size}
    end
  end

  @impl true
  def enter_raw do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :enotsup}
  end

  @impl true
  def leave_raw do
    case :shell.start_interactive({:noshell, :cooked}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :enotsup}
  end

  @impl true
  def set_isig(flag) when flag in [:on, :off] do
    case System.find_executable("sh") do
      nil -> {:error, :no_shell}
      sh -> run_stty(sh, if(flag == :off, do: "-isig", else: "isig"))
    end
  end

  defp run_stty(sh, flags) do
    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        args: ["-c", "stty #{flags} 2>/dev/null"]
      ])

    result =
      receive do
        {^port, {:exit_status, 0}} -> :ok
        {^port, {:exit_status, status}} -> {:error, {:stty_exit, status}}
      after
        @stty_timeout -> {:error, :timeout}
      end

    close_port(port)
    result
  rescue
    _error -> {:error, :enotsup}
  end

  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  defp columns(device), do: :io.columns(device)
  defp rows(device), do: :io.rows(device)

  defp env_int(name) do
    case System.get_env(name) do
      nil ->
        :error

      value ->
        case Integer.parse(value) do
          {int, _rest} when int > 0 -> {:ok, int}
          _other -> :error
        end
    end
  end
end

defmodule Terra.Command do
  @moduledoc """
  Commands are data returned from `init/1` and `update/2`, executed by the
  runtime off the view path.

  ## Shapes

    * `{:tick, ms, msg}`: after `ms` milliseconds, `update/2` receives `msg`.
    * `{:read_file, path, msg}`: `update/2` receives `{msg, result}` where
      `result` is the `File.read/1` tuple.
    * `{:port, cmd, msg}`: runs `cmd` through the shell. When the command
      finishes, `update/2` receives `{msg, {:ok, {lines, status}}}`, where
      `lines` is the collected output split on newlines and `status` the exit
      status. When the port cannot start, is closed, or crashes, `update/2`
      receives `{msg, {:error, reason}}` instead.

  A non-zero exit status is not an error: the command ran and produced output,
  and the app decides what that output means (a failing `mix test` run is still
  parseable). `{:error, reason}` means there is no usable output.

  `view/1` is never invoked to run a command; results arrive in `update/2` like
  any other message, and the terminal restore contract is unchanged.
  """

  @type t ::
          {:tick, non_neg_integer, term}
          | {:read_file, Path.t(), term}
          | {:port, binary, term}

  @doc false
  @spec run(t(), pid) :: pid
  def run({:read_file, path, msg}, runtime) when is_binary(path) do
    spawn_link(fn -> send(runtime, {:terra_command, self(), msg, File.read(path)}) end)
  end

  def run({:port, cmd, msg}, runtime) when is_binary(cmd) do
    spawn_link(fn -> send(runtime, {:terra_command, self(), msg, run_port(cmd)}) end)
  end

  defp run_port(cmd) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :stream,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", cmd]
      ])

    collect(port, :erlang.monitor(:port, port), [])
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp collect(port, monitor, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect(port, monitor, [data | chunks])

      {^port, {:exit_status, status}} ->
        :erlang.demonitor(monitor, [:flush])
        {:ok, {to_lines(chunks), status}}

      {:DOWN, ^monitor, :port, ^port, reason} ->
        {:error, reason}
    end
  end

  defp to_lines(chunks) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
  end
end

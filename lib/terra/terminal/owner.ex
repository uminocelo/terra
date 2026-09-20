defmodule Terra.Terminal.Owner do
  @moduledoc """
  Process that owns the terminal for the lifetime of an application.

  It enters raw mode and the alternate screen on `enter/1`, and it restores on
  every path it can observe:

  - an explicit `exit/0`
  - the death of the process that started it (monitored)
  - a linked process death (exits are trapped)
  - its own termination through `terminate/2` (`:kill` excluded)

  Restore is idempotent: the escape sequence and the tty flags are only written
  while the terminal is actually held.
  """

  use GenServer

  alias Terra.Terminal.ANSI

  @name __MODULE__
  @timeout 5_000

  defstruct backend: Terra.Terminal.TTY,
            owner: nil,
            monitor: nil,
            entered?: false,
            raw?: false,
            terminal?: false,
            isig?: false,
            encoding: nil,
            size: {80, 24}

  @type info :: %{
          size: {pos_integer, pos_integer},
          raw?: boolean,
          terminal?: boolean,
          entered?: boolean
        }

  @spec start(keyword) :: GenServer.on_start()
  def start(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :owner, fn -> self() end)

    case whereis() do
      nil -> GenServer.start(__MODULE__, opts, name: @name)
      pid -> {:ok, pid}
    end
  end

  @spec whereis() :: pid | nil
  def whereis do
    case GenServer.whereis(@name) do
      pid when is_pid(pid) -> pid
      _other -> nil
    end
  end

  @doc "Starts the owner when needed, then takes the terminal."
  @spec enter(keyword) :: {:ok, info} | {:error, term}
  def enter(opts \\ []) do
    case ensure_started(opts) do
      {:ok, pid} -> call_or({:enter, opts}, pid, {:error, :not_running})
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_started(opts) do
    case whereis() do
      nil -> start(opts)
      pid -> {:ok, pid}
    end
  end

  @doc "Restores the terminal and stops the owner. Safe to call twice."
  @spec exit() :: :ok
  def exit do
    case whereis() do
      nil -> :ok
      pid -> call_or(:exit, pid, :ok)
    end
  end

  @doc "Stops the owner, restoring the terminal first."
  @spec stop() :: :ok
  def stop do
    exit()
  end

  @spec write(iodata) :: :ok | {:error, term}
  def write(data) do
    case whereis() do
      nil -> Terra.Terminal.TTY.write(data)
      pid -> call_or({:write, data}, pid, :ok)
    end
  end

  @spec info() :: info | nil
  def info do
    case whereis() do
      nil -> nil
      pid -> call_or(:info, pid, nil)
    end
  end

  @spec size() :: {pos_integer, pos_integer} | nil
  def size do
    case info() do
      %{size: size} -> size
      _other -> nil
    end
  end

  defp call_or(message, pid, fallback) do
    GenServer.call(pid, message, @timeout)
  catch
    :exit, _reason -> fallback
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.get(opts, :owner, self())
    backend = Keyword.get(opts, :backend, Terra.Terminal.TTY)
    monitor = if is_pid(owner) and owner != self(), do: Process.monitor(owner)

    {:ok, %__MODULE__{owner: owner, backend: backend, monitor: monitor}}
  end

  @impl true
  def handle_call({:enter, _opts}, _from, %__MODULE__{entered?: true} = state) do
    {:reply, {:ok, info(state)}, state}
  end

  def handle_call({:enter, _opts}, _from, state) do
    state = do_enter(state)
    {:reply, {:ok, info(state)}, state}
  end

  def handle_call(:exit, _from, state) do
    {:stop, :normal, :ok, do_restore(state)}
  end

  def handle_call({:write, data}, _from, state) do
    {:reply, state.backend.write(data), state}
  end

  def handle_call(:info, _from, state) do
    {:reply, info(state), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{monitor: ref} = state) do
    {:stop, :normal, do_restore(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # Ports are linked to the process that opened them and send an EXIT when they
  # close. The terminal backend uses a short-lived port for `stty`, so its normal
  # exit must not be mistaken for a linked process dying: that would restore the
  # terminal the moment we took it.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, do_restore(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: do_restore(state)

  defp do_enter(state) do
    backend = state.backend
    terminal? = backend.terminal?()
    raw? = terminal? and backend.enter_raw() == :ok
    state = %{state | terminal?: terminal?, raw?: raw?}

    state =
      if raw? do
        encoding = backend.encoding()
        backend.set_encoding(:latin1)

        %{state | encoding: encoding, isig?: backend.set_isig(:off) == :ok}
      else
        state
      end

    backend.write(ANSI.alt_screen(true) <> ANSI.cursor(:hide))
    %{state | entered?: true, size: query_size(backend)}
  end

  defp do_restore(%__MODULE__{entered?: false} = state), do: state

  defp do_restore(state) do
    backend = state.backend

    # Restore is best effort: it runs from terminate/2 and during shutdown, so a
    # backend that is already gone must not turn cleanup into a crash.
    safe(fn -> backend.write(ANSI.reset() <> ANSI.cursor(:show) <> ANSI.alt_screen(false)) end)

    if state.isig?, do: safe(fn -> backend.set_isig(:on) end)

    if state.raw? do
      safe(fn -> backend.set_encoding(state.encoding || :unicode) end)
      safe(fn -> backend.leave_raw() end)
    end

    %{state | entered?: false, raw?: false, isig?: false}
  end

  defp safe(fun) do
    fun.()
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp query_size(backend) do
    case backend.size() do
      {:ok, size} -> size
      _other -> {80, 24}
    end
  end

  defp info(state) do
    %{
      size: state.size,
      raw?: state.raw?,
      terminal?: state.terminal?,
      entered?: state.entered?
    }
  end
end

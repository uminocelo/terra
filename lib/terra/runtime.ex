defmodule Terra.Runtime do
  @moduledoc """
  The process that runs one Terra app.

  It owns the terminal (when live), the input reader, tick timers, running
  commands and the last rendered frame, and it feeds events through the app's
  `event_to_msg/2` and `update/2`.

  Everything that can escape to the user goes through one boundary: a callback that
  raises does not crash quietly inside the loop. The runtime restores the terminal,
  then exits with `{:callback_error, kind, reason, stacktrace}`. `Terra.run/1`
  re-raises that original error, so it is never swallowed.

  ## Restore on every path

  - `update/2` returns `{:quit, state}` or the reader sees `:interrupt`
  - the owner process dies (monitored)
  - `init/1`, `update/2` or `view/1` raises
  - the runtime is stopped or shut down

  Restore is delegated to `Terra.Terminal`, which is idempotent.

  ## Options

  | Option | Default | Meaning |
  | --- | --- | --- |
  | `:owner` | calling process | process notified on completion and monitored for death |
  | `:app` | `[]` | options passed to `init/1` |
  | `:terminal` | `true` | take the terminal (raw mode, alt screen). `false` is headless |
  | `:terminal_backend` | `Terra.Terminal.TTY` | terminal backend, injectable for tests |
  | `:read` | value of `:terminal` | start the stdin reader |
  | `:input_backend` | `Terra.Input.TTY` | input backend, injectable for tests |
  | `:width`, `:height` | terminal size, else 80x24 | render size |
  | `:theme` | `Terra.Theme.default/0` | colors views read at render time |
  | `:events` | `[]` | events to apply right after `init/1` |

  ## Resize

  When live, the runtime subscribes to `SIGWINCH` and pushes `{:resize, w, h}` to
  `update/2` whenever the size actually changed, then repaints from scratch so a
  shrink cannot leave old cells behind. `resize/1` re-queries the size and
  `resize/3` sets it explicitly; both push the same event.
  """

  use GenServer

  alias Terra.{Input, Renderer, Terminal}
  alias Terra.Runtime.SignalHandler

  @required_callbacks [init: 1, update: 2, view: 1]
  @call_timeout 5_000

  defstruct module: nil,
            app_state: nil,
            owner: nil,
            monitor: nil,
            entered?: false,
            terminal?: false,
            terminal_backend: nil,
            input: nil,
            width: 80,
            height: 24,
            timers: [],
            commands: [],
            resize?: false,
            theme: nil,
            prev_grid: nil,
            last_frame: ""

  @type t :: %__MODULE__{}

  @doc """
  Starts a runtime without linking it to the caller, so a callback crash cannot
  take the caller down before `Terra.run/1` can re-raise it.
  """
  @spec start(module, keyword) :: GenServer.on_start()
  def start(module, opts \\ []) do
    GenServer.start(__MODULE__, {module, opts})
  end

  @doc "Stops a runtime, restoring the terminal first when it held one."
  @spec stop(GenServer.server()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @doc "Re-queries the terminal size and pushes `{:resize, w, h}`."
  @spec resize(GenServer.server()) :: :ok
  def resize(pid), do: GenServer.call(pid, :resize, @call_timeout)

  @doc "Sets the render size and pushes `{:resize, w, h}`."
  @spec resize(GenServer.server(), pos_integer, pos_integer) :: :ok
  def resize(pid, width, height), do: GenServer.call(pid, {:resize, width, height}, @call_timeout)

  @doc """
  Runs an app until it quits and returns `{:ok, final_state}`.

  Re-raises the original error after restoring the terminal when a callback blows
  up, and raises `ArgumentError` when the module is missing required callbacks.
  """
  @spec run(module, keyword) :: {:ok, term} | {:error, term} | no_return
  def run(module, opts \\ []) do
    opts = Keyword.put(opts, :owner, self())

    with :ok <- validate(module),
         {:ok, pid} <- start(module, opts) do
      await(pid)
    else
      {:error, {:missing_callbacks, missing}} ->
        raise ArgumentError, missing_message(module, missing)

      {:error, {:callback_error, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns `:ok` or `{:error, {:missing_callbacks, [{fun, arity}]}}`."
  @spec validate(module) :: :ok | {:error, {:missing_callbacks, [{atom, arity}]}}
  def validate(module) do
    Code.ensure_loaded(module)

    missing =
      for {fun, arity} <- @required_callbacks,
          not function_exported?(module, fun, arity),
          do: {fun, arity}

    case missing do
      [] -> :ok
      missing -> {:error, {:missing_callbacks, missing}}
    end
  end

  @doc false
  def missing_message(module, missing) do
    list = Enum.map_join(missing, ", ", fn {fun, arity} -> "#{fun}/#{arity}" end)

    "Terra app #{inspect(module)} is missing required callbacks: #{list}. " <>
      "Define them, or `use Terra` and implement init/1, update/2 and view/1."
  end

  defp await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:terra_runtime, ^pid, {:done, state}} ->
        Process.demonitor(ref, [:flush])
        {:ok, state}

      {:DOWN, ^ref, :process, ^pid, {:callback_error, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init({module, opts}) do
    Process.flag(:trap_exit, true)
    Code.ensure_loaded(module)

    state = %__MODULE__{
      module: module,
      owner: Keyword.get(opts, :owner, self()),
      terminal?: Keyword.get(opts, :terminal, true),
      terminal_backend: Keyword.get(opts, :terminal_backend, Terminal.TTY),
      theme: Keyword.get(opts, :theme),
      width: Keyword.get(opts, :width, 80),
      height: Keyword.get(opts, :height, 24)
    }

    state = %{state | monitor: monitor_owner(state.owner)}

    case enter(state) do
      {:ok, state} ->
        state = %{state | resize?: subscribe_resize(state)}

        case init_app(state, opts) do
          {:ok, state} ->
            state
            |> start_input(opts)
            |> start_events(opts)
            |> start_app()

          {:error, error} ->
            restore(state)
            {:stop, error}
        end

      {:error, error} ->
        {:stop, error}
    end
  end

  defp start_app(state) do
    case render(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, error} ->
        restore(state)
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:keys, events}, _from, state) do
    case deliver(state, events) do
      {:ok, state} -> {:reply, :ok, state}
      {:quit, state} -> finish_call(state, :ok)
      {:error, error, state} -> {:stop, error, :ok, state}
    end
  end

  def handle_call(:resize, _from, state) do
    {width, height} = Terminal.size()
    resize_and_reply(state, width, height)
  end

  def handle_call({:resize, width, height}, _from, state) do
    resize_and_reply(state, width, height)
  end

  def handle_call(:frame, _from, state), do: {:reply, state.last_frame, state}
  def handle_call(:state, _from, state), do: {:reply, state.app_state, state}

  @impl true
  def handle_cast({:event, event}, state), do: handle_delivery(state, [event])

  @impl true
  def handle_info({:terra_input, :closed}, state), do: finish_stop(state)
  def handle_info({:terra_input, events}, state), do: handle_delivery(state, events)
  def handle_info({:terra_events, events}, state), do: handle_delivery(state, events)

  def handle_info(:terra_sigwinch, state) do
    {width, height} = Terminal.size()

    if {width, height} == {state.width, state.height} do
      {:noreply, state}
    else
      case push_resize(state, width, height) do
        {:ok, state} -> {:noreply, state}
        {:quit, state} -> finish_stop(state)
        {:error, error, state} -> {:stop, error, state}
      end
    end
  end

  def handle_info({:terra_tick, msg}, state) do
    case apply_update(state, msg) do
      {:ok, state} -> {:noreply, state}
      {:quit, state} -> finish_stop(state)
      {:error, error, state} -> {:stop, error, state}
    end
  end

  def handle_info({:terra_command, pid, msg, result}, state) do
    state = %{state | commands: List.delete(state.commands, pid)}

    case apply_update(state, {msg, result}) do
      {:ok, state} -> {:noreply, state}
      {:quit, state} -> finish_stop(state)
      {:error, error, state} -> {:stop, error, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, %__MODULE__{input: pid} = state) do
    {:noreply, %{state | input: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timers(state.timers)
    cancel_commands(state.commands)
    unsubscribe_resize(state)
    restore(state)
    :ok
  end

  defp resize_and_reply(state, width, height) do
    case push_resize(state, width, height) do
      {:ok, state} -> {:reply, :ok, state}
      {:quit, state} -> finish_call(state, :ok)
      {:error, error, state} -> {:stop, error, :ok, state}
    end
  end

  defp push_resize(state, width, height) do
    state = %{state | width: width, height: height, prev_grid: nil}
    apply_update(state, {:resize, width, height})
  end

  defp subscribe_resize(%__MODULE__{terminal?: false}), do: false

  defp subscribe_resize(_state) do
    with :ok <- safe_signal(),
         :ok <- safe_add_handler() do
      true
    else
      _other -> false
    end
  end

  defp safe_signal do
    :os.set_signal(:sigwinch, :handle)
  rescue
    _error -> {:error, :unsupported}
  catch
    _kind, _reason -> {:error, :unsupported}
  end

  defp safe_add_handler do
    :gen_event.add_handler(:erl_signal_server, SignalHandler, self())
  rescue
    _error -> {:error, :unsupported}
  catch
    _kind, _reason -> {:error, :unsupported}
  end

  defp unsubscribe_resize(%__MODULE__{resize?: false}), do: :ok

  defp unsubscribe_resize(_state) do
    :gen_event.delete_handler(:erl_signal_server, SignalHandler, :remove)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp handle_delivery(state, events) do
    case deliver(state, events) do
      {:ok, state} -> {:noreply, state}
      {:quit, state} -> finish_stop(state)
      {:error, error, state} -> {:stop, error, state}
    end
  end

  defp notify_done(state),
    do: send(state.owner, {:terra_runtime, self(), {:done, state.app_state}})

  defp finish_call(state, reply) do
    notify_done(state)
    {:stop, :normal, reply, state}
  end

  defp finish_stop(state) do
    notify_done(state)
    {:stop, :normal, state}
  end

  defp monitor_owner(owner) when is_pid(owner) and owner != self(), do: Process.monitor(owner)
  defp monitor_owner(_owner), do: nil

  defp enter(%__MODULE__{terminal?: false} = state), do: {:ok, state}

  defp enter(state) do
    case Terminal.enter(backend: state.terminal_backend, owner: self()) do
      {:ok, info} ->
        {:ok, %{state | entered?: true, width: elem(info.size, 0), height: elem(info.size, 1)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore(%__MODULE__{entered?: false}), do: :ok

  defp restore(state) do
    Terminal.exit()
    %{state | entered?: false}
  end

  defp init_app(state, opts) do
    app_opts = Keyword.get(opts, :app, [])

    case run_callback(fn -> state.module.init(app_opts) end) do
      {:ok, {app_state, commands}} when is_list(commands) ->
        {:ok, schedule(%{state | app_state: app_state}, commands)}

      {:ok, app_state} ->
        {:ok, %{state | app_state: app_state}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp start_input(state, opts) do
    default_read? = state.terminal?

    if Keyword.get(opts, :read, default_read?) do
      backend = Keyword.get(opts, :input_backend, Input.TTY)
      %{state | input: start_reader(backend)}
    else
      state
    end
  end

  defp start_reader(backend) do
    case Input.start(owner: self(), backend: backend) do
      {:ok, pid} -> pid
      {:error, _reason} -> nil
    end
  end

  defp start_events(state, opts) do
    case Keyword.get(opts, :events, []) do
      [] -> state
      events -> send(self(), {:terra_events, events})
    end

    state
  end

  defp deliver(state, events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case handle_event(state, event) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:quit, state} -> {:halt, {:quit, state}}
        {:error, error, state} -> {:halt, {:error, error, state}}
      end
    end)
  end

  defp handle_event(state, event) do
    interrupt? = event == :interrupt

    case map_event(state, event) do
      {:ok, :ignore} ->
        stop_or_continue(interrupt?, state)

      {:ok, msg} ->
        case apply_update(state, msg) do
          {:ok, state} -> stop_or_continue(interrupt?, state)
          other -> other
        end

      {:error, error, state} ->
        {:error, error, state}
    end
  end

  defp stop_or_continue(true, state), do: {:quit, state}
  defp stop_or_continue(false, state), do: {:ok, state}

  defp map_event(state, event) do
    module = state.module

    fun =
      if function_exported?(module, :event_to_msg, 2) do
        fn -> module.event_to_msg(event, state.app_state) end
      else
        fn -> event end
      end

    case run_callback(fun) do
      {:ok, msg} -> {:ok, msg}
      {:error, error} -> {:error, error, state}
    end
  end

  defp apply_update(state, msg) do
    case run_callback(fn -> state.module.update(msg, state.app_state) end) do
      {:ok, {:quit, app_state}} ->
        render_quit(%{state | app_state: app_state})

      {:ok, {app_state, commands}} when is_list(commands) ->
        state = schedule(%{state | app_state: app_state}, commands)
        render_step(state)

      {:ok, app_state} ->
        render_step(%{state | app_state: app_state})

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp render_step(state) do
    case render(state) do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:error, error, state}
    end
  end

  defp render_quit(state) do
    case render(state) do
      {:ok, state} -> {:quit, state}
      {:error, error} -> {:error, error, state}
    end
  end

  defp render(state) do
    case run_callback(fn -> state.module.view(state.app_state) end) do
      {:ok, view} -> {:ok, paint(state, view)}
      {:error, error} -> {:error, error}
    end
  end

  defp paint(%__MODULE__{terminal?: false} = state, view) do
    grid = grid(state, view)
    %{state | prev_grid: grid, last_frame: Renderer.to_text(grid)}
  end

  defp paint(state, view) do
    grid = grid(state, view)

    case Renderer.patch(state.prev_grid, grid) do
      "" -> state
      bytes -> write(state, bytes)
    end

    %{state | prev_grid: grid}
  end

  defp write(state, bytes) do
    case Terra.Terminal.write(bytes) do
      :ok -> state
      {:error, _reason} -> state
    end
  end

  defp grid(state, view) do
    Renderer.render(view, width: state.width, height: state.height, theme: state.theme)
  end

  defp schedule(state, commands) do
    Enum.reduce(commands, state, fn
      {:tick, ms, msg}, state when is_integer(ms) and ms >= 0 ->
        ref = Process.send_after(self(), {:terra_tick, msg}, ms)
        %{state | timers: [ref | state.timers]}

      {:read_file, _path, _msg} = command, state ->
        %{state | commands: [Terra.Command.run(command, self()) | state.commands]}

      {:port, _cmd, _msg} = command, state ->
        %{state | commands: [Terra.Command.run(command, self()) | state.commands]}

      _other, state ->
        state
    end)
  end

  defp cancel_timers(timers), do: Enum.each(timers, &Process.cancel_timer/1)

  defp cancel_commands(pids), do: Enum.each(pids, &Process.exit(&1, :kill))

  defp run_callback(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:error, {:callback_error, kind, reason, __STACKTRACE__}}
  end
end

defmodule Terra.Input do
  @moduledoc """
  Reads stdin bytes and emits the runtime event union.

  The process owns a buffer, not a terminal. Bytes arrive from a
  `Terra.Input.Backend` (one byte per read from `Terra.Input.TTY`), are appended to
  the buffer, and `Terra.Input.Parser` drains every complete event. A partial
  trailing sequence stays in the buffer for the next read, so an arrow or a
  multi-byte grapheme split across two reads is emitted exactly once.

  ## Events and control messages

  Events are sent to the owner process as a non-empty batch:

      {:terra_input, [event]}

  When the input closes (EOF, or `close/1`), the owner gets:

      {:terra_input, :closed}

  `:closed` is a control message, not an event. `:eof` never raises, and Ctrl+C is
  an event (`:interrupt`); restoring the terminal stays `Terra.Terminal`'s job.

  ## Ambiguous `ESC`

  A lone `ESC` could be an arrow sequence that has not finished arriving, so the
  parser holds it. After `:flush_ms` (default 50 ms) with no more bytes, the buffer
  is re-parsed with `flush: true`, which turns it into `:esc` and drops any other
  truncated sequence.

  ## Testing

  Pass a `:backend` implementing `Terra.Input.Backend`, or `read: false` to drive
  the process with `feed/2`. `Terra.Input.Parser.parse/2` is pure and covers the
  fixture cases on its own.
  """

  use GenServer, restart: :transient

  alias Terra.Input.Parser

  @default_flush_ms 50
  @default_read_timeout 1_000

  @type event :: Parser.event()
  @type option ::
          {:owner, pid}
          | {:backend, module}
          | {:flush_ms, non_neg_integer}
          | {:read_timeout, non_neg_integer}
          | {:read, boolean}

  defstruct owner: nil,
            backend: Terra.Input.TTY,
            flush_ms: @default_flush_ms,
            read_timeout: @default_read_timeout,
            monitor: nil,
            reader: nil,
            timer: nil,
            buffer: ""

  @doc "Like `parse/2`, on the pure parser."
  @spec parse(binary, keyword) :: {[event], binary}
  defdelegate parse(buffer, opts \\ []), to: Parser

  @doc "Starts the input process linked to the caller."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Starts the input process without linking."
  @spec start(keyword) :: GenServer.on_start()
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts)
  end

  @doc "Feeds raw bytes into the buffer, as a read would."
  @spec feed(GenServer.server(), binary) :: :ok
  def feed(pid, bytes) when is_binary(bytes) do
    GenServer.cast(pid, {:feed, bytes})
  end

  @doc "Closes the input stream. The owner receives `{:terra_input, :closed}`."
  @spec close(GenServer.server()) :: :ok
  def close(pid) do
    GenServer.cast(pid, :close)
  end

  @doc "Stops the input process without emitting more events."
  @spec stop(GenServer.server()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.get(opts, :owner, self())
    backend = Keyword.get(opts, :backend, Terra.Input.TTY)

    state = %__MODULE__{
      owner: owner,
      backend: backend,
      flush_ms: Keyword.get(opts, :flush_ms, @default_flush_ms),
      read_timeout: Keyword.get(opts, :read_timeout, @default_read_timeout),
      monitor: if(is_pid(owner), do: Process.monitor(owner))
    }

    state = if Keyword.get(opts, :read, true), do: start_reader(state), else: state

    {:ok, state}
  end

  @impl true
  def handle_cast({:feed, bytes}, state) do
    {:noreply, ingest(state, bytes)}
  end

  def handle_cast(:close, state) do
    {:stop, :normal, close_state(state)}
  end

  @impl true
  def handle_info({:input_data, bytes}, state) do
    {:noreply, ingest(state, bytes)}
  end

  def handle_info(:input_eof, state) do
    {:stop, :normal, close_state(state)}
  end

  def handle_info({:input_error, _reason}, state) do
    {:stop, :normal, close_state(state)}
  end

  def handle_info(:flush, state) do
    {events, _rest} = Parser.parse(state.buffer, flush: true)
    emit(state.owner, events)
    {:noreply, %{state | buffer: "", timer: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, %__MODULE__{reader: pid} = state) do
    {:noreply, %{state | reader: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer)
    :ok
  end

  defp start_reader(state) do
    server = self()
    backend = state.backend
    timeout = state.read_timeout

    reader =
      spawn_link(fn ->
        reader_loop(server, backend, timeout)
      end)

    %{state | reader: reader}
  end

  defp reader_loop(server, backend, timeout) do
    case backend.read(timeout) do
      {:ok, ""} ->
        reader_loop(server, backend, timeout)

      {:ok, bytes} when is_binary(bytes) ->
        send(server, {:input_data, bytes})
        reader_loop(server, backend, timeout)

      {:error, :timeout} ->
        reader_loop(server, backend, timeout)

      :eof ->
        send(server, :input_eof)

      {:error, reason} ->
        send(server, {:input_error, reason})
    end
  end

  defp ingest(state, bytes) do
    buffer = state.buffer <> bytes
    {events, rest} = Parser.parse(buffer)
    emit(state.owner, events)
    state = %{state | buffer: rest}
    reschedule(state)
  end

  defp close_state(state) do
    {events, _rest} = Parser.parse(state.buffer, flush: true)
    emit(state.owner, events)
    send(state.owner, {:terra_input, :closed})
    cancel_timer(state.timer)
    %{state | buffer: "", timer: nil}
  end

  defp reschedule(%__MODULE__{buffer: ""} = state) do
    cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp reschedule(state) do
    cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp emit(_owner, []), do: :ok
  defp emit(owner, events), do: send(owner, {:terra_input, events})
end

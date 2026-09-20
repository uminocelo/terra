defmodule Terra.Test do
  @moduledoc """
  Headless helpers for driving and snapshotting a Terra app.

  Snapshot rendering and simulated keys are the whole point of testing a TUI
  without a TTY, so they are a product feature, not a nice-to-have.

  ## Rendering a view

      defmodule Counter do
        use Terra
        def init(_opts), do: 0
        def update({:char, "j"}, n), do: n + 1
        def update(_event, n), do: n
        def view(n), do: box(text("Count: \#{n}"))
      end

      Terra.Test.render(Counter)
      #=> "┌─────────┐\\n│Count: 0 │\\n└─────────┘"

  ## Driving a running app

      machine = Terra.Test.start(Counter)
      machine |> Terra.Test.send_keys("jj") |> Terra.Test.render()
      #=> "┌─────────┐\\n│Count: 2 │\\n└─────────┘"

  `send_keys/2` accepts a string (each grapheme becomes `{:char, g}`), a single
  runtime event such as `:up` or `{:ctrl, :a}`, or a list of either. The machine
  runs headless: no terminal is taken and no stdin is read, so ticks still fire and
  every frame is a plain-text snapshot.
  """

  alias Terra.{Renderer, Runtime}

  @default_width 80
  @default_height 24
  @call_timeout 5_000

  @doc """
  Starts an app headlessly and returns the machine (a runtime process).

  Options are forwarded to `Terra.Runtime`. `:terminal` is forced to `false` and
  `:read` defaults to `false`; pass `:read, true` (plus a backend) if you want the
  reader running.
  """
  @spec start(module, keyword) :: pid
  def start(module, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:terminal, false)
      |> Keyword.put_new(:read, false)

    case Runtime.start(module, opts) do
      {:ok, pid} ->
        pid

      {:error, {:callback_error, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:error, reason} ->
        raise ArgumentError, "could not start Terra app: #{inspect(reason)}"
    end
  end

  @doc """
  Feeds keys or events to a machine and returns the machine.

  Safe to call after a quit: the machine stops, and the exit is swallowed so the
  caller can assert on the process being gone.
  """
  @spec send_keys(pid, term) :: pid
  def send_keys(pid, keys) when is_pid(pid) do
    try do
      GenServer.call(pid, {:keys, events(keys)}, @call_timeout)
    catch
      :exit, _reason -> :ok
    end

    pid
  end

  @doc """
  Returns a plain-text snapshot.

  With a machine pid, the current frame. With an app module or a view, that view
  rendered at the requested (or default 80x24) size. A module is initialized first,
  so its `init/1` options are `opts[:app]`.
  """
  @spec render(pid | module | Terra.View.t()) :: binary
  def render(pid) when is_pid(pid), do: GenServer.call(pid, :frame, @call_timeout)

  def render(target), do: render(target, [])

  @spec render(module | Terra.View.t(), keyword) :: binary
  def render(module, opts) when is_atom(module) do
    module
    |> initial_view(opts)
    |> render_view(opts)
  end

  def render(view, opts) when is_tuple(view), do: render_view(view, opts)

  @doc "Returns the machine's current app state."
  @spec state(pid) :: term
  def state(pid) when is_pid(pid), do: GenServer.call(pid, :state, @call_timeout)

  @doc "Re-queries the size and pushes `{:resize, w, h}` into the app."
  @spec resize(pid) :: :ok
  def resize(pid) when is_pid(pid), do: Runtime.resize(pid)

  @doc "Resizes the machine and pushes `{:resize, w, h}` into the app."
  @spec resize(pid, pos_integer, pos_integer) :: :ok
  def resize(pid, width, height) when is_pid(pid), do: Runtime.resize(pid, width, height)

  @doc "Stops a machine, restoring anything it held."
  @spec stop(pid) :: :ok
  def stop(pid) when is_pid(pid), do: GenServer.stop(pid, :normal)

  @doc """
  Normalizes keys into the runtime event union.

  A string becomes one `{:char, grapheme}` per grapheme; atoms and tuples pass
  through; lists are flattened.
  """
  @spec events(term) :: [Terra.event()]
  def events(binary) when is_binary(binary) do
    Enum.map(String.graphemes(binary), &{:char, &1})
  end

  def events(list) when is_list(list), do: Enum.flat_map(list, &events/1)
  def events(event), do: [event]

  defp render_view(view, opts) do
    opts =
      opts
      |> Keyword.put_new(:width, @default_width)
      |> Keyword.put_new(:height, @default_height)

    view
    |> Renderer.render(opts)
    |> Renderer.to_text()
  end

  defp initial_view(module, opts) do
    app_opts = Keyword.get(opts, :app, [])

    case module.init(app_opts) do
      {state, commands} when is_list(commands) -> module.view(state)
      state -> module.view(state)
    end
  end
end

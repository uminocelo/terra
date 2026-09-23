defmodule Terra.RuntimeTest.CaptureBackend do
  @moduledoc false
  @behaviour Terra.Terminal.Backend

  @name __MODULE__

  def start do
    case Agent.start(fn -> %{writes: []} end, name: @name) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        Agent.update(@name, fn _state -> %{writes: []} end)
        pid
    end
  end

  def stop do
    if pid = Process.whereis(@name) do
      try do
        Agent.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def output do
    Agent.get(@name, fn state -> state.writes |> Enum.reverse() |> IO.iodata_to_binary() end)
  end

  @impl true
  def write(data) do
    Agent.update(@name, fn state ->
      %{state | writes: [IO.iodata_to_binary(data) | state.writes]}
    end)

    :ok
  end

  @impl true
  def encoding, do: :unicode

  @impl true
  def set_encoding(_encoding), do: :ok

  @impl true
  def terminal?, do: true

  @impl true
  def size, do: {:ok, {100, 40}}

  @impl true
  def enter_raw, do: :ok

  @impl true
  def leave_raw, do: :ok

  @impl true
  def set_isig(_flag), do: :ok
end

defmodule Terra.RuntimeTest.Counter do
  @moduledoc false
  use Terra

  def init(_opts), do: 0

  def update({:char, "j"}, count), do: count + 1
  def update({:char, "k"}, count), do: count - 1
  def update({:char, "q"}, count), do: {:quit, count}
  def update(_event, count), do: count

  def view(count) do
    box([text("Count: #{count}"), text("j/k to change, q to quit")])
  end
end

defmodule Terra.RuntimeTest.Chain do
  @moduledoc false
  use Terra

  def init(_opts), do: {0, [{:tick, 5, :tick}]}

  def update(:tick, count) when count >= 3, do: {:quit, count}
  def update(:tick, count), do: {count + 1, [{:tick, 5, :tick}]}

  def view(count), do: text("n=#{count}")
end

defmodule Terra.RuntimeTest.Filter do
  @moduledoc false
  use Terra

  def init(_opts), do: 0
  def update(:hit, count), do: count + 1
  def update(_event, count), do: count

  def event_to_msg({:char, "x"}, _count), do: :hit
  def event_to_msg(_event, _count), do: :ignore

  def view(count), do: text("hits=#{count}")
end

defmodule Terra.RuntimeTest.BoomView do
  @moduledoc false
  use Terra

  def init(_opts), do: 0
  def update(_event, count), do: count
  def view(_count), do: raise("boom from view/1")
end

defmodule Terra.RuntimeTest.BoomUpdate do
  @moduledoc false
  use Terra

  def init(_opts), do: 0
  def update({:char, "x"}, _count), do: raise("boom from update/2")
  def update(_event, count), do: count
  def view(count), do: text("Count: #{count}")
end

defmodule Terra.RuntimeTest.NotAnApp do
  @moduledoc false
end

defmodule Terra.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Terra.{Renderer, Runtime, Terminal}
  alias Terra.RuntimeTest.{CaptureBackend, Chain, Counter, Filter}
  alias Terra.Terminal.ANSI

  setup do
    CaptureBackend.start()
    on_exit(&CaptureBackend.stop/0)
    on_exit(fn -> Terminal.exit() end)
    :ok
  end

  defp start_live(module, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:terminal, true)
      |> Keyword.put(:terminal_backend, CaptureBackend)
      |> Keyword.put_new(:read, false)
      |> Keyword.put(:owner, self())

    {:ok, pid} = Runtime.start(module, opts)
    pid
  end

  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(5)
        {:cont, false}
      end
    end)
  end

  describe "use Terra" do
    test "passes events through by default" do
      assert Counter.event_to_msg({:char, "j"}, 0) == {:char, "j"}
      assert Counter.event_to_msg(:up, 0) == :up
    end

    test "imports the view primitives unqualified" do
      assert Counter.view(0) ==
               Terra.View.box([
                 Terra.View.text("Count: 0"),
                 Terra.View.text("j/k to change, q to quit")
               ])
    end

    test "validate/1 reports missing callbacks" do
      assert :ok = Runtime.validate(Counter)

      assert {:error, {:missing_callbacks, missing}} =
               Runtime.validate(Terra.RuntimeTest.NotAnApp)

      assert Enum.any?(missing, fn {fun, _arity} -> fun == :init end)
    end
  end

  describe "Terra.run/1" do
    test "applies events headlessly and returns the final state on :quit" do
      events = [{:char, "j"}, {:char, "j"}, {:char, "q"}]
      assert Runtime.run(Counter, terminal: false, events: events) == {:ok, 2}
    end

    test "keeps running while ticks are scheduled and stops on :quit" do
      assert Runtime.run(Chain, terminal: false) == {:ok, 3}
    end

    test "restores, then re-raises a raised view/1" do
      capture_log(fn ->
        assert_raise RuntimeError, "boom from view/1", fn ->
          Runtime.run(Terra.RuntimeTest.BoomView, terminal: true, terminal_backend: CaptureBackend)
        end
      end)

      assert CaptureBackend.output() =~ ANSI.alt_screen(false)
      assert Terminal.info() == nil
    end

    test "raises a clear error when required callbacks are missing" do
      assert_raise ArgumentError, ~r/missing required callbacks/, fn ->
        Runtime.run(Terra.RuntimeTest.NotAnApp, terminal: false)
      end
    end
  end

  describe "headless machine" do
    test "keys update state and the snapshot" do
      machine = Terra.Test.start(Counter)

      assert Terra.Test.render(machine) =~ "Count: 0"

      Terra.Test.send_keys(machine, "jj")
      assert Terra.Test.state(machine) == 2
      assert Terra.Test.render(machine) =~ "Count: 2"

      Terra.Test.send_keys(machine, "k")
      assert Terra.Test.render(machine) =~ "Count: 1"

      Runtime.stop(machine)
    end

    test "a quit key stops the machine" do
      machine = Terra.Test.start(Counter)
      ref = Process.monitor(machine)

      Terra.Test.send_keys(machine, "q")
      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
    end

    test ":interrupt stops the machine too" do
      machine = Terra.Test.start(Counter)
      ref = Process.monitor(machine)

      Terra.Test.send_keys(machine, [:interrupt])
      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
    end

    test "event_to_msg can ignore and remap events" do
      machine = Terra.Test.start(Filter)

      Terra.Test.send_keys(machine, "xx")
      assert Terra.Test.state(machine) == 2

      Terra.Test.send_keys(machine, [:up])
      assert Terra.Test.state(machine) == 2

      Runtime.stop(machine)
    end

    test "a tick scheduled by init fires without a TTY" do
      machine = Terra.Test.start(Chain)
      assert eventually(fn -> Terra.Test.state(machine) == 3 end)
      ref = Process.monitor(machine)
      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
    end

    test "a raised update/2 exits with the original error" do
      machine = Terra.Test.start(Terra.RuntimeTest.BoomUpdate)
      ref = Process.monitor(machine)

      capture_log(fn ->
        Terra.Test.send_keys(machine, "x")

        assert_receive {:DOWN, ^ref, :process, ^machine,
                        {:callback_error, :error, %RuntimeError{message: "boom from update/2"},
                         _stack}}
      end)
    end
  end

  describe "live machine restore" do
    test "quitting with q restores the terminal" do
      machine = start_live(Counter)
      ref = Process.monitor(machine)

      Terra.Test.send_keys(machine, "q")

      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
      assert CaptureBackend.output() =~ ANSI.alt_screen(false)
      assert CaptureBackend.output() =~ ANSI.cursor(:show)
      assert Terminal.info() == nil
    end

    test ":interrupt restores the terminal" do
      machine = start_live(Counter)
      ref = Process.monitor(machine)

      Terra.Test.send_keys(machine, [:interrupt])

      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
      assert CaptureBackend.output() =~ ANSI.alt_screen(false)
      assert Terminal.info() == nil
    end

    test "a raised view/1 restores before the error surfaces" do
      capture_log(fn ->
        assert {:error, {:callback_error, :error, %RuntimeError{}, _stack}} =
                 Runtime.start(Terra.RuntimeTest.BoomView,
                   terminal: true,
                   terminal_backend: CaptureBackend,
                   read: false,
                   owner: self()
                 )
      end)

      assert CaptureBackend.output() =~ ANSI.alt_screen(false)
      assert Terminal.info() == nil
    end

    test "a killed runtime still restores the terminal" do
      machine = start_live(Counter)
      ref = Process.monitor(machine)

      Process.exit(machine, :kill)

      assert_receive {:DOWN, ^ref, :process, ^machine, :killed}
      assert eventually(fn -> CaptureBackend.output() =~ ANSI.alt_screen(false) end)
      assert eventually(fn -> Terminal.info() == nil end)
    end

    test "paints the first frame fully, then only changed cells" do
      machine = start_live(Counter)

      first = CaptureBackend.output()
      assert first =~ ANSI.clear()
      assert first =~ ANSI.home()
      assert first =~ "Count: 0"

      Terra.Test.send_keys(machine, "j")
      patch = String.replace_prefix(CaptureBackend.output(), first, "")
      refute patch == ""
      refute patch =~ ANSI.clear()
      assert patch =~ "1"
      refute patch =~ "Count"

      Runtime.stop(machine)
    end
  end

  describe "Terra.Test.render/2" do
    test "renders a view directly" do
      assert Terra.Test.render(Terra.View.text("hi"), width: 4, height: 2) == "hi"
    end

    test "renders a module's initial view" do
      snapshot = Terra.Test.render(Counter, width: 30, height: 5)
      assert snapshot =~ "Count: 0"
      assert snapshot =~ "j/k to change"
    end

    test "matches the frame the machine holds" do
      machine = Terra.Test.start(Counter, width: 30, height: 5)
      assert Terra.Test.render(machine) == Terra.Test.render(Counter, width: 30, height: 5)
      Runtime.stop(machine)
    end
  end

  describe "Renderer.paint/2" do
    test "is the same bytes the runtime writes" do
      machine = start_live(Counter)
      view = Counter.view(0)

      assert {:ok, bytes} = Renderer.paint(view, width: 100, height: 40)
      assert CaptureBackend.output() =~ bytes
      Runtime.stop(machine)
    end
  end
end

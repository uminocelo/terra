defmodule Terra.ResizeTest.ResizeApp do
  @moduledoc false
  use Terra

  def init(_opts), do: %{size: nil, resizes: 0}

  def update({:resize, width, height}, state) do
    %{state | size: {width, height}, resizes: state.resizes + 1}
  end

  def update(_msg, state), do: state

  def view(state) do
    box(text("size: #{inspect(state.size)}"), title: "Resize")
  end
end

defmodule Terra.ResizeTest do
  use ExUnit.Case, async: false

  alias Terra.Runtime
  alias Terra.Terminal.ANSI
  alias Terra.View

  defmodule CaptureBackend do
    @moduledoc false
    @behaviour Terra.Terminal.Backend

    @name __MODULE__

    def start do
      case Agent.start(fn -> [] end, name: @name) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          Agent.update(@name, fn _writes -> [] end)
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
      Agent.get(@name, fn writes -> writes |> Enum.reverse() |> IO.iodata_to_binary() end)
    end

    def reset, do: Agent.update(@name, fn _writes -> [] end)

    @impl true
    def write(data) do
      Agent.update(@name, fn writes -> [IO.iodata_to_binary(data) | writes] end)
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

  setup do
    CaptureBackend.start()

    on_exit(fn ->
      Terra.Terminal.exit()
      CaptureBackend.stop()
    end)

    :ok
  end

  describe "Terra.Test.resize" do
    test "pushes {:resize, w, h} into update/2" do
      machine = Terra.Test.start(Terra.ResizeTest.ResizeApp, width: 40, height: 8)

      assert Terra.Test.state(machine).size == nil

      Terra.Test.resize(machine, 20, 4)
      assert Terra.Test.state(machine).size == {20, 4}
      assert Terra.Test.state(machine).resizes == 1

      Terra.Test.resize(machine, 20, 4)
      assert Terra.Test.state(machine).resizes == 2

      Terra.Test.stop(machine)
    end

    test "re-renders at the new size" do
      machine = Terra.Test.start(Terra.ResizeTest.ResizeApp, width: 40, height: 8)
      assert Terra.Test.render(machine) =~ "size: nil"

      Terra.Test.resize(machine, 12, 4)
      snapshot = Terra.Test.render(machine)

      assert snapshot =~ "Resize"
      assert snapshot |> String.split("\n") |> length() == 4
      assert snapshot |> String.split("\n") |> hd() |> String.length() == 12

      Terra.Test.stop(machine)
    end
  end

  describe "size snapshots" do
    test "a smaller size produces a smaller snapshot" do
      view = View.box(View.vstack([View.text("one"), View.text("two")]))

      large = Terra.Test.render(view, width: 30, height: 8)
      small = Terra.Test.render(view, width: 12, height: 4)

      assert String.length(small) < String.length(large)
      assert small |> String.split("\n") |> length() < large |> String.split("\n") |> length()
    end
  end

  describe "live resize" do
    defp start_live do
      {:ok, pid} =
        Runtime.start(Terra.ResizeTest.ResizeApp,
          terminal: true,
          terminal_backend: CaptureBackend,
          read: false,
          owner: self()
        )

      pid
    end

    test "a shrink repaints from scratch so no old cells are left" do
      machine = start_live()
      first = CaptureBackend.output()
      assert first =~ ANSI.clear() <> ANSI.home()

      CaptureBackend.reset()
      Runtime.resize(machine, 20, 5)
      patch = CaptureBackend.output()

      assert patch =~ ANSI.clear() <> ANSI.home()
      assert patch =~ ANSI.move(5, 1)
      refute patch =~ ANSI.move(6, 1)
      assert Terra.Test.state(machine).size == {20, 5}

      Runtime.stop(machine)
    end

    test "resize/1 re-queries the terminal size" do
      machine = start_live()
      assert Terra.Test.state(machine).size == nil

      Runtime.resize(machine)
      assert Terra.Test.state(machine).size == {100, 40}

      Runtime.stop(machine)
    end
  end

  describe "Renderer.size/1" do
    test "uses the given dimensions without depending on the terminal" do
      assert Terra.Renderer.size(width: 12, height: 5) == {12, 5}

      snapshot =
        View.text("hi") |> Terra.Renderer.render(width: 12, height: 5) |> Terra.Renderer.to_text()

      assert snapshot == "hi"
    end
  end

  describe "SIGWINCH handler" do
    test "forwards :sigwinch to the target process" do
      me = self()

      assert {:ok, ^me} = Terra.Runtime.SignalHandler.init(me)
      assert {:ok, ^me} = Terra.Runtime.SignalHandler.handle_event(:sigwinch, me)
      assert_receive :terra_sigwinch

      assert {:ok, ^me} = Terra.Runtime.SignalHandler.handle_event(:sigterm, me)
      refute_receive :terra_sigwinch, 20
    end

    test "implements the gen_event callbacks" do
      me = self()

      assert {:ok, :ok, ^me} = Terra.Runtime.SignalHandler.handle_call(:anything, me)
      assert {:ok, ^me} = Terra.Runtime.SignalHandler.handle_info(:anything, me)
      assert :ok = Terra.Runtime.SignalHandler.terminate(:normal, me)
      assert {:ok, ^me} = Terra.Runtime.SignalHandler.code_change(:old, me, :extra)
    end
  end
end

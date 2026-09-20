defmodule Terra.Terminal.CaptureBackend do
  @moduledoc false
  @behaviour Terra.Terminal.Backend

  @name __MODULE__

  def start do
    case Agent.start(fn -> initial() end, name: @name) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        Agent.update(@name, fn _state -> initial() end)
        pid
    end
  end

  def stop do
    if Process.whereis(@name), do: Agent.stop(@name)
  end

  def state, do: Agent.get(@name, & &1)
  def output, do: state().writes |> Enum.reverse() |> IO.iodata_to_binary()

  defp initial do
    %{
      writes: [],
      calls: [],
      encoding: :unicode,
      isig: :on,
      raw?: false,
      terminal?: true,
      stty_port?: false,
      size: {100, 40}
    }
  end

  defp record(fun), do: Agent.update(@name, fun)

  @impl true
  def write(data) do
    record(fn state -> %{state | writes: [IO.iodata_to_binary(data) | state.writes]} end)
    :ok
  end

  @impl true
  def encoding, do: :unicode

  @impl true
  def set_encoding(encoding) do
    record(fn state -> %{state | encoding: encoding, calls: [:set_encoding | state.calls]} end)
    :ok
  end

  @impl true
  def terminal?, do: state().terminal?

  @impl true
  def size, do: {:ok, state().size}

  @impl true
  def enter_raw do
    record(fn state -> %{state | raw?: true, calls: [:enter_raw | state.calls]} end)
    :ok
  end

  @impl true
  def leave_raw do
    record(fn state -> %{state | raw?: false, calls: [:leave_raw | state.calls]} end)
    :ok
  end

  @impl true
  def set_isig(flag) do
    record(fn state -> %{state | isig: flag, calls: [{:set_isig, flag} | state.calls]} end)

    # Mirror the real backend, which changes ISIG by opening a short-lived port.
    # Ports are linked to whoever opened them and send an EXIT on close.
    if state().stty_port?, do: run_port()

    :ok
  end

  defp run_port do
    port = Port.open({:spawn, "true"}, [:binary, :exit_status])

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      1_000 -> :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end
end

defmodule Terra.TerminalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Terra.Terminal.{ANSI, CaptureBackend, TTY}

  setup do
    CaptureBackend.start()

    on_exit(fn ->
      Terra.Terminal.exit()
      CaptureBackend.stop()
    end)

    :ok
  end

  defp enter, do: Terra.Terminal.enter(backend: CaptureBackend)

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  describe "enter/1" do
    test "takes the terminal: raw mode, latin1 input, ISIG off, alt screen, hidden cursor" do
      assert {:ok, info} = enter()

      assert info.entered?
      assert info.terminal?
      assert info.raw?
      assert info.size == {100, 40}

      state = CaptureBackend.state()
      assert :enter_raw in state.calls
      assert {:set_isig, :off} in state.calls
      assert state.encoding == :latin1
      assert state.isig == :off

      assert CaptureBackend.output() =~ ANSI.alt_screen(true)
      assert CaptureBackend.output() =~ ANSI.cursor(:hide)
    end

    test "can be called twice without hanging" do
      assert {:ok, _info} = enter()
      assert {:ok, info} = enter()

      assert info.entered?
      assert Enum.count(CaptureBackend.state().calls, &(&1 == :enter_raw)) == 1
    end

    test "reports raw? false and a fallback size without a terminal" do
      Agent.update(CaptureBackend, &%{&1 | terminal?: false, size: {80, 24}})

      assert {:ok, info} = enter()

      assert info.raw? == false
      assert info.entered?
      assert info.size == {80, 24}
      assert CaptureBackend.state().encoding == :unicode
    end
  end

  describe "exit/0 and restore/0" do
    test "writes the restore sequence and puts the tty flags back" do
      assert {:ok, _info} = enter()
      assert :ok = Terra.Terminal.exit()

      output = CaptureBackend.output()
      state = CaptureBackend.state()

      assert output =~ ANSI.reset()
      assert output =~ ANSI.cursor(:show)
      assert output =~ ANSI.alt_screen(false)
      assert state.encoding == :unicode
      assert state.isig == :on
      assert state.raw? == false
      assert :leave_raw in state.calls
    end

    test "can be called twice without hanging" do
      assert {:ok, _info} = enter()
      assert :ok = Terra.Terminal.exit()
      assert :ok = Terra.Terminal.exit()
      assert :ok = Terra.Terminal.restore()

      assert Enum.count(CaptureBackend.state().writes, &(&1 =~ ANSI.alt_screen(false))) == 1
    end

    test "is a no-op when nothing was entered" do
      assert :ok = Terra.Terminal.exit()
      assert CaptureBackend.state().writes == []
    end
  end

  describe "escape helpers" do
    setup do
      {:ok, _pid} = Terra.Terminal.start(backend: CaptureBackend)
      :ok
    end

    test "emit the expected ANSI for clear, home and cursor moves" do
      assert :ok = Terra.Terminal.clear()
      assert :ok = Terra.Terminal.home()
      assert :ok = Terra.Terminal.move(3, 5)
      assert :ok = Terra.Terminal.hide_cursor()
      assert :ok = Terra.Terminal.show_cursor()
      assert :ok = Terra.Terminal.alt_screen(false)
      assert :ok = Terra.Terminal.reset()

      output = CaptureBackend.output()
      assert output =~ "\e[2J"
      assert output =~ "\e[H"
      assert output =~ "\e[3;5H"
      assert output =~ "\e[?25l"
      assert output =~ "\e[?25h"
      assert output =~ "\e[?1049l"
      assert output =~ "\e[0m"
    end

    test "ANSI sequences match the documented escapes" do
      assert ANSI.alt_screen(true) == "\e[?1049h"
      assert ANSI.alt_screen(false) == "\e[?1049l"
      assert ANSI.cursor(:hide) == "\e[?25l"
      assert ANSI.cursor(:show) == "\e[?25h"
      assert ANSI.reset() == "\e[0m"
      assert ANSI.clear() == "\e[2J"
      assert ANSI.home() == "\e[H"
      assert ANSI.move(12, 7) == "\e[12;7H"
    end
  end

  describe "owner lifetime" do
    test "the stty port closing does not stop the owner or restore the terminal" do
      Agent.update(CaptureBackend, &%{&1 | stty_port?: true})

      assert {:ok, info} = enter()
      assert info.entered?

      refute eventually(fn -> Terra.Terminal.entered?() == false end, 20)

      assert Terra.Terminal.entered?()
      assert Terra.Terminal.info() != nil
      assert Terra.Terminal.size() == {100, 40}
      assert CaptureBackend.output() =~ ANSI.alt_screen(true)
      refute CaptureBackend.output() =~ ANSI.alt_screen(false)
    end

    test "info/0 and size/0 return nil when nothing owns the terminal" do
      assert Terra.Terminal.Owner.info() == nil
      assert Terra.Terminal.Owner.size() == nil
      assert is_tuple(Terra.Terminal.size())
    end
  end

  describe "restore paths" do
    test "a run loop that raises restores the terminal" do
      capture_log(fn ->
        test_pid = self()

        loop =
          spawn(fn ->
            {:ok, _info} = enter()
            send(test_pid, :entered)

            receive do
              :go -> raise "boom from view/1"
            end
          end)

        ref = Process.monitor(loop)
        assert_receive :entered
        send(loop, :go)

        assert eventually(fn -> CaptureBackend.output() =~ ANSI.alt_screen(false) end)
        assert eventually(fn -> Terra.Terminal.info() == nil end)

        assert_receive {:DOWN, ^ref, :process, ^loop,
                        {%RuntimeError{message: "boom from view/1"}, _stack}}
      end)
    end

    test "a run loop killed abruptly restores the terminal" do
      test_pid = self()

      loop =
        spawn(fn ->
          {:ok, _info} = enter()
          send(test_pid, :entered)
          Process.sleep(:infinity)
        end)

      assert_receive :entered
      Process.exit(loop, :kill)
      assert eventually(fn -> CaptureBackend.output() =~ ANSI.alt_screen(false) end)
      assert eventually(fn -> Terra.Terminal.info() == nil end)
      assert CaptureBackend.state().isig == :on
    end

    test "the owner terminating restores the terminal" do
      assert {:ok, _info} = enter()
      owner = Process.whereis(Terra.Terminal.Owner)
      assert is_pid(owner)

      :ok = GenServer.stop(owner, :shutdown)

      assert CaptureBackend.output() =~ ANSI.alt_screen(false)
      assert CaptureBackend.state().isig == :on
      assert CaptureBackend.state().raw? == false
      assert Terra.Terminal.info() == nil
    end
  end

  describe "size" do
    test "comes from the backend while the terminal is held" do
      assert {:ok, _info} = enter()
      assert Terra.Terminal.size() == {100, 40}
      assert Terra.Terminal.columns() == 100
      assert Terra.Terminal.rows() == 40
    end

    test "falls back to COLUMNS and LINES when there is no tty" do
      previous_columns = System.get_env("COLUMNS")
      previous_lines = System.get_env("LINES")

      on_exit(fn ->
        restore_env("COLUMNS", previous_columns)
        restore_env("LINES", previous_lines)
      end)

      System.put_env("COLUMNS", "77")
      System.put_env("LINES", "33")

      assert TTY.size_from_env() == {:ok, {77, 33}}
    end

    test "never fails without a tty" do
      assert {:ok, {columns, rows}} = TTY.size()
      assert is_integer(columns) and columns > 0
      assert is_integer(rows) and rows > 0
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

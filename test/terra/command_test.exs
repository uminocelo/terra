defmodule Terra.CommandTest do
  use ExUnit.Case, async: true

  defmodule FileApp do
    @moduledoc false
    use Terra

    def init(opts), do: {%{result: nil}, [{:read_file, Keyword.fetch!(opts, :path), :loaded}]}

    def update({:loaded, result}, state), do: %{state | result: result}
    def update(_event, state), do: state

    def view(state), do: box(text("result: #{inspect(state.result)}"))
  end

  defmodule PortApp do
    @moduledoc false
    use Terra

    def init(_opts), do: %{result: nil}

    def update({:char, "r"}, state), do: {state, [{:port, "echo hello", :ran}]}
    def update({:ran, result}, state), do: %{state | result: result}
    def update(_event, state), do: state

    def view(state), do: box(text("result: #{inspect(state.result)}"))
  end

  describe "read_file command" do
    test "init/1 can schedule a read and the result arrives as {msg, {:ok, data}}" do
      path =
        Path.join(
          System.tmp_dir!(),
          "terra_command_test_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(path, "hello terra")
      on_exit(fn -> File.rm(path) end)

      machine = Terra.Test.start(FileApp, app: [path: path])

      assert eventually(fn -> Terra.Test.state(machine).result != nil end)
      assert Terra.Test.state(machine).result == {:ok, "hello terra"}

      Terra.Test.stop(machine)
    end

    test "a missing file arrives as {msg, {:error, reason}}" do
      path =
        Path.join(
          System.tmp_dir!(),
          "terra_command_test_missing_#{System.unique_integer([:positive])}"
        )

      machine = Terra.Test.start(FileApp, app: [path: path])

      assert eventually(fn -> Terra.Test.state(machine).result != nil end)
      assert {:error, reason} = Terra.Test.state(machine).result
      assert reason in [:enoent, :eacces]

      Terra.Test.stop(machine)
    end
  end

  describe "port command" do
    test "update/2 can schedule a port and the result arrives as {msg, {:ok, {lines, status}}}" do
      machine = Terra.Test.start(PortApp)

      Terra.Test.send_keys(machine, "r")

      assert eventually(fn -> Terra.Test.state(machine).result != nil end)
      assert Terra.Test.state(machine).result == {:ok, {["hello"], 0}}

      Terra.Test.stop(machine)
    end

    test "a non-zero exit status is data, not an error" do
      machine =
        Terra.Test.start(Terra.CommandTest.ExitApp, app: [cmd: "echo out && exit 3"])

      assert eventually(fn -> Terra.Test.state(machine).result != nil end)
      assert Terra.Test.state(machine).result == {:ok, {["out"], 3}}

      Terra.Test.stop(machine)
    end

    test "quitting while a port runs still stops cleanly" do
      machine = Terra.Test.start(Terra.CommandTest.ExitApp, app: [cmd: "sleep 30"])
      ref = Process.monitor(machine)

      Terra.Test.send_keys(machine, [{:char, "q"}])
      assert_receive {:DOWN, ^ref, :process, ^machine, :normal}
    end
  end

  defmodule ExitApp do
    @moduledoc false
    use Terra

    def init(opts), do: {%{result: nil}, [{:port, Keyword.fetch!(opts, :cmd), :ran}]}

    def update({:ran, result}, state), do: %{state | result: result}
    def update({:char, "q"}, state), do: {:quit, state}
    def update(_event, state), do: state

    def view(state), do: box(text("result: #{inspect(state.result)}"))
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
end

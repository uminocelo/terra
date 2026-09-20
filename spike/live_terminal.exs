defmodule Live do
  def line(label, value), do: IO.puts(:stdio, "LIVE #{label} #{inspect(value)}")

  def enter do
    {:ok, info} = Terra.Terminal.enter()
    line("INFO", info)
  end

  def keys do
    enter()
    IO.puts(:stdio, "LIVE READY")

    loop()
  end

  defp loop do
    case IO.binread(:stdio, 1) do
      :eof ->
        line("EOF", :ok)

      <<0x03>> ->
        line("EVENT", :interrupt)
        finish()

      <<0x71>> ->
        line("EVENT", :quit)
        finish()

      byte ->
        line("BYTE", byte)
        loop()
    end
  end

  defp finish do
    :ok = Terra.Terminal.exit()
    line("RESTORED", Terra.Terminal.info())
    Process.sleep(30)
    System.halt(0)
  end

  def crash do
    enter()
    IO.puts(:stdio, "LIVE READY")
    Process.sleep(200)
    :ok = Terra.Terminal.restore()
    raise "boom from view/1"
  end

  def loop_death do
    test = self()

    loop =
      spawn(fn ->
        enter()
        send(test, :entered)
        Process.sleep(:infinity)
      end)

    receive do
      :entered -> :ok
    after
      3000 -> :timeout
    end

    IO.puts(:stdio, "LIVE READY")
    Process.sleep(300)
    Process.exit(loop, :kill)
    Process.sleep(300)
    line("AFTER_KILL", Terra.Terminal.info())
    System.halt(0)
  end
end

[mode | _] = System.argv()

case mode do
  "crash" -> Live.crash()
  "loop_death" -> Live.loop_death()
  _disabled -> Live.keys()
end

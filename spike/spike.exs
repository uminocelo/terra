Code.require_file("spike_lib.exs", __DIR__)

defmodule Spike do
  alias Spike.{Frame, Keys, Term}

  def main(mode) do
    case mode do
      "crash" -> crash()
      "bench" -> bench()
      "sigterm" -> signal_test("sigterm")
      "sigint" -> signal_test("sigint")
      "keys_isig_off" -> keys(isig_off: true)
      _ -> keys([])
    end
  end

  defp keys(opts) do
    {raw, encoding} = Term.enter()
    log("RAW", raw)
    if opts[:isig_off], do: log("ISIG", Term.isig(:off))

    log("SIZE", Term.size())
    log("ENCODING", encoding)
    log("READY", mode_label(opts))

    {_reader, buffer} = Keys.start_notifier()
    loop(buffer, encoding, opts)
  end

  defp mode_label(opts) do
    if opts[:isig_off], do: "isig-off", else: "plain"
  end

  defp loop(buffer, encoding, opts) do
    case Keys.next_event(buffer) do
      {:event, :idle, buffer} ->
        loop(buffer, encoding, opts)

      {:event, event, buffer} ->
        log("EVENT", event)

        case event do
          :quit -> finish(encoding, opts)
          :interrupt -> finish(encoding, opts)
          {:char, "q"} -> finish(encoding, opts)
          _other -> loop(buffer, encoding, opts)
        end

      {:incomplete, buffer} ->
        loop(buffer, encoding, opts)

      {:eof, _buffer} ->
        log("EOF", :ok)
        finish(encoding, opts)
    end
  end

  defp finish(encoding, opts) do
    log("RESTORE", :begin)
    Term.restore(encoding)
    if opts[:isig_off], do: log("ISIG", Term.isig(:on))
    log("DONE", :ok)
    Process.sleep(30)
    System.halt(0)
  end

  defp crash do
    {_raw, encoding} = Term.enter()
    log("READY", "crash")

    try do
      raise "boom from view/1"
    rescue
      error ->
        Term.restore(encoding)
        log("RESTORED_BEFORE_RERAISE", :ok)
        reraise error, __STACKTRACE__
    end
  end

  defp bench do
    {_raw, encoding} = Term.enter()
    {cols, rows} = Term.size()
    log("READY", "bench #{cols}x#{rows}")

    frames = 120
    gen = for _ <- 1..frames, do: elem(:timer.tc(fn -> Frame.render(cols, rows) end), 0)
    paint = for _ <- 1..frames, do: elem(:timer.tc(fn -> Frame.paint(cols, rows) end), 0)

    log("BENCH_GEN_AVG_MS", Float.round(Enum.sum(gen) / length(gen) / 1000, 3))
    log("BENCH_TOTAL_MS", Float.round(Enum.sum(paint) / 1000, 3))
    log("BENCH_AVG_MS", Float.round(Enum.sum(paint) / length(paint) / 1000, 3))
    log("BENCH_P50_MS", Float.round(percentile(paint, 0.5) / 1000, 3))
    log("BENCH_P95_MS", Float.round(percentile(paint, 0.95) / 1000, 3))
    log("BENCH_MAX_MS", Float.round(Enum.max(paint) / 1000, 3))
    log("BENCH_FRAMES", frames)

    finish(encoding, [])
  end

  defp signal_test(signal) do
    case signal do
      "sigterm" -> log("SET_SIGNAL", :os.set_signal(:sigterm, :handle))
      "sigint" -> log("SET_SIGNAL", {:not_supported, :sigint})
    end

    {_raw, encoding} = Term.enter()
    log("SIZE", Term.size())
    log("ENCODING", encoding)
    log("READY", signal)

    Process.sleep(:infinity)
  end

  defp percentile(times, q) do
    sorted = Enum.sort(times)
    index = min(trunc(length(sorted) * q), length(sorted) - 1)
    Enum.at(sorted, index)
  end

  defp log(label, value) do
    Term.out("SPIKE #{label} #{inspect(value)}\n")
  end
end

[mode | _] = System.argv()
Spike.main(mode)
defmodule Terra.Input.QueueBackend do
  @moduledoc false
  @behaviour Terra.Input.Backend

  @name __MODULE__

  def start(chunks) do
    stop()
    Agent.start(fn -> chunks end, name: @name)
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

  @impl true
  def read(_timeout) do
    Agent.get_and_update(@name, fn
      [] -> {:eof, []}
      [chunk | rest] -> {{:ok, chunk}, rest}
    end)
  end
end

defmodule Terra.Input.BlockingBackend do
  @moduledoc false
  @behaviour Terra.Input.Backend

  @impl true
  def read(_timeout), do: Process.sleep(:infinity)
end

defmodule Terra.InputTest do
  use ExUnit.Case, async: true

  alias Terra.Input.Parser

  describe "parse/2 plain keys" do
    test "printable bytes become char events" do
      assert {[{:char, "a"}], ""} = Parser.parse("a")
      assert {[{:char, "a"}, {:char, "b"}], ""} = Parser.parse("ab")
      assert {[{:char, " "}], ""} = Parser.parse(" ")
      assert {[{:char, "~"}], ""} = Parser.parse("~")
    end

    test "enter, tab and backspace" do
      assert {[:enter], ""} = Parser.parse("\r")
      assert {[:enter], ""} = Parser.parse("\n")
      assert {[:tab], ""} = Parser.parse("\t")
      assert {[:backspace], ""} = Parser.parse(<<0x7F>>)
      assert {[:backspace], ""} = Parser.parse(<<0x08>>)
    end

    test "Ctrl+C is :interrupt and other Ctrl keys are {:ctrl, letter}" do
      assert {[:interrupt], ""} = Parser.parse(<<0x03>>)
      assert {[{:ctrl, :a}], ""} = Parser.parse(<<0x01>>)
      assert {[{:ctrl, :z}], ""} = Parser.parse(<<0x1A>>)
      assert {[{:ctrl, :space}], ""} = Parser.parse(<<0x00>>)
    end

    test "unknown low bytes are dropped" do
      assert {[], ""} = Parser.parse(<<0x1B, "j">>)
      assert {[], ""} = Parser.parse(<<0xFF>>)
    end
  end

  describe "parse/2 arrows" do
    test "CSI arrows map to direction events" do
      assert {[:up], ""} = Parser.parse("\e[A")
      assert {[:down], ""} = Parser.parse("\e[B")
      assert {[:right], ""} = Parser.parse("\e[C")
      assert {[:left], ""} = Parser.parse("\e[D")
    end

    test "SS3 arrows map to direction events" do
      assert {[:up], ""} = Parser.parse("\eOA")
      assert {[:left], ""} = Parser.parse("\eOD")
    end

    test "unknown CSI sequences are dropped" do
      assert {[], ""} = Parser.parse("\e[1;5A")
    end

    test "Shift-Tab is reported as {:ctrl, :tab}" do
      assert {[{:ctrl, :tab}], ""} = Parser.parse("\e[Z")
    end

    test "a CSI split across two reads yields exactly one event" do
      assert {[], "\e["} = Parser.parse("\e[")
      {events, rest} = Parser.parse("\e[" <> "A")
      assert {[:up], ""} = {events, rest}
      assert {[], ""} = Parser.parse(rest)
    end
  end

  describe "parse/2 UTF-8 and graphemes" do
    test "a 2-byte character split across two reads becomes one char event" do
      assert {[], <<0xC3>>} = Parser.parse(<<0xC3>>)

      {events, rest} = Parser.parse(<<0xC3, 0xA9>>)
      assert {[{:char, "é"}], ""} = {events, rest}
    end

    test "a 3-byte character is one char event" do
      assert {[{:char, "€"}], ""} = Parser.parse("€")
    end

    test "combining marks join the base grapheme" do
      combined = "e" <> <<0xCC, 0x81>>
      assert {[{:char, grapheme}], ""} = Parser.parse(combined)
      assert grapheme == "e" <> <<0xCC, 0x81>>
      assert String.length(grapheme) == 1
    end

    test "a high byte that cannot start a grapheme is dropped" do
      assert {[], ""} = Parser.parse(<<0x80>>)
      assert {[], <<0xC0>>} = Parser.parse(<<0xC0>>)
      assert {[], ""} = Parser.parse(<<0xC0>>, flush: true)
    end
  end

  describe "parse/2 ambiguous ESC" do
    test "a lone ESC is held, not guessed" do
      assert {[], "\e"} = Parser.parse("\e")
    end

    test "flush turns a held ESC into :esc" do
      assert {[:esc], ""} = Parser.parse("\e", flush: true)
    end

    test "flush drops a truncated CSI instead of emitting a false event" do
      assert {[], ""} = Parser.parse("\e[", flush: true)
      assert {[], ""} = Parser.parse(<<0xC3>>, flush: true)
    end

    test "an ESC followed by a key is not a false :esc" do
      {events, rest} = Parser.parse("\e[A")
      assert events == [:up]
      assert rest == ""
    end
  end

  describe "parse/2 mixed batches" do
    test "drains every complete event and keeps only the tail" do
      assert {[{:char, "a"}, {:char, "b"}, :up], ""} = Parser.parse("ab\e[A")
      assert {[{:char, "x"}, :enter], "\e["} = Parser.parse("x\r\e[")
    end
  end

  describe "input process" do
    setup do
      input = start_supervised!({Terra.Input, [owner: self(), read: false, flush_ms: 200]})
      %{input: input}
    end

    test "feeds complete events to the owner in batches", %{input: input} do
      Terra.Input.feed(input, "a")
      assert_receive {:terra_input, [{:char, "a"}]}

      Terra.Input.feed(input, "\e[A")
      assert_receive {:terra_input, [:up]}
    end

    test "holds a split sequence until the rest arrives", %{input: input} do
      Terra.Input.feed(input, "\e[")
      Terra.Input.feed(input, "B")
      assert_receive {:terra_input, [:down]}
      refute_received {:terra_input, [:esc]}
    end

    test "flushes a lone ESC after the timeout", %{input: input} do
      Terra.Input.feed(input, "\e")
      assert_receive {:terra_input, [:esc]}, 500
    end

    test "Ctrl+C is an interrupt event, not a crash", %{input: input} do
      Terra.Input.feed(input, <<0x03>>)
      assert_receive {:terra_input, [:interrupt]}
      assert Process.alive?(input)
    end

    test "close/1 flushes and reports the stream closed", %{input: input} do
      ref = Process.monitor(input)
      Terra.Input.feed(input, "\e")
      Terra.Input.close(input)
      assert_receive {:terra_input, [:esc]}
      assert_receive {:terra_input, :closed}
      assert_receive {:DOWN, ^ref, :process, ^input, _reason}
    end
  end

  describe "reader loop" do
    test "reads bytes without waiting for Enter" do
      Terra.Input.QueueBackend.start(["a", "\t"])
      on_exit(&Terra.Input.QueueBackend.stop/0)
      input = start_supervised!({Terra.Input, [owner: self(), backend: Terra.Input.QueueBackend]})
      ref = Process.monitor(input)

      assert_receive {:terra_input, [{:char, "a"}]}
      assert_receive {:terra_input, [:tab]}
      assert_receive {:terra_input, :closed}
      assert_receive {:DOWN, ^ref, :process, ^input, _reason}
    end

    test "EOF closes cleanly without raising" do
      Terra.Input.QueueBackend.start([])
      on_exit(&Terra.Input.QueueBackend.stop/0)
      start_supervised!({Terra.Input, [owner: self(), backend: Terra.Input.QueueBackend]})
      assert_receive {:terra_input, :closed}
    end

    test "a blocking read does not stop the process from handling feed/2" do
      input =
        start_supervised!({Terra.Input, [owner: self(), backend: Terra.Input.BlockingBackend]})

      Terra.Input.feed(input, "x")
      assert_receive {:terra_input, [{:char, "x"}]}
      assert Process.alive?(input)
    end
  end

  describe "parser fixtures" do
    # Byte chunks as a real terminal might deliver them, and the events the
    # parser must emit. Unknown sequences are dropped, per the Parser docs.
    @fixtures [
      {"half an arrow is held, never a false :esc", ["\e["], []},
      {"a CSI split across two reads is one arrow", ["\e[", "A"], [:up]},
      {"a UTF-8 grapheme split across two reads is one char", [<<0xC3>>, <<0xA9>>],
       [{:char, "é"}]},
      {"Ctrl+C is an interrupt event", [<<0x03>>], [:interrupt]},
      {"an unknown CSI sequence is dropped", ["\e[1;5A"], []},
      {"an unknown escape sequence is dropped", ["\ej"], []}
    ]

    for {name, chunks, expected} <- @fixtures do
      @tag fixture: name
      test name do
        chunks = unquote(Macro.escape(chunks))
        expected = unquote(Macro.escape(expected))

        input = start_supervised!({Terra.Input, [owner: self(), read: false, flush_ms: 60_000]})

        Enum.each(chunks, &Terra.Input.feed(input, &1))

        assert collect_events(expected) == expected
      end
    end

    defp collect_events(expected, acc \\ []) do
      if expected != [] and length(acc) >= length(expected) do
        acc
      else
        receive do
          {:terra_input, events} when is_list(events) -> collect_events(expected, acc ++ events)
        after
          200 -> acc
        end
      end
    end
  end
end

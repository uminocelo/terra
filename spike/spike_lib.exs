defmodule Spike.Term do
  @alt_enter "\e[?1049h"
  @alt_leave "\e[?1049l"
  @cursor_hide "\e[?25l"
  @cursor_show "\e[?25h"
  @reset "\e[0m"

  def out(data), do: IO.binwrite(:stdio, data)

  def size do
    case {columns(:standard_error), rows(:standard_error)} do
      {{:ok, cols}, {:ok, rows}} -> {cols, rows}
      _other -> env_size()
    end
  end

  defp columns(device), do: :io.columns(device)
  defp rows(device), do: :io.rows(device)

  defp env_size do
    cols = System.get_env("COLUMNS") |> parse_int(80)
    rows = System.get_env("LINES") |> parse_int(24)
    {cols, rows}
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  def enter do
    raw = :shell.start_interactive({:noshell, :raw})
    previous = :io.getopts(:standard_io)[:encoding]
    :io.setopts(:standard_io, encoding: :latin1)
    out(@alt_enter <> @cursor_hide)
    {raw, previous}
  end

  def restore(encoding \\ :unicode) do
    out(@reset <> @cursor_show <> @alt_leave <> "\e[H\e[2J")
    :io.setopts(:standard_io, encoding: encoding)
    :shell.start_interactive({:noshell, :cooked})
  end

  def stty(flags) do
    sh = System.find_executable("sh")
    arg = "stty #{flags} < /dev/tty"
    port = Port.open({:spawn_executable, sh}, [:binary, :exit_status, :stderr_to_stdout, args: ["-c", arg]])

    receive do
      {^port, {:data, data}} -> {:data, String.trim(data)}
      {^port, {:exit_status, status}} -> {:status, status}
    after
      3000 -> :timeout
    end
  end

  # Runs stty on the inherited tty. Requires :nouse_stdio so fd 0 is the tty.
  def tty_stty(flags) do
    sh = System.find_executable("sh")

    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        args: ["-c", "stty #{flags} 2>/dev/null"]
      ])

    receive do
      {^port, {:exit_status, status}} -> {:status, status}
    after
      3000 -> :timeout
    end
  end

  def isig(flag) when flag in [:on, :off] do
    tty_stty(if flag == :off, do: "-isig", else: "isig")
  end

  def home, do: "\e[H"

  def clear, do: "\e[2J"

  def move(row, col), do: "\e[#{row};#{col}H"

  def style(text, codes) do
    "\e[" <> Enum.join(codes, ";") <> "m" <> text <> @reset
  end
end

defmodule Spike.Frame do
  alias Spike.Term

  def paint(cols, rows) do
    Term.out(render(cols, rows))
  end

  def render(cols, rows) do
    [Term.clear(), Term.home(), box(cols, rows)] |> IO.iodata_to_binary()
  end

  defp box(cols, rows) do
    inner = max(cols - 2, 0)
    label = " terra spike 80x24 "
    pad = max(inner - String.length(label), 0)
    head = Term.style("+" <> label <> String.duplicate("-", pad) <> "+", ["1", "38;5;75"])
    foot = Term.style("+" <> String.duplicate("-", inner) <> "+", ["2", "38;5;244"])

    middle =
      for row <- 1..max(rows - 2, 0) do
        text =
          case rem(row, 6) do
            1 -> Term.style("spike frame", ["38;5;215"])
            2 -> Term.style("row #{row}: full redraw", ["2"])
            _ -> ""
          end

        padding = String.duplicate(" ", max(inner - String.length(strip(text)), 0))
        "|" <> text <> padding <> "|"
      end

    [head, middle, foot, "\n"]
  end

  defp strip(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")
end

defmodule Spike.Keys do
  @escape_timeout 50
  @sequence_timeout 250

  def start_notifier do
    parent = self()
    pid = spawn_link(fn -> read_loop(parent) end)
    {pid, <<>>}
  end

  defp read_loop(parent) do
    case IO.binread(:stdio, 1) do
      :eof ->
        send(parent, :eof)

      byte ->
        send(parent, {:byte, byte})
        read_loop(parent)
    end
  end

  def next_event(buffer) do
    receive do
      {:byte, byte} ->
        buffer = buffer <> byte
        parse(buffer)

      :eof ->
        {:eof, <<>>}
    after
      timeout(buffer) ->
        flush(buffer)
    end
  end

  defp timeout(<<0x1B>>), do: @escape_timeout
  defp timeout(<<>>), do: @escape_timeout
  defp timeout(_buffer), do: @sequence_timeout

  defp flush(<<>>), do: {:event, :idle, <<>>}
  defp flush(<<0x1B>>), do: {:event, :escape, <<>>}
  defp flush(buffer), do: {:event, {:unknown, buffer}, <<>>}

  defp parse(<<0x03, rest::binary>>), do: {:event, :interrupt, rest}
  defp parse(<<0x0D, rest::binary>>), do: {:event, :enter, rest}
  defp parse(<<0x0A, rest::binary>>), do: {:event, :enter, rest}
  defp parse(<<0x09, rest::binary>>), do: {:event, :tab, rest}
  defp parse(<<0x7F, rest::binary>>), do: {:event, :backspace, rest}
  defp parse(<<"q", rest::binary>>), do: {:event, :quit, rest}
  defp parse(<<0x1B, "[", 0x41, rest::binary>>), do: {:event, :up, rest}
  defp parse(<<0x1B, "[", 0x42, rest::binary>>), do: {:event, :down, rest}
  defp parse(<<0x1B, "[", 0x43, rest::binary>>), do: {:event, :right, rest}
  defp parse(<<0x1B, "[", 0x44, rest::binary>>), do: {:event, :left, rest}
  defp parse(<<0x1B>>), do: {:incomplete, <<0x1B>>}
  defp parse(<<0x1B, "[">>), do: {:incomplete, <<0x1B, "[" >>}
  defp parse(<<lead, _rest::binary>> = buffer) when lead in 0xC2..0xF4, do: parse_utf8(buffer)
  defp parse(<<byte, rest::binary>>) when byte >= 0x20 and byte < 0x7F, do: {:event, {:char, <<byte>>}, rest}
  defp parse(<<byte, rest::binary>>), do: {:event, {:unknown, <<byte>>}, rest}

  defp parse_utf8(buffer) do
    needed = utf8_size(:binary.first(buffer))

    if byte_size(buffer) < needed do
      {:incomplete, buffer}
    else
      rest = :binary.part(buffer, needed, byte_size(buffer) - needed)
      {:event, {:char, :binary.part(buffer, 0, needed)}, rest}
    end
  end

  defp utf8_size(lead) when lead < 0xE0, do: 2
  defp utf8_size(lead) when lead < 0xF0, do: 3
  defp utf8_size(_lead), do: 4
end
defmodule Terra.Input.Parser do
  @moduledoc """
  Turns raw terminal bytes into the runtime event union.

  Pure and stateless: `parse/2` consumes as much of the buffer as it can and
  returns the leftover bytes so a caller can prepend them to the next read. That
  leftover is the whole point: an arrow sequence or a multi-byte grapheme split
  across two reads must not emit a false event, so a partial trailing sequence is
  kept, not guessed at.

  ## Events

      :up | :down | :left | :right | :enter | :tab | :backspace | :esc | :interrupt
      | {:char, grapheme} | {:ctrl, atom}

  The union has no shift modifier, so Shift-Tab is reported as `{:ctrl, :tab}`.

  Bytes that never form a documented event (an unknown CSI, an Alt-modified key,
  a byte that cannot start a UTF-8 grapheme) are dropped. A lone `ESC` is
  ambiguous: it might be the start of an arrow sequence, so the caller should hold
  it and re-parse with `flush: true` after a short timeout to get `:esc`.
  """

  @esc 0x1B
  @csi_final_min 0x40
  @csi_final_max 0x7E
  @space 0x20
  @delete 0x7F
  @utf8_lead 0x80

  @type event ::
          :up
          | :down
          | :left
          | :right
          | :enter
          | :tab
          | :backspace
          | :esc
          | :interrupt
          | {:char, String.t()}
          | {:ctrl, atom}

  @doc """
  Parses every complete event in `buffer`.

  Returns `{events, rest}` where `rest` is the unparsed tail. With `flush: true`
  an incomplete tail is given up on instead of kept: a lone `ESC` becomes `:esc`
  and a truncated sequence is dropped.
  """
  @spec parse(binary, keyword) :: {[event], binary}
  def parse(buffer, opts \\ []) when is_binary(buffer) do
    do_parse(buffer, [], Keyword.get(opts, :flush, false))
  end

  defp do_parse(<<>>, events, _flush?), do: {Enum.reverse(events), ""}

  defp do_parse(<<@esc, rest::binary>> = buffer, events, flush?) do
    case parse_escape(rest, flush?) do
      {:event, event, tail} -> do_parse(tail, [event | events], flush?)
      {:unknown, tail} -> do_parse(tail, events, flush?)
      :incomplete -> {Enum.reverse(events), buffer}
    end
  end

  defp do_parse(<<0x0D, rest::binary>>, events, flush?),
    do: do_parse(rest, [:enter | events], flush?)

  defp do_parse(<<0x0A, rest::binary>>, events, flush?),
    do: do_parse(rest, [:enter | events], flush?)

  defp do_parse(<<0x09, rest::binary>>, events, flush?),
    do: do_parse(rest, [:tab | events], flush?)

  defp do_parse(<<0x08, rest::binary>>, events, flush?),
    do: do_parse(rest, [:backspace | events], flush?)

  defp do_parse(<<@delete, rest::binary>>, events, flush?),
    do: do_parse(rest, [:backspace | events], flush?)

  defp do_parse(<<0x03, rest::binary>>, events, flush?),
    do: do_parse(rest, [:interrupt | events], flush?)

  defp do_parse(<<byte, rest::binary>>, events, flush?) when byte >= 0x01 and byte <= 0x1A do
    do_parse(rest, [{:ctrl, ctrl_name(byte)} | events], flush?)
  end

  defp do_parse(<<0x00, rest::binary>>, events, flush?),
    do: do_parse(rest, [{:ctrl, :space} | events], flush?)

  defp do_parse(<<0x1C, rest::binary>>, events, flush?),
    do: do_parse(rest, [{:ctrl, :backslash} | events], flush?)

  defp do_parse(<<0x1D, rest::binary>>, events, flush?),
    do: do_parse(rest, [{:ctrl, :bracket_right} | events], flush?)

  defp do_parse(<<0x1E, rest::binary>>, events, flush?),
    do: do_parse(rest, [{:ctrl, :caret} | events], flush?)

  defp do_parse(<<0x1F, rest::binary>>, events, flush?),
    do: do_parse(rest, [{:ctrl, :underscore} | events], flush?)

  defp do_parse(<<byte, rest::binary>>, events, flush?) when byte >= @space and byte <= @delete do
    case extend(<<byte>>, rest, flush?) do
      {:ok, grapheme, tail} -> do_parse(tail, [{:char, grapheme} | events], flush?)
      :incomplete -> {Enum.reverse(events), <<byte>> <> rest}
    end
  end

  defp do_parse(<<byte, _::binary>> = buffer, events, flush?) when byte >= @utf8_lead do
    case decode_grapheme(buffer, flush?) do
      {:ok, grapheme, tail} -> do_parse(tail, [{:char, grapheme} | events], flush?)
      :incomplete -> {Enum.reverse(events), buffer}
      :invalid -> do_parse(binary_part(buffer, 1, byte_size(buffer) - 1), events, flush?)
    end
  end

  defp do_parse(<<_byte, rest::binary>>, events, flush?), do: do_parse(rest, events, flush?)

  defp parse_escape(<<>>, false), do: :incomplete
  defp parse_escape(<<>>, true), do: {:event, :esc, ""}
  defp parse_escape(<<"[", rest::binary>>, flush?), do: parse_csi(rest, flush?)
  defp parse_escape(<<"O", rest::binary>>, flush?), do: parse_ss3(rest, flush?)
  defp parse_escape(<<_other, rest::binary>>, _flush?), do: {:unknown, rest}

  defp parse_csi(rest, flush?), do: scan_csi(rest, <<>>, flush?)

  defp scan_csi(<<byte, tail::binary>>, params, flush?)
       when byte >= 0x20 and byte <= 0x3F do
    scan_csi(tail, <<params::binary, byte>>, flush?)
  end

  defp scan_csi(<<final, tail::binary>>, params, _flush?)
       when final >= @csi_final_min and final <= @csi_final_max do
    case csi_event(params, final) do
      :unknown -> {:unknown, tail}
      event -> {:event, event, tail}
    end
  end

  defp scan_csi(<<_byte, tail::binary>>, _params, _flush?), do: {:unknown, tail}
  defp scan_csi(<<>>, _params, false), do: :incomplete
  defp scan_csi(<<>>, _params, true), do: {:unknown, ""}

  defp csi_event("", ?A), do: :up
  defp csi_event("", ?B), do: :down
  defp csi_event("", ?C), do: :right
  defp csi_event("", ?D), do: :left
  defp csi_event("", ?Z), do: {:ctrl, :tab}
  defp csi_event(_params, _final), do: :unknown

  defp parse_ss3(<<>>, false), do: :incomplete
  defp parse_ss3(<<>>, true), do: {:unknown, ""}

  defp parse_ss3(<<final, tail::binary>>, _flush?) do
    case final do
      ?A -> {:event, :up, tail}
      ?B -> {:event, :down, tail}
      ?C -> {:event, :right, tail}
      ?D -> {:event, :left, tail}
      _other -> {:unknown, tail}
    end
  end

  defp ctrl_name(byte), do: String.to_atom(<<?a + byte - 1>>)

  defp decode_grapheme(buffer, flush?) do
    case :unicode.characters_to_binary(buffer, :utf8, :utf8) do
      valid when is_binary(valid) -> first_grapheme(valid, buffer, flush?)
      {:incomplete, valid, _rest} -> first_grapheme(valid, buffer, flush?)
      {:error, _valid, _rest} -> :invalid
    end
  end

  defp first_grapheme("", _buffer, true), do: :invalid
  defp first_grapheme("", _buffer, false), do: :incomplete

  defp first_grapheme(valid, buffer, flush?) do
    {grapheme, rest_valid} = String.next_grapheme(valid)
    consumed = byte_size(valid) - byte_size(rest_valid)
    rest = binary_part(buffer, consumed, byte_size(buffer) - consumed)
    extend(grapheme, rest, flush?)
  end

  defp extend(grapheme, "", _flush?), do: {:ok, grapheme, ""}

  defp extend(grapheme, <<byte, _::binary>> = rest, flush?) when byte >= @utf8_lead do
    case decode_codepoint(rest) do
      {:ok, codepoint, tail} ->
        if combining?(codepoint) do
          extend(grapheme <> <<codepoint::utf8>>, tail, flush?)
        else
          {:ok, grapheme, rest}
        end

      :incomplete ->
        if flush?, do: {:ok, grapheme, rest}, else: :incomplete

      :invalid ->
        {:ok, grapheme, rest}
    end
  end

  defp extend(grapheme, rest, _flush?), do: {:ok, grapheme, rest}

  defp decode_codepoint(<<byte, _::binary>> = binary) do
    case utf8_length(byte) do
      :invalid ->
        :invalid

      length ->
        if byte_size(binary) < length do
          :incomplete
        else
          candidate = binary_part(binary, 0, length)
          tail = binary_part(binary, length, byte_size(binary) - length)

          case candidate do
            <<codepoint::utf8>> -> {:ok, codepoint, tail}
            _other -> :invalid
          end
        end
    end
  end

  defp utf8_length(byte) when byte in 0xC2..0xDF, do: 2
  defp utf8_length(byte) when byte in 0xE0..0xEF, do: 3
  defp utf8_length(byte) when byte in 0xF0..0xF4, do: 4
  defp utf8_length(_byte), do: :invalid

  defp combining?(codepoint) do
    codepoint in 0x0300..0x036F or
      codepoint in 0x1AB0..0x1AFF or
      codepoint in 0x1DC0..0x1DFF or
      codepoint in 0x20D0..0x20FF or
      codepoint in 0xFE00..0xFE0F or
      codepoint in 0xFE20..0xFE2F or
      codepoint in [0x200C, 0x200D]
  end
end

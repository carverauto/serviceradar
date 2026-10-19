defmodule ServiceRadar.Inventory.AdvisoryFeeds.NvdShardDecoder do
  @moduledoc false

  @key "\"vulnerabilities\""
  @key_size byte_size(@key)

  def init do
    %{
      phase: :seek_key,
      depth: 0,
      top_object: false,
      expect_key: false,
      in_string: false,
      escape: false,
      buffer: <<>>,
      pos: 0,
      start: 0,
      pieces: [],
      cap_depth: 0,
      cap_string: false,
      cap_escape: false,
      patterns: %{
        seek: :binary.compile_pattern([@key, "{", "}", "[", "]", ":", ",", "\""]),
        structure: :binary.compile_pattern(["{", "}", "\""]),
        string: :binary.compile_pattern(["\"", "\\"])
      }
    }
  end

  def pull(%{phase: phase} = state, data) when phase in [:in_array, :capture] do
    resume(state, data)
  end

  def pull(state, data) do
    scan(%{state | buffer: <<>>}, append(state.buffer, data), false)
  end

  def finish(%{phase: phase} = state) when phase in [:in_array, :capture] do
    case resume(state, <<>>) do
      {:need_more, scanned} -> incomplete(scanned)
      other -> other
    end
  end

  def finish(state) do
    case scan(%{state | buffer: <<>>}, state.buffer, true) do
      {:need_more, scanned} -> incomplete(scanned)
      {:event, event, scanned} -> {:event, event, scanned}
      other -> other
    end
  end

  # Continue in the retained chunk, or append new text to its unread tail. An
  # open record keeps its unflushed bytes from `start`.
  defp resume(%{phase: :in_array, buffer: buffer, pos: pos} = state, data) do
    case data do
      <<>> -> in_array(state, buffer, pos)
      data -> in_array(state, append(tail(buffer, pos), data), 0)
    end
  end

  defp resume(%{phase: :capture, buffer: buffer, pos: pos, start: start} = state, data) do
    case data do
      <<>> -> capture(state, buffer, pos)
      data -> capture(%{state | start: 0}, append(tail(buffer, start), data), pos - start)
    end
  end

  defp tail(buffer, from), do: binary_part(buffer, from, byte_size(buffer) - from)

  defp incomplete(%{phase: :done}), do: :done
  defp incomplete(%{phase: :error} = state), do: {:error, :truncated_record, state}
  defp incomplete(%{phase: :capture} = state), do: {:error, :truncated_record, state}
  defp incomplete(%{phase: :in_array} = state), do: {:error, :truncated_vulnerabilities, state}

  defp incomplete(state), do: {:error, {:invalid_records, "vulnerabilities"}, state}

  defp append(<<>>, data), do: data
  defp append(buffer, <<>>), do: buffer
  defp append(buffer, data), do: buffer <> data

  defp scan(state, bin, final?) do
    case state.phase do
      :done ->
        {:done, state}

      :error ->
        {:error, :truncated_record, state}

      :seek_key ->
        seek_key(state, bin, final?)

      :seek_colon ->
        seek_mark(state, bin, ?:, :seek_array, final?)

      :seek_array ->
        seek_mark(state, bin, ?[, :in_array, final?)

      :in_array ->
        enter_array(state, bin, final?)
    end
  end

  defp seek_key(state, bin, final?) do
    if state.in_string do
      seek_string(state, bin, final?)
    else
      scan_seek(state, bin, final?)
    end
  end

  defp scan_seek(state, <<>>, _final?) do
    {:need_more, %{state | buffer: <<>>}}
  end

  defp scan_seek(state, bin, final?) do
    case :binary.match(bin, state.patterns.seek) do
      :nomatch ->
        {:need_more, %{state | buffer: <<>>}}

      {pos, len} ->
        <<_::binary-size(^pos), token::binary-size(^len), rest::binary>> = bin
        from_token = binary_part(bin, pos, byte_size(bin) - pos)
        scan_seek_token(state, token, from_token, rest, final?)
    end
  end

  defp scan_seek_token(
         %{depth: 1, top_object: true, expect_key: true} = state,
         @key,
         _from_token,
         rest,
         final?
       ) do
    scan(%{state | phase: :seek_colon, expect_key: false}, rest, final?)
  end

  defp scan_seek_token(state, @key, _from_token, rest, final?) do
    scan_seek(%{state | expect_key: false}, rest, final?)
  end

  defp scan_seek_token(%{depth: 0} = state, "{", _from_token, rest, final?) do
    scan_seek(%{state | depth: 1, top_object: true, expect_key: true}, rest, final?)
  end

  defp scan_seek_token(state, open, _from_token, rest, final?) when open in ["{", "["] do
    scan_seek(%{state | depth: state.depth + 1, expect_key: false}, rest, final?)
  end

  defp scan_seek_token(state, close, _from_token, rest, final?) when close in ["}", "]"] do
    next_depth = max(state.depth - 1, 0)

    scan_seek(
      %{
        state
        | depth: next_depth,
          top_object: state.top_object and next_depth > 0,
          expect_key: false
      },
      rest,
      final?
    )
  end

  defp scan_seek_token(%{depth: 1, top_object: true} = state, ",", _from_token, rest, final?) do
    scan_seek(%{state | expect_key: true}, rest, final?)
  end

  defp scan_seek_token(state, mark, _from_token, rest, final?) when mark in [",", ":"] do
    scan_seek(%{state | expect_key: false}, rest, final?)
  end

  defp scan_seek_token(state, "\"", from_token, rest, final?) do
    if state.depth == 1 and state.top_object and state.expect_key and not final? and
         byte_size(from_token) < @key_size and key_has_prefix?(from_token) do
      {:need_more, %{state | buffer: copy_bin(from_token)}}
    else
      seek_string(%{state | in_string: true, escape: false, expect_key: false}, rest, final?)
    end
  end

  defp key_has_prefix?(bin), do: binary_part(@key, 0, byte_size(bin)) == bin

  defp seek_string(state, <<>>, _final?) do
    {:need_more, %{state | buffer: <<>>, in_string: true}}
  end

  defp seek_string(%{escape: true} = state, <<_ch, rest::binary>>, final?) do
    seek_string(%{state | escape: false}, rest, final?)
  end

  defp seek_string(state, bin, final?) do
    case :binary.match(bin, ["\\", "\""]) do
      :nomatch ->
        {:need_more, %{state | buffer: <<>>, in_string: true, escape: false}}

      {pos, 1} ->
        <<_::binary-size(^pos), ch, rest::binary>> = bin

        case ch do
          ?\\ -> seek_string(%{state | escape: true}, rest, final?)
          ?" -> seek_key(%{state | in_string: false, escape: false}, rest, final?)
        end
    end
  end

  defp seek_mark(state, <<>>, _mark, _next, _final?) do
    {:need_more, %{state | buffer: <<>>}}
  end

  defp seek_mark(state, <<ws, rest::binary>>, mark, next, final?)
       when ws in [?\s, ?\n, ?\r, ?\t] do
    seek_mark(state, rest, mark, next, final?)
  end

  defp seek_mark(state, <<mark, rest::binary>>, mark, next, final?) do
    scan(%{state | phase: next}, rest, final?)
  end

  defp seek_mark(state, <<_ch, _rest::binary>>, _mark, _next, _final?) do
    {:error, {:invalid_records, "vulnerabilities"}, %{state | phase: :error}}
  end

  # The record body is scanned by offset into the current text chunk. Only the
  # structural bytes are visited: one compiled `:binary.match/3` per string and
  # per brace. Nothing is copied until a record is complete, and then it is
  # copied once. Copying every run of bytes between tokens made this scanner,
  # not Jason, the cost of a nist-nvd2 run: about ten times Jason's own decode
  # time on the same shard.
  defp enter_array(state, bin, _final?) do
    in_array(%{state | buffer: bin, pos: 0, start: 0}, bin, 0)
  end

  defp in_array(state, bin, pos) when pos >= byte_size(bin) do
    {:need_more, %{state | buffer: <<>>, pos: 0, start: 0}}
  end

  defp in_array(state, bin, pos) do
    case :binary.at(bin, pos) do
      ws when ws in [?\s, ?\n, ?\r, ?\t, ?,] ->
        in_array(state, bin, pos + 1)

      ?] ->
        {:done, %{state | phase: :done, buffer: <<>>, pos: 0, pieces: []}}

      ?{ ->
        capture(
          %{
            state
            | phase: :capture,
              cap_depth: 1,
              cap_string: false,
              cap_escape: false,
              pieces: [],
              start: pos
          },
          bin,
          pos + 1
        )

      _other ->
        {:error, :invalid_vulnerability, %{state | phase: :error, buffer: <<>>, pos: 0}}
    end
  end

  defp capture(state, bin, pos) when pos >= byte_size(bin) do
    need_more_capture(state, bin)
  end

  # A backslash was the last byte of the previous chunk: skip the escaped byte.
  defp capture(%{cap_string: true, cap_escape: true} = state, bin, pos) do
    capture(%{state | cap_escape: false}, bin, pos + 1)
  end

  defp capture(%{cap_string: true} = state, bin, pos) do
    case :binary.match(bin, state.patterns.string, scope: {pos, byte_size(bin) - pos}) do
      :nomatch ->
        need_more_capture(state, bin)

      {at, 1} ->
        case :binary.at(bin, at) do
          ?" -> capture(%{state | cap_string: false}, bin, at + 1)
          ?\\ -> capture(%{state | cap_escape: true}, bin, at + 1)
        end
    end
  end

  defp capture(state, bin, pos) do
    case :binary.match(bin, state.patterns.structure, scope: {pos, byte_size(bin) - pos}) do
      :nomatch ->
        need_more_capture(state, bin)

      {at, 1} ->
        case :binary.at(bin, at) do
          ?{ ->
            capture(%{state | cap_depth: state.cap_depth + 1}, bin, at + 1)

          ?" ->
            capture(%{state | cap_string: true, cap_escape: false}, bin, at + 1)

          ?} when state.cap_depth == 1 ->
            emit_object(state, bin, at + 1)

          ?} ->
            capture(%{state | cap_depth: state.cap_depth - 1}, bin, at + 1)
        end
    end
  end

  # The record continues in the next chunk. Keep the unread tail of this chunk
  # as a sub-binary; the chunks are the reader's own copies, so this holds no
  # more than the record being assembled.
  defp need_more_capture(state, bin) do
    pieces = push_piece(state.pieces, bin, state.start, byte_size(bin))
    {:need_more, %{state | pieces: pieces, buffer: <<>>, pos: 0, start: 0}}
  end

  defp emit_object(state, bin, stop) do
    object =
      case push_piece(state.pieces, bin, state.start, stop) do
        [single] -> :binary.copy(single)
        pieces -> pieces |> Enum.reverse() |> IO.iodata_to_binary()
      end

    event =
      case Jason.decode(object) do
        {:ok, record} when is_map(record) -> {:ok, record}
        {:ok, other} -> {:error, {:invalid_record, other}}
        {:error, reason} -> {:error, reason}
      end

    {:event, event,
     %{
       state
       | phase: :in_array,
         pieces: [],
         cap_depth: 0,
         buffer: bin,
         pos: stop,
         start: stop
     }}
  end

  defp push_piece(pieces, _bin, start, stop) when stop <= start, do: pieces
  defp push_piece(pieces, bin, start, stop), do: [binary_part(bin, start, stop - start) | pieces]

  defp copy_bin(<<>>), do: <<>>
  defp copy_bin(bin), do: :binary.copy(bin)
end

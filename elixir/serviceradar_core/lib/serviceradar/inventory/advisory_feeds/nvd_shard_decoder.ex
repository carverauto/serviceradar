defmodule ServiceRadar.Inventory.AdvisoryFeeds.NvdShardDecoder do
  @moduledoc false

  @key "\"vulnerabilities\""
  @key_size byte_size(@key)

  def init do
    %{
      phase: :seek_key,
      depth: 0,
      in_string: false,
      escape: false,
      buffer: <<>>,
      cap_acc: [],
      cap_depth: 0,
      cap_string: false,
      cap_escape: false
    }
  end

  def pull(state, data) do
    scan(%{state | buffer: <<>>}, append(state.buffer, data), false)
  end

  def finish(state) do
    case scan(%{state | buffer: <<>>}, state.buffer, true) do
      {:need_more, scanned} -> incomplete(scanned)
      {:event, event, scanned} -> {:event, event, scanned}
      other -> other
    end
  end

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
        in_array(state, bin, final?)

      :capture ->
        capture(state, bin, final?)
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
    case :binary.match(bin, [@key, "{", "}", "\""]) do
      :nomatch ->
        {:need_more, %{state | buffer: <<>>}}

      {pos, len} ->
        <<_::binary-size(^pos), token::binary-size(^len), rest::binary>> = bin
        from_token = binary_part(bin, pos, byte_size(bin) - pos)

        cond do
          token == @key and state.depth == 1 ->
            scan(%{state | phase: :seek_colon}, rest, final?)

          token == "{" ->
            scan_seek(%{state | depth: state.depth + 1}, rest, final?)

          token == "}" ->
            scan_seek(%{state | depth: max(state.depth - 1, 0)}, rest, final?)

          token == "\"" and not final? and byte_size(from_token) < @key_size and
              key_has_prefix?(from_token) ->
            {:need_more, %{state | buffer: copy_bin(from_token)}}

          token == "\"" ->
            seek_string(%{state | in_string: true, escape: false}, rest, final?)

          true ->
            scan_seek(state, rest, final?)
        end
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

  defp in_array(state, <<>>, _final?) do
    {:need_more, %{state | buffer: <<>>}}
  end

  defp in_array(state, <<ws, rest::binary>>, final?) when ws in [?\s, ?\n, ?\r, ?\t, ?,] do
    in_array(state, rest, final?)
  end

  defp in_array(state, <<?], _rest::binary>>, _final?) do
    {:done, %{state | phase: :done, buffer: <<>>, cap_acc: []}}
  end

  defp in_array(state, <<?{, rest::binary>>, final?) do
    capture(
      %{
        state
        | phase: :capture,
          cap_depth: 1,
          cap_string: false,
          cap_escape: false,
          cap_acc: ["{"]
      },
      rest,
      final?
    )
  end

  defp in_array(state, <<_ch, _rest::binary>>, _final?) do
    {:error, :invalid_vulnerability, %{state | phase: :error, buffer: <<>>}}
  end

  defp capture(state, <<>>, _final?) do
    {:need_more, %{state | buffer: <<>>}}
  end

  defp capture(%{cap_string: true, cap_escape: true} = state, <<ch, rest::binary>>, final?) do
    capture(%{state | cap_escape: false, cap_acc: [<<ch>> | state.cap_acc]}, rest, final?)
  end

  defp capture(%{cap_string: true} = state, bin, final?) do
    case :binary.match(bin, ["\\", "\""]) do
      :nomatch ->
        {:need_more, %{state | cap_acc: [copy_bin(bin) | state.cap_acc], buffer: <<>>}}

      {pos, 1} ->
        <<head::binary-size(^pos), ch, rest::binary>> = bin
        acc = push_copy(state.cap_acc, head)

        case ch do
          ?\\ ->
            capture(%{state | cap_escape: true, cap_acc: ["\\" | acc]}, rest, final?)

          ?" ->
            capture(%{state | cap_string: false, cap_acc: ["\"" | acc]}, rest, final?)
        end
    end
  end

  defp capture(state, bin, final?) do
    case :binary.match(bin, ["{", "}", "\""]) do
      :nomatch ->
        {:need_more, %{state | cap_acc: [copy_bin(bin) | state.cap_acc], buffer: <<>>}}

      {pos, 1} ->
        <<head::binary-size(^pos), ch, rest::binary>> = bin
        acc = push_copy(state.cap_acc, head)

        case ch do
          ?{ ->
            capture(%{state | cap_depth: state.cap_depth + 1, cap_acc: ["{" | acc]}, rest, final?)

          ?" ->
            capture(
              %{state | cap_string: true, cap_escape: false, cap_acc: ["\"" | acc]},
              rest,
              final?
            )

          ?} ->
            depth = state.cap_depth - 1
            acc = ["}" | acc]

            if depth == 0 do
              emit_object(state, acc, rest)
            else
              capture(%{state | cap_depth: depth, cap_acc: acc}, rest, final?)
            end
        end
    end
  end

  defp emit_object(state, acc, rest) do
    object =
      acc
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> :binary.copy()

    event =
      case Jason.decode(object) do
        {:ok, record} when is_map(record) -> {:ok, record}
        {:ok, other} -> {:error, {:invalid_record, other}}
        {:error, reason} -> {:error, reason}
      end

    {:event, event,
     %{state | phase: :in_array, cap_acc: [], cap_depth: 0, buffer: copy_bin(rest)}}
  end

  defp push_copy(acc, <<>>), do: acc
  defp push_copy(acc, bin), do: [copy_bin(bin) | acc]

  defp copy_bin(<<>>), do: <<>>
  defp copy_bin(bin), do: :binary.copy(bin)
end

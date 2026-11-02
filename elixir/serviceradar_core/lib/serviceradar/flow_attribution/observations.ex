defmodule ServiceRadar.FlowAttribution.Observations do
  @moduledoc """
  The JetStream contract for netprobe process attribution observations.

  Core publishes each admitted batch on `flows.attribution.observations`, in the
  dedicated `flows` stream next to `flows.raw.*`, and EventWriter's
  `FlowAttributionObservations` processor loads the rows into the StarRocks
  table `flow_process_attribution_observations`. Core never writes the
  observations to a database itself.

  One message carries at most `@max_rows_per_message` rows and at most
  `@max_message_bytes` bytes when encoded. That budget is the NATS server
  default max payload minus the header margin, so the published frame stays
  within max_payload. Text fields are truncated UTF-8-safely to the warehouse
  column widths, then the row is shortened until its JSON fits in one message.
  A row that still cannot fit fails the batch before any publish. The publish
  waits for the JetStream PubAck: a message the server refused (for example a
  subject the NATS user may not publish) fails the batch instead of vanishing.
  """

  alias ServiceRadar.NATS.JetStreamPublish

  @subject "flows.attribution.observations"
  @max_rows_per_message 500
  @nats_max_payload_bytes 1_048_576
  @payload_margin_bytes 65_536
  @max_message_bytes @nats_max_payload_bytes - @payload_margin_bytes
  @envelope_bytes 11
  @max_row_bytes @max_message_bytes - @envelope_bytes

  # flow_process_attribution_observations column widths (0026).
  @scalar_limits [
    {:partition, 128},
    {:agent_id, 256},
    {:local_ip, 64},
    {:remote_ip, 64},
    {:comm, 256},
    {:cmdline, 65_533},
    {:container_id, 256},
    {:attribution_key, 64}
  ]

  @nested_limits [
    {:workload_identity, 1_048_576},
    {:executable_ownership, 65_533}
  ]

  @spec subject() :: String.t()
  def subject, do: @subject

  @doc """
  Publishes observation rows (as built by `EventRows.from_event/3`).

  `:publish` replaces the JetStream publish. An arity-3 callback is
  `(subject, body, msg_id -> :ok | {:error, term})`; an arity-2 callback is
  `(subject, body -> :ok | {:error, term})`.

  `:event_id` is the EdgeRecordV1 event id. A 16-byte id is written as
  canonical UUID text; any other id that is not a header token is lowercase
  hex. Each split's `Nats-Msg-Id` is that text, a colon, and the split index,
  so a retry stores each split once and a later split is not dropped.
  """
  @spec publish([map()], keyword()) :: :ok | {:error, term()}
  def publish(rows, opts \\ []) when is_list(rows) do
    publish = Keyword.get(opts, :publish, &default_publish/3)
    event_id = Keyword.get(opts, :event_id)

    with {:ok, encoded} <- encode_rows(rows),
         {:ok, bodies} <- split_messages(encoded) do
      bodies
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {body, index}, :ok ->
        case deliver(publish, body, message_id(event_id, index)) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
          other -> {:halt, {:error, {:unexpected_publish_result, other}}}
        end
      end)
    end
  end

  defp default_publish(subject, body, msg_id) do
    JetStreamPublish.publish(subject, body, msg_opts(msg_id))
  end

  defp msg_opts(id) when is_binary(id) and id != "", do: [msg_id: id]
  defp msg_opts(_id), do: []

  defp deliver(publish, body, msg_id) do
    cond do
      is_function(publish, 3) -> publish.(@subject, body, msg_id)
      is_function(publish, 2) -> publish.(@subject, body)
      true -> {:error, :invalid_publish}
    end
  end

  defp message_id(event_id, index) when is_binary(event_id) and event_id != "" do
    message_id_prefix(event_id) <> ":" <> Integer.to_string(index)
  end

  defp message_id(_event_id, _index), do: nil

  defp message_id_prefix(<<_::128>> = event_id), do: canonical_uuid(event_id)

  defp message_id_prefix(event_id) do
    if header_token?(event_id), do: event_id, else: Base.encode16(event_id, case: :lower)
  end

  defp canonical_uuid(<<_::128>> = event_id) do
    <<p1::binary-size(8), p2::binary-size(4), p3::binary-size(4), p4::binary-size(4),
      p5::binary-size(12)>> =
      Base.encode16(event_id, case: :lower)

    p1 <> "-" <> p2 <> "-" <> p3 <> "-" <> p4 <> "-" <> p5
  end

  defp header_token?(value) do
    String.valid?(value) and Enum.all?(:binary.bin_to_list(value), &(&1 in 0x21..0x7E))
  end

  defp encode_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case encode_one(row) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        :error -> {:halt, {:error, :observation_exceeds_max_payload}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end

  defp encode_one(row) when is_map(row) do
    with {:ok, row} <- row |> scrub_binaries() |> cap_scalars() |> cap_nested(),
         {:ok, clamped} <- clamp_value(row, @max_row_bytes) do
      encoded = Jason.encode!(clamped)

      if byte_size(encoded) + @envelope_bytes <= @max_message_bytes do
        {:ok, encoded}
      else
        :error
      end
    end
  end

  defp encode_one(_row), do: :error

  defp split_messages([]), do: {:ok, []}

  defp split_messages(encoded_rows) do
    encoded_rows
    |> Enum.reduce_while({:ok, [], [], 0, @envelope_bytes}, fn row,
                                                               {:ok, done, current, count, size} ->
      size_with_row = size + byte_size(row) + if(count == 0, do: 0, else: 1)

      cond do
        size_with_row > @max_message_bytes and count == 0 ->
          {:halt, {:error, :observation_exceeds_max_payload}}

        count > 0 and
            (count + 1 > @max_rows_per_message or size_with_row > @max_message_bytes) ->
          if @envelope_bytes + byte_size(row) > @max_message_bytes do
            {:halt, {:error, :observation_exceeds_max_payload}}
          else
            {:cont,
             {:ok, [encode_body(current) | done], [row], 1, @envelope_bytes + byte_size(row)}}
          end

        true ->
          {:cont, {:ok, done, [row | current], count + 1, size_with_row}}
      end
    end)
    |> finish_split()
  end

  defp finish_split({:error, _} = error), do: error
  defp finish_split({:ok, done, [], _count, _size}), do: {:ok, Enum.reverse(done)}

  defp finish_split({:ok, done, current, _count, _size}) do
    {:ok, Enum.reverse([encode_body(current) | done])}
  end

  defp encode_body(reversed_rows) do
    IO.iodata_to_binary([
      "{\"rows\":[",
      reversed_rows |> Enum.reverse() |> Enum.intersperse(","),
      "]}"
    ])
  end

  defp cap_scalars(row) do
    Enum.reduce(@scalar_limits, row, fn {key, max}, acc ->
      case fetch_field(acc, key) do
        {:ok, value} when is_binary(value) -> put_field(acc, key, truncate_binary(value, max))
        _ -> acc
      end
    end)
  end

  defp cap_nested(row) do
    Enum.reduce_while(@nested_limits, {:ok, row}, fn {key, max}, {:ok, acc} ->
      case fetch_field(acc, key) do
        {:ok, value} when is_map(value) and not is_struct(value) ->
          case clamp_value(value, max) do
            {:ok, clamped} -> {:cont, {:ok, put_field(acc, key, clamped)}}
            :error -> {:halt, :error}
          end

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp fetch_field(row, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(row, key) -> {:ok, Map.get(row, key)}
      Map.has_key?(row, string_key) -> {:ok, Map.get(row, string_key)}
      true -> :error
    end
  end

  defp put_field(row, key, value) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(row, key) -> Map.put(row, key, value)
      Map.has_key?(row, string_key) -> Map.put(row, string_key, value)
      true -> Map.put(row, key, value)
    end
  end

  defp clamp_value(value, max_bytes, previous_size \\ nil) do
    encoded = Jason.encode!(value)
    size = byte_size(encoded)

    cond do
      size <= max_bytes ->
        {:ok, value}

      is_integer(previous_size) and size >= previous_size ->
        :error

      true ->
        case longest_binary(value) do
          nil ->
            :error

          {path, binary} ->
            excess = size - max_bytes
            keep = max(byte_size(binary) - excess, 0)
            shortened = truncate_binary(binary, keep)

            shortened =
              if byte_size(shortened) >= byte_size(binary), do: "", else: shortened

            clamp_value(put_path(value, path, shortened), max_bytes, size)
        end
    end
  end

  defp longest_binary(value) do
    case walk_binaries(value, [], nil) do
      nil -> nil
      {_size, path, binary} -> {path, binary}
    end
  end

  defp walk_binaries(value, path, best) when is_binary(value) do
    if byte_size(value) > 0 and (best == nil or byte_size(value) > elem(best, 0)) do
      {byte_size(value), Enum.reverse(path), value}
    else
      best
    end
  end

  defp walk_binaries(value, path, best) when is_map(value) do
    if is_struct(value) do
      best
    else
      Enum.reduce(value, best, fn {key, inner}, acc ->
        walk_binaries(inner, [key | path], acc)
      end)
    end
  end

  defp walk_binaries(value, path, best) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(best, fn {inner, index}, acc ->
      walk_binaries(inner, [index | path], acc)
    end)
  end

  defp walk_binaries(_value, _path, best), do: best

  defp put_path(value, [key], replacement) when is_map(value),
    do: Map.put(value, key, replacement)

  defp put_path(value, [index], replacement) when is_list(value) do
    List.replace_at(value, index, replacement)
  end

  defp put_path(value, [key | rest], replacement) when is_map(value) do
    Map.put(value, key, put_path(Map.fetch!(value, key), rest, replacement))
  end

  defp put_path(value, [index | rest], replacement) when is_list(value) do
    List.replace_at(value, index, put_path(Enum.at(value, index), rest, replacement))
  end

  defp scrub_binaries(row) do
    Map.new(row, fn {key, value} -> {key, scrub_value(value)} end)
  end

  defp scrub_value(value) when is_binary(value), do: String.replace_invalid(value)

  defp scrub_value(value) when is_map(value) do
    if is_struct(value) do
      value
    else
      Map.new(value, fn {key, inner} -> {scrub_key(key), scrub_value(inner)} end)
    end
  end

  defp scrub_value(value) when is_list(value), do: Enum.map(value, &scrub_value/1)
  defp scrub_value(value), do: value

  defp scrub_key(key) when is_binary(key), do: String.replace_invalid(key)
  defp scrub_key(key), do: key

  defp truncate_binary(value, max_bytes) do
    value |> binary_part(0, min(max_bytes, byte_size(value))) |> trim_incomplete_utf8()
  end

  defp trim_incomplete_utf8(value) do
    if String.valid?(value) do
      value
    else
      trim_incomplete_utf8(binary_part(value, 0, byte_size(value) - 1))
    end
  end

  @doc "Decodes one observation message into its rows, or `:error`."
  @spec decode(binary()) :: {:ok, [map()]} | :error
  def decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"rows" => rows}} when is_list(rows) -> {:ok, Enum.filter(rows, &valid_row?/1)}
      _ -> :error
    end
  end

  def decode(_body), do: :error

  # The table's key and NOT NULL columns; a row without them would be filtered
  # out of the Stream Load, failing the whole batch's row count.
  defp valid_row?(%{
         "observed_at" => observed_at,
         "partition" => partition,
         "proto" => proto,
         "local_ip" => local_ip,
         "local_port" => local_port,
         "remote_ip" => remote_ip,
         "remote_port" => remote_port,
         "attribution_key" => key
       }) do
    is_binary(observed_at) and is_binary(partition) and is_integer(proto) and
      is_binary(local_ip) and is_integer(local_port) and is_binary(remote_ip) and
      is_integer(remote_port) and is_binary(key)
  end

  defp valid_row?(_row), do: false
end

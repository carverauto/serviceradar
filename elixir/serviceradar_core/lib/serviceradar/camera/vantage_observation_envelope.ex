defmodule ServiceRadar.Camera.VantageObservationEnvelope do
  @moduledoc """
  Validates `media.results.vantage.v1` envelopes (`vantage.result.v1`) while
  retaining admitted-job identity when the body fails validation so active
  recorded-block `VantageJob` rows can transition cleanly to `:failed_terminal`.
  """

  alias ServiceRadar.Camera.Validations.VantageCropJpeg

  @max_envelope_bytes 983_040
  @max_bigint 9_223_372_036_854_775_807
  @max_u32 4_294_967_295
  @max_observations 256
  @worker_kinds ["camera_vlm", "external_rust", "external_python"]

  @invalid {:error, :invalid_result_envelope}
  @invalid_bbox {:error, :invalid_bbox}

  @doc "JetStream subject for Vantage observation results."
  @spec result_subject() :: String.t()
  def result_subject, do: "media.results.vantage.v1"

  @doc "Maximum JSON envelope size in bytes (960 KiB)."
  @spec max_envelope_bytes() :: pos_integer()
  def max_envelope_bytes, do: @max_envelope_bytes

  @doc "Maximum crop JPEG size in bytes (32 KiB)."
  @spec max_crop_bytes() :: pos_integer()
  def max_crop_bytes, do: VantageCropJpeg.max_bytes()

  @doc """
  Validates a decoded `vantage.result.v1` envelope map.

  Returns `{:ok, identity, {:ok, body} | {:error, reason}}` when identity fields
  are valid, or `{:error, :invalid_result_envelope}` when identity itself is invalid.
  """
  @spec validate(term()) ::
          {:ok, map(), {:ok, map()} | {:error, term()}} | {:error, :invalid_result_envelope}
  def validate(envelope) when is_map(envelope) and not is_struct(envelope) do
    with {:ok, identity} <- parse_identity(envelope),
         :ok <- validate_mode_identity(identity) do
      body =
        object(envelope, [
          {:schema_version, &literal(&1, "vantage.result.v1")},
          {:schema, &nullable(&1, fn v -> literal(v, result_subject()) end), nil},
          {:observations,
           &array(&1, @max_observations, fn item ->
             parse_observation(item, identity.source_mode)
           end)}
        ])

      {:ok, identity, body}
    else
      {:error, _} -> @invalid
    end
  end

  def validate(_), do: @invalid

  defp parse_identity(envelope) do
    object(envelope, [
      {:source_mode, &source_mode/1},
      {:job_id, fn v -> nullable(v, &uuid/1) end, nil},
      {:catalog_entry_id, fn v -> nullable(v, &uuid/1) end, nil},
      {:descriptor_sha256, fn v -> nullable(v, &digest/1) end, nil},
      {:camera_source_id, &uuid/1},
      {:stream_profile_id, &uuid/1},
      {:pack_id, &nullable(&1, fn v -> string(v, 255) end), nil},
      {:pipeline_id, &string(&1, 255)},
      {:pipeline_version, &string(&1, 64)},
      {:worker_kind, &worker_kind/1},
      {:worker_id, &string(&1, 128)},
      {:model_id, &string(&1, 128)},
      {:model_version, &string(&1, 64)},
      {:capability, &nullable(&1, fn v -> string(v, 128) end), nil}
    ])
  end

  defp validate_mode_identity(%{source_mode: :recorded_block} = id) do
    if is_binary(id.job_id) and is_binary(id.catalog_entry_id) and
         is_binary(id.descriptor_sha256) do
      :ok
    else
      @invalid
    end
  end

  defp validate_mode_identity(%{source_mode: :live_keyframe_tap}), do: :ok

  defp parse_observation(value, source_mode) do
    with {:ok, parsed} <-
           object(value, [
             {:observation_key, &string(&1, 512)},
             {:fragment_sequence, &nullable(&1, fn v -> uint(v, @max_u32) end), nil},
             {:frame_sequence, &nullable(&1, fn v -> uint(v, @max_bigint) end), nil},
             {:media_pts_ns, &nullable(&1, fn v -> uint(v, @max_bigint) end), nil},
             {:timeline_ts_us, &uint(&1, @max_bigint)},
             {:time_basis, &time_basis/1},
             {:track_id, fn v -> nullable(v, &track_id/1) end, nil},
             {:category, &string(&1, 128)},
             {:label, &string(&1, 512)},
             {:confidence, &confidence/1},
             {:bbox, fn v -> nullable(v, &bbox/1) end, nil},
             {:crop_jpeg_b64, fn v -> nullable(v, &decode_crop_jpeg_b64/1) end, nil},
             {:attributes, &plain_map/1},
             {:signal_schema_id, &string(&1, 128)},
             {:signal_schema_version, &string(&1, 64)},
             {:display_contract_id, &nullable(&1, fn v -> string(v, 128) end), nil},
             {:search_text, &nullable(&1, fn v -> string(v, 4096) end), nil}
           ]),
         :ok <- validate_mode_observation(source_mode, parsed) do
      {crop_jpeg, rest} = Map.pop(parsed, :crop_jpeg_b64)
      display_contract_id = rest.display_contract_id || rest.signal_schema_id

      search_text =
        rest.search_text || build_search_text(rest.label, rest.category, rest.attributes)

      {:ok,
       rest
       |> Map.put(:crop_jpeg, crop_jpeg)
       |> Map.put(:display_contract_id, display_contract_id)
       |> Map.put(:search_text, search_text)}
    end
  end

  defp validate_mode_observation(:recorded_block, obs) do
    if is_integer(obs.fragment_sequence) and is_integer(obs.media_pts_ns),
      do: :ok,
      else: @invalid
  end

  defp validate_mode_observation(:live_keyframe_tap, _obs), do: :ok

  defp build_search_text(label, category, attributes) do
    attr_tokens =
      attributes
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.flat_map(fn
        {_k, v} when is_binary(v) and v != "" -> [v]
        {_k, v} when is_number(v) or is_boolean(v) -> [to_string(v)]
        _ -> []
      end)

    ([label, category] ++ attr_tokens)
    |> Enum.uniq()
    |> Enum.join(" ")
    |> String.slice(0, 4096)
  end

  defp decode_crop_jpeg_b64(encoded) do
    VantageCropJpeg.decode_base64_jpeg(encoded)
  end

  defp object(value, fields) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, parsed} ->
      keys = List.wrap(elem(field, 0))
      key = hd(keys)

      case read_field(value, keys, field) do
        {:ok, v} -> {:cont, {:ok, Map.put(parsed, key, v)}}
        error -> {:halt, error}
      end
    end)
  end

  defp object(_, _), do: @invalid

  defp read_field(map, keys, field) do
    names = Enum.flat_map(keys, fn key -> [key, Atom.to_string(key)] end)
    values = map |> Map.take(names) |> Map.values() |> Enum.uniq()

    case values do
      [] when tuple_size(field) == 3 -> {:ok, elem(field, 2)}
      [] -> @invalid
      [value] -> elem(field, 1).(value)
      _ -> @invalid
    end
  end

  defp array(list, limit, parse) when is_list(list) and length(list) <= limit do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse.(item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp array(_, _, _), do: @invalid

  defp nullable(nil, _), do: {:ok, nil}
  defp nullable(value, parse), do: parse.(value)

  defp literal(value, value), do: {:ok, value}
  defp literal(_, _), do: @invalid

  defp source_mode("recorded_block"), do: {:ok, :recorded_block}
  defp source_mode(:recorded_block), do: {:ok, :recorded_block}
  defp source_mode("live_keyframe_tap"), do: {:ok, :live_keyframe_tap}
  defp source_mode(:live_keyframe_tap), do: {:ok, :live_keyframe_tap}
  defp source_mode(_), do: @invalid

  defp time_basis("received"), do: {:ok, :received}
  defp time_basis(:received), do: {:ok, :received}
  defp time_basis("camera_reported"), do: {:ok, :camera_reported}
  defp time_basis(:camera_reported), do: {:ok, :camera_reported}
  defp time_basis(_), do: @invalid

  defp worker_kind(v) when is_atom(v), do: worker_kind(Atom.to_string(v))
  defp worker_kind(v) when v in @worker_kinds, do: {:ok, v}
  defp worker_kind(_), do: @invalid

  defp track_id(v) when is_integer(v) and v >= 0 and v <= @max_bigint,
    do: {:ok, Integer.to_string(v)}

  defp track_id(v) when is_binary(v), do: string(v, 128)
  defp track_id(_), do: @invalid

  defp plain_map(v) when is_map(v) and not is_struct(v) do
    case sanitize_plain_map(v) do
      {:ok, sanitized} -> {:ok, sanitized}
      :error -> @invalid
    end
  end

  defp plain_map(_), do: @invalid

  defp sanitize_plain_map(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      with {:ok, key} <- stringify_key(k),
           {:ok, val} <- sanitize_plain_value(v) do
        {:cont, {:ok, Map.put(acc, key, val)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp sanitize_plain_value(:out_of_range), do: :error
  defp sanitize_plain_value(v) when is_map(v) and not is_struct(v), do: sanitize_plain_map(v)
  defp sanitize_plain_value(v) when is_struct(v), do: :error

  defp sanitize_plain_value(v) when is_list(v) do
    v
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case sanitize_plain_value(item) do
        {:ok, val} -> {:cont, {:ok, [val | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp sanitize_plain_value(v), do: {:ok, v}

  defp stringify_key(k) when is_atom(k), do: {:ok, Atom.to_string(k)}
  defp stringify_key(k) when is_binary(k), do: {:ok, k}
  defp stringify_key(k) when is_integer(k), do: {:ok, Integer.to_string(k)}
  defp stringify_key(_), do: :error

  defp uuid(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> @invalid
    end
  end

  defp uuid(_), do: @invalid

  defp digest(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: {:ok, value}, else: @invalid
  end

  defp digest(_), do: @invalid

  defp string(value, limit)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= limit do
    if String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: @invalid
  end

  defp string(_, _), do: @invalid

  defp uint(value, max) when is_integer(value) and value >= 0 and value <= max, do: {:ok, value}
  defp uint(_, _), do: @invalid

  defguardp unit_number(v) when (is_float(v) or is_integer(v)) and v >= 0.0 and v <= 1.0

  defp confidence(value) when unit_number(value), do: {:ok, value * 1.0}
  defp confidence(_), do: @invalid

  defp bbox([x1, y1, x2, y2])
       when unit_number(x1) and unit_number(y1) and unit_number(x2) and unit_number(y2) and
              x1 < x2 and y1 < y2 do
    {:ok, %{"x1" => x1 * 1.0, "y1" => y1 * 1.0, "x2" => x2 * 1.0, "y2" => y2 * 1.0}}
  end

  defp bbox(_), do: @invalid_bbox
end

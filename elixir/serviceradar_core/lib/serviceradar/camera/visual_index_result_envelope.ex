defmodule ServiceRadar.Camera.VisualIndexResultEnvelope do
  @moduledoc """
  Validates the media worker result and retains the admitted-job identity when the body is invalid.
  All fields below are required except the listed omissions and nullable worker fields.

  | Object | Required fields | Optional fields |
  | --- | --- | --- |
  | Result | Schema, schema version (v1), catalog UUID, descriptor SHA-256, detector and embedder ID/version, dimension, frames | Job UUID, tracks (empty), nullable `block_thumbnail_jpeg_b64` (`<= 64 KiB` base64 JPEG) |
  | Frame | Fragment sequence, media PTS, scene suppression, detections, embeddings | Nullable `thumbnail_jpeg_b64` (`<= 64 KiB` base64 JPEG) |
  | Detection | Object class, confidence, box, dominant colors | Nullable track ID (validated, not persisted) |
  | Embedding | Region kind, region index, dominant colors, vector | Nullable class, confidence, box and track ID |
  | Track | Track ID, object class, first and last offsets, dwell, frame count and peak confidence | None |

  Scene embeddings use index zero and carry no class, confidence or box. Embedder model ID/version
  and `model_id`/`model_version` must agree when supplied together. Unknown fields are ignored.
  """

  alias ServiceRadar.Camera.Thumbnail

  @max_bigint 9_223_372_036_854_775_807
  @max_u32 4_294_967_295
  @invalid {:error, :invalid_result_envelope}
  @invalid_vector {:error, :invalid_embedding_vector}
  @invalid_bbox {:error, :invalid_bbox}
  @norm_tolerance 0.05

  def result_subject, do: "media.results.visual_index.v1"

  def validate(envelope) do
    with {:ok, identity} <-
           object(envelope, [
             {:catalog_entry_id, &uuid/1},
             {:job_id, &uuid/1, nil},
             {:descriptor_sha256, &digest/1},
             {:detector_model_id, &string(&1, 128)},
             {:detector_model_version, &string(&1, 64)},
             {[:embedder_model_id, :model_id], &string(&1, 128)},
             {[:embedder_model_version, :model_version], &string(&1, 64)},
             {:embedding_dim, &dimension/1}
           ]) do
      body =
        with {:ok, parsed} <-
               object(envelope, [
                 {:schema, &literal(&1, result_subject())},
                 {:schema_version, &literal(&1, 1)},
                 {:tracks, fn items -> array(items, :infinity, &track/1) end, []},
                 {:block_thumbnail_jpeg_b64, fn v -> nullable(v, &thumbnail_jpeg_b64/1) end, nil},
                 {:frames, &array(&1, 512, fn item -> frame(item, identity.embedding_dim) end)}
               ]) do
          {block_thumbnail_jpeg, rest} = Map.pop(parsed, :block_thumbnail_jpeg_b64)
          {:ok, Map.put(rest, :block_thumbnail_jpeg, block_thumbnail_jpeg)}
        end

      {:ok, identity, body}
    end
  end

  defp track(value) do
    object(value, [
      {:track_id, &uint(&1, @max_bigint)},
      {:object_class, &string(&1, 64)},
      {:first_seen_offset_ms, &uint(&1, @max_bigint)},
      {:last_seen_offset_ms, &uint(&1, @max_bigint)},
      {:dwell_ms, &uint(&1, @max_bigint)},
      {:frame_count, &uint(&1, @max_u32)},
      {:peak_confidence, &confidence/1}
    ])
  end

  defp frame(value, dim) do
    with {:ok, parsed} <-
           object(value, [
             {:fragment_sequence, &uint(&1, @max_u32)},
             {:media_pts_ns, &uint(&1, @max_bigint)},
             {:scene_suppressed, &boolean/1},
             {:detections, fn items -> array(items, 64, &detection_with_track/1) end},
             {:embeddings, &array(&1, 16, fn item -> embedding(item, dim) end)},
             {:thumbnail_jpeg_b64, fn v -> nullable(v, &thumbnail_jpeg_b64/1) end, nil}
           ]) do
      {thumbnail_jpeg, rest} = Map.pop(parsed, :thumbnail_jpeg_b64)

      vantage_detections = rest.detections
      persisted_detections = Enum.map(vantage_detections, &Map.delete(&1, "track_id"))

      {:ok,
       rest
       |> Map.put(:detections, persisted_detections)
       |> Map.put(:vantage_detections, vantage_detections)
       |> Map.put(:thumbnail_jpeg, thumbnail_jpeg)}
    end
  end

  defp thumbnail_jpeg_b64(value) do
    case Thumbnail.decode_base64_jpeg(value) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> @invalid
    end
  end

  defp detection_with_track(value) do
    with {:ok, parsed} <-
           object(value, [
             {:object_class, &string(&1, 64)},
             {:confidence, &confidence/1},
             {:bbox, &bbox/1},
             {:dominant_colors, &colors/1},
             {:track_id, &nullable(&1, fn id -> uint(id, @max_bigint) end), nil}
           ]) do
      {:ok, Map.new(parsed, fn {key, v} -> {Atom.to_string(key), v} end)}
    end
  end

  defp embedding(value, dim) do
    with {:ok, parsed} <-
           object(value, [
             {:region_kind, &region_kind/1},
             {:region_index, &uint(&1, @max_u32)},
             {:object_class, &nullable(&1, fn s -> string(s, 64) end), nil},
             {:confidence, fn value -> nullable(value, &confidence/1) end, nil},
             {:bbox, fn value -> nullable(value, &bbox/1) end, nil},
             {:track_id, &nullable(&1, fn id -> uint(id, @max_bigint) end), nil},
             {:dominant_colors, &colors/1},
             {:embedding, &vector(&1, dim)}
           ]),
         :ok <- check_region(parsed) do
      {:ok, parsed}
    end
  end

  defp check_region(%{region_kind: :crop}), do: :ok
  defp check_region(%{region_index: 0, object_class: nil, confidence: nil, bbox: nil}), do: :ok
  defp check_region(%{bbox: box}) when not is_nil(box), do: @invalid_bbox
  defp check_region(_), do: @invalid

  defp region_kind("scene"), do: {:ok, :scene}
  defp region_kind("crop"), do: {:ok, :crop}
  defp region_kind(_), do: @invalid

  defp colors(value), do: array(value, 16, &string(&1, 32))

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
      [] when tuple_size(field) == 3 ->
        {:ok, elem(field, 2)}

      [] ->
        @invalid

      [value] ->
        elem(field, 1).(value)

      _ when hd(keys) in [:embedder_model_id, :embedder_model_version] ->
        {:error, :unmatched_result_job}

      _ ->
        @invalid
    end
  end

  defp array(list, limit, parse)
       when is_list(list) and (limit == :infinity or length(list) <= limit) do
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
  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_), do: @invalid
  defp uint(value, max) when is_integer(value) and value >= 0 and value <= max, do: {:ok, value}
  defp uint(_, _), do: @invalid
  defp dimension(value) when value in [512, 768], do: {:ok, value}
  defp dimension(_), do: @invalid_vector

  defguardp unit_float(v) when is_float(v) and v >= 0.0 and v <= 1.0
  defp confidence(value) when unit_float(value), do: {:ok, value}
  defp confidence(_), do: @invalid

  defp bbox([x1, y1, x2, y2])
       when unit_float(x1) and unit_float(y1) and unit_float(x2) and unit_float(y2) and x1 < x2 and
              y1 < y2,
       do: {:ok, %{"x1" => x1, "y1" => y1, "x2" => x2, "y2" => y2}}

  defp bbox(_), do: @invalid_bbox

  defp vector(values, dim) when is_list(values) and length(values) == dim do
    cond do
      :out_of_range in values ->
        @invalid

      Enum.all?(values, &(is_float(&1) and abs(&1) <= 1.0 + @norm_tolerance)) ->
        normalize_vector(values)

      true ->
        @invalid_vector
    end
  end

  defp vector(_, _), do: @invalid_vector

  defp normalize_vector(values) do
    norm = :math.sqrt(Enum.sum_by(values, &(&1 * &1)))

    if abs(norm - 1.0) <= @norm_tolerance,
      do: Ash.Vector.new(Enum.map(values, &(&1 / norm))),
      else: @invalid_vector
  end
end

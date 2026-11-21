defmodule ServiceRadar.Camera.VisualIndexResultProjector do
  @moduledoc """
  Idempotent JetStream result projector (`media.results.visual_index.v1`) for
  `VisualFrame`, `VisualEmbedding`, and `VisualIndexJob` (`3.1`, `design.md` `4.2`).

  - Validates the `media.results.visual_index.v1` schema, model metadata,
    bounding-box normalization, and L2-normalized vector dimensions (`512 | 768`).
  - Locks/verifies the `RecordingCatalogEntry` inside a CNPG transaction:
    refuses/drops late results if `descriptor_sha256` mismatches or if the block
    is quarantined, absent, or terminally deleted (`{:error, :recording_gone}`).
  - Derives authoritative `timeline_ts_us` and `time_basis` from the catalog
    entry (`timeline_start_us`, `media_start_ns`, `time_basis`) rather than
    worker wall clocks.
  - Upserts `VisualFrame` and `VisualEmbedding` idempotently and marks the
    matching `VisualIndexJob` `:completed`.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.VisualEmbedding
  alias ServiceRadar.Camera.VisualFrame
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.JSONDocument

  require Ash.Query

  @result_subject "media.results.visual_index.v1"
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @max_envelope_bytes 4_194_304
  @max_frames_per_result 512
  @max_embeddings_per_frame 16
  @max_colors_per_embedding 16
  @max_bigint 9_223_372_036_854_775_807
  @norm_tolerance 0.05
  @allowed_dims [512, 768]

  @system_actor SystemActor.system(:camera_visual_index_result_projector)

  @doc "JetStream result subject consumed by the projector."
  @spec result_subject() :: String.t()
  def result_subject, do: @result_subject

  @doc """
  Returns `true` when an ingestion error indicates the message should be
  terminally dropped/ACKed without retry (e.g. deleted/quarantined recording or
  schema/digest violation).
  """
  @spec terminal_drop?(term()) :: boolean()
  def terminal_drop?(:unmatched_result_job), do: true
  def terminal_drop?(:recording_gone), do: true
  def terminal_drop?(:descriptor_sha256_mismatch), do: true
  def terminal_drop?(:invalid_result_envelope), do: true
  def terminal_drop?(:invalid_embedding_vector), do: true
  def terminal_drop?(:invalid_bbox), do: true
  def terminal_drop?(_), do: false

  @doc """
  Validates and projects one `media.results.visual_index.v1` envelope (JSON
  binary or decoded map) idempotently into CNPG.
  """
  @spec ingest_result(binary() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_result(envelope, opts \\ [])

  def ingest_result(raw_json, opts) when is_binary(raw_json) and is_list(opts) do
    case decode_result(raw_json) do
      {:ok, envelope} -> ingest_result(envelope, opts)
      {:error, reason, nil} -> {:error, reason}
      {:error, :invalid_result_envelope, header} -> ingest_result(header, opts)
    end
  end

  def ingest_result(envelope, opts) when is_map(envelope) and is_list(opts) do
    with {:ok, identity} <- parse_identity(envelope) do
      frames =
        with :ok <- validate_schema_version(envelope) do
          parse_frames(fetch_val(envelope, :frames), identity.embedding_dim)
        end

      transact_projection(identity, frames, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
    end
  end

  def ingest_result(_, _), do: {:error, :invalid_result_envelope}

  @doc false
  def decode_result(raw_json)
      when is_binary(raw_json) and byte_size(raw_json) <= @max_envelope_bytes do
    decoders = [
      object_finish: fn pairs, acc -> {Jason.OrderedObject.new(Enum.reverse(pairs)), acc} end,
      float: &decode_float/1,
      integer: &decode_integer/1
    ]

    case JSON.decode(raw_json, nil, decoders) do
      {%Jason.OrderedObject{} = object, nil, ""} ->
        case JSONDocument.to_map(object, arrays: true) do
          {:ok, _envelope} = result -> result
          {:error, :invalid_request} -> {:error, :invalid_result_envelope, result_header(object)}
        end

      _ ->
        {:error, :invalid_result_envelope, nil}
    end
  end

  def decode_result(_), do: {:error, :invalid_result_envelope, nil}

  defp decode_float(token) do
    String.to_float(token)
  rescue
    ArgumentError -> :out_of_range
  end

  defp decode_integer(token) when byte_size(token) <= 20, do: String.to_integer(token)
  defp decode_integer(_), do: :out_of_range

  defp result_header(%Jason.OrderedObject{values: pairs}) do
    keys = ~w(job_id catalog_entry_id descriptor_sha256 detector_model_id detector_model_version
              embedder_model_id embedder_model_version model_id model_version embedding_dim)
    header = Jason.OrderedObject.new(Enum.filter(pairs, fn {key, _} -> key in keys end))

    case JSONDocument.to_map(header) do
      {:ok, map} -> map
      {:error, _} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Envelope Validation
  # ---------------------------------------------------------------------------

  defp parse_identity(env) do
    with {:ok, catalog_entry_id} <- cast_uuid(fetch_val(env, :catalog_entry_id)),
         {:ok, job_id} <- cast_optional_uuid(fetch_val(env, :job_id)),
         {:ok, descriptor_sha256} <- parse_hex64(fetch_val(env, :descriptor_sha256)),
         {:ok, det_model_id} <- parse_non_empty(fetch_val(env, :detector_model_id), 128),
         {:ok, det_model_ver} <-
           parse_non_empty(fetch_val(env, :detector_model_version), 64),
         {:ok, emb_model_id} <- model_identity(env, :embedder_model_id, :model_id, 128),
         {:ok, emb_model_ver} <- model_identity(env, :embedder_model_version, :model_version, 64),
         {:ok, embedding_dim} <- parse_dim(fetch_val(env, :embedding_dim)) do
      {:ok,
       %{
         job_id: job_id,
         catalog_entry_id: catalog_entry_id,
         descriptor_sha256: descriptor_sha256,
         detector_model_id: det_model_id,
         detector_model_version: det_model_ver,
         embedder_model_id: emb_model_id,
         embedder_model_version: emb_model_ver,
         embedding_dim: embedding_dim
       }}
    end
  end

  defp model_identity(env, field, alternate, max_length) do
    case {fetch_val(env, field), fetch_val(env, alternate)} do
      {nil, value} -> parse_non_empty(value, max_length)
      {value, nil} -> parse_non_empty(value, max_length)
      {value, value} -> parse_non_empty(value, max_length)
      _ -> {:error, :unmatched_result_job}
    end
  end

  defp validate_schema_version(env) do
    ver = fetch_val(env, :schema_version)
    schema = fetch_val(env, :schema)

    if ver in [nil, 1] and schema in [nil, @result_subject] do
      :ok
    else
      {:error, :invalid_result_envelope}
    end
  end

  defp parse_dim(dim) when dim in @allowed_dims, do: {:ok, dim}
  defp parse_dim(_), do: {:error, :invalid_embedding_vector}

  defp parse_frames(frames, dim)
       when is_list(frames) and length(frames) <= @max_frames_per_result do
    frames
    |> Enum.reduce_while({:ok, []}, fn raw_frame, {:ok, acc} ->
      case parse_single_frame(raw_frame, dim) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp parse_frames(_, _), do: {:error, :invalid_result_envelope}

  defp parse_single_frame(frame, dim) when is_map(frame) do
    seq = fetch_val(frame, :fragment_sequence) || fetch_val(frame, :fragment_index)
    pts_ns = fetch_val(frame, :media_pts_ns) || fetch_val(frame, :media_offset_ns)
    suppressed = fetch_val(frame, :scene_suppressed) == true
    raw_detections = fetch_val(frame, :detections) || []
    raw_embeddings = fetch_val(frame, :embeddings) || []

    with true <- seq in 0..@max_bigint,
         true <- pts_ns in 0..@max_bigint,
         {:ok, detections} <- parse_detections(raw_detections),
         {:ok, embeddings} <- parse_embeddings(raw_embeddings, dim) do
      {:ok,
       %{
         fragment_sequence: seq,
         media_pts_ns: pts_ns,
         scene_suppressed: suppressed,
         detections: detections,
         embeddings: embeddings
       }}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_result_envelope}
    end
  end

  defp parse_single_frame(_, _), do: {:error, :invalid_result_envelope}

  defp parse_detections(list) when is_list(list) and length(list) <= 64 do
    list
    |> Enum.reduce_while({:ok, []}, fn det, {:ok, acc} ->
      case normalize_detection(det) do
        {:ok, norm} -> {:cont, {:ok, [norm | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp parse_detections(_), do: {:error, :invalid_result_envelope}

  defp normalize_detection(det) when is_map(det) do
    cls = fetch_val(det, :object_class) || fetch_val(det, :class) || fetch_val(det, :label)
    conf = fetch_val(det, :confidence) || fetch_val(det, :score)
    raw_bbox = fetch_val(det, :bbox) || fetch_val(det, :bbox_norm)

    with {:ok, norm_cls} <- parse_non_empty(cls, 64),
         true <- is_nil(conf) or (is_number(conf) and conf >= 0.0 and conf <= 1.0),
         {:ok, bbox} <- parse_required_bbox(raw_bbox),
         {:ok, colors} <- parse_colors(fetch_val(det, :dominant_colors)) do
      {:ok,
       %{
         "object_class" => norm_cls,
         "confidence" => if(is_number(conf), do: conf * 1.0),
         "bbox" => bbox,
         "dominant_colors" => colors
       }}
    else
      {:error, :invalid_bbox} = err -> err
      _ -> {:error, :invalid_result_envelope}
    end
  end

  defp normalize_detection(_), do: {:error, :invalid_result_envelope}

  defp parse_embeddings(list, dim)
       when is_list(list) and length(list) <= @max_embeddings_per_frame do
    list
    |> Enum.reduce_while({:ok, []}, fn emb, {:ok, acc} ->
      case parse_single_embedding(emb, dim) do
        {:ok, norm} -> {:cont, {:ok, [norm | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp parse_embeddings(_, _), do: {:error, :invalid_result_envelope}

  defp parse_single_embedding(emb, dim) when is_map(emb) do
    raw_kind = fetch_val(emb, :region_kind) || fetch_val(emb, :embedding_kind)
    raw_idx = fetch_val(emb, :region_index) || fetch_val(emb, :crop_index) || 0
    raw_cls = fetch_val(emb, :object_class)
    raw_conf = fetch_val(emb, :confidence) || fetch_val(emb, :detector_confidence)
    raw_bbox = fetch_val(emb, :bbox) || fetch_val(emb, :bbox_norm)
    attrs = fetch_val(emb, :attributes) || %{}

    raw_colors =
      fetch_val(emb, :dominant_colors) ||
        (is_map(attrs) && fetch_val(attrs, :dominant_colors)) ||
        []

    raw_vec = fetch_val(emb, :embedding) || fetch_val(emb, :vector)

    with {:ok, kind} <- parse_region_kind(raw_kind),
         true <- raw_idx in 0..@max_bigint,
         {:ok, obj_class} <- parse_optional_class(kind, raw_cls),
         {:ok, conf} <- parse_optional_confidence(kind, raw_conf),
         {:ok, bbox} <- parse_region_bbox(kind, raw_bbox),
         {:ok, colors} <- parse_colors(raw_colors),
         {:ok, vec} <- normalize_l2_vector(raw_vec, dim) do
      {:ok,
       %{
         region_kind: kind,
         region_index: if(kind == :scene, do: 0, else: raw_idx),
         object_class: obj_class,
         confidence: conf,
         bbox: bbox,
         dominant_colors: colors,
         embedding: vec
       }}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_result_envelope}
    end
  end

  defp parse_single_embedding(_, _), do: {:error, :invalid_result_envelope}

  defp parse_region_kind(k) when k in [:scene, "scene"], do: {:ok, :scene}
  defp parse_region_kind(k) when k in [:crop, "crop"], do: {:ok, :crop}
  defp parse_region_kind(_), do: {:error, :invalid_result_envelope}

  defp parse_optional_class(:scene, nil), do: {:ok, nil}
  defp parse_optional_class(:scene, ""), do: {:ok, nil}
  defp parse_optional_class(:scene, _), do: {:error, :invalid_result_envelope}
  defp parse_optional_class(:crop, nil), do: {:ok, nil}

  defp parse_optional_class(:crop, cls), do: parse_non_empty(cls, 64)
  defp parse_optional_class(_, _), do: {:error, :invalid_result_envelope}

  defp parse_optional_confidence(:scene, nil), do: {:ok, nil}
  defp parse_optional_confidence(:scene, _), do: {:error, :invalid_result_envelope}
  defp parse_optional_confidence(:crop, nil), do: {:ok, nil}

  defp parse_optional_confidence(:crop, c) when is_number(c) and c >= 0.0 and c <= 1.0,
    do: {:ok, c * 1.0}

  defp parse_optional_confidence(_, _), do: {:error, :invalid_result_envelope}

  defp parse_region_bbox(:scene, nil), do: {:ok, nil}
  defp parse_region_bbox(:scene, _), do: {:error, :invalid_bbox}
  defp parse_region_bbox(:crop, nil), do: {:ok, nil}
  defp parse_region_bbox(:crop, raw), do: parse_required_bbox(raw)

  defp parse_required_bbox([x1, y1, x2, y2]) do
    validate_bbox_coords(x1, y1, x2, y2)
  end

  defp parse_required_bbox(map) when is_map(map) do
    validate_bbox_coords(
      fetch_val(map, :x1),
      fetch_val(map, :y1),
      fetch_val(map, :x2),
      fetch_val(map, :y2)
    )
  end

  defp parse_required_bbox(_), do: {:error, :invalid_bbox}

  defp validate_bbox_coords(x1, y1, x2, y2) do
    if unit_num?(x1) and unit_num?(y1) and unit_num?(x2) and unit_num?(y2) and x1 < x2 and y1 < y2 do
      {:ok, %{"x1" => x1 * 1.0, "y1" => y1 * 1.0, "x2" => x2 * 1.0, "y2" => y2 * 1.0}}
    else
      {:error, :invalid_bbox}
    end
  end

  defp unit_num?(v), do: is_number(v) and v >= 0.0 and v <= 1.0

  defp parse_colors(list) when is_list(list) do
    colors = Enum.filter(list, &is_binary/1)

    if Enum.any?(colors, &String.contains?(&1, <<0>>)) do
      {:error, :invalid_result_envelope}
    else
      normalized =
        colors
        |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
        |> Enum.reject(&(&1 == "" or byte_size(&1) > 32))
        |> Enum.uniq()
        |> Enum.take(@max_colors_per_embedding)

      {:ok, normalized}
    end
  end

  defp parse_colors(_), do: {:ok, []}

  defp normalize_l2_vector(%Ash.Vector{dimensions: dim} = vec, expected_dim)
       when dim == expected_dim do
    normalize_l2_vector(Ash.Vector.to_list(vec), expected_dim)
  end

  defp normalize_l2_vector(values, expected_dim)
       when is_list(values) and length(values) == expected_dim do
    sum_sq =
      Enum.reduce_while(values, 0.0, fn
        v, acc when is_number(v) and abs(v) <= 1.0 + @norm_tolerance -> {:cont, acc + v * v}
        _, _ -> {:halt, :invalid}
      end)

    case sum_sq do
      :invalid ->
        {:error, :invalid_embedding_vector}

      sq when is_float(sq) and sq > 1.0e-12 ->
        norm = :math.sqrt(sq)

        if abs(norm - 1.0) <= @norm_tolerance do
          normalized = Enum.map(values, &(&1 / norm))
          Ash.Vector.new(normalized)
        else
          {:error, :invalid_embedding_vector}
        end

      _ ->
        {:error, :invalid_embedding_vector}
    end
  end

  defp normalize_l2_vector(_, _), do: {:error, :invalid_embedding_vector}

  # ---------------------------------------------------------------------------
  # Transactional Projection
  # ---------------------------------------------------------------------------

  defp transact_projection(parsed, frames, now) do
    [RecordingCatalogEntry, VisualIndexJob, VisualFrame, VisualEmbedding]
    |> Ash.transact(fn ->
      execute_projection(parsed, frames, now)
    end)
    |> unwrap_transaction()
  end

  defp execute_projection(parsed, frames, now) do
    entry_id = parsed.catalog_entry_id

    entry =
      RecordingCatalogEntry
      |> Ash.Query.filter(id == ^entry_id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: @system_actor)

    with {:ok, job} <- matching_job(parsed) do
      project_job(job, entry, parsed, frames, now)
    end
  end

  defp project_job(nil, _entry, _parsed, _frames, _now), do: :unmatched_result_job

  defp project_job(job, _entry, _parsed, {:error, reason}, _now), do: {:reject, job, reason}

  defp project_job(job, entry, parsed, {:ok, frames}, now) do
    cond do
      is_nil(entry) or not RecordingCatalogEntry.playable?(entry) ->
        cancel_jobs_for_entry(parsed.catalog_entry_id)

      job.state in [:completed, :cancelled, :failed_terminal] ->
        projection_summary(job, [])

      entry.descriptor_sha256 != parsed.descriptor_sha256 ->
        {:reject, job, :descriptor_sha256_mismatch}

      true ->
        store_frames(entry, parsed, frames)

        with {:ok, _} <- complete_job(job, now), do: projection_summary(job, frames)
    end
  end

  defp projection_summary(job, frames) do
    {:ok,
     %{
       status: :ingested,
       catalog_entry_id: job.catalog_entry_id,
       job_id: job.id,
       frame_count: length(frames),
       embedding_count: Enum.sum_by(frames, &length(&1.embeddings))
     }}
  end

  defp store_frames(entry, parsed, frames) do
    Enum.each(frames, fn f_spec ->
      timeline_ts_us = compute_timeline_ts_us(entry, f_spec.media_pts_ns)

      {:ok, frame} =
        VisualFrame
        |> Ash.Changeset.for_create(
          :upsert_frame,
          %{
            catalog_entry_id: entry.id,
            camera_source_id: entry.camera_source_id,
            stream_profile_id: entry.stream_profile_id,
            fragment_sequence: f_spec.fragment_sequence,
            media_pts_ns: f_spec.media_pts_ns,
            timeline_ts_us: timeline_ts_us,
            time_basis: entry.time_basis || :received,
            scene_suppressed: f_spec.scene_suppressed,
            detector_model_id: parsed.detector_model_id,
            detector_model_version: parsed.detector_model_version,
            detections: f_spec.detections
          },
          actor: @system_actor
        )
        |> Ash.create(actor: @system_actor)

      upsert_frame_embeddings(entry, frame, timeline_ts_us, parsed, f_spec.embeddings)
    end)
  end

  defp upsert_frame_embeddings(entry, frame, timeline_ts_us, parsed, embeddings) do
    Enum.each(embeddings, fn emb_spec ->
      {:ok, _} =
        VisualEmbedding
        |> Ash.Changeset.for_create(
          :upsert_embedding,
          %{
            visual_frame_id: frame.id,
            catalog_entry_id: entry.id,
            camera_source_id: entry.camera_source_id,
            stream_profile_id: entry.stream_profile_id,
            timeline_ts_us: timeline_ts_us,
            region_kind: emb_spec.region_kind,
            region_index: emb_spec.region_index,
            object_class: emb_spec.object_class,
            confidence: emb_spec.confidence,
            bbox: emb_spec.bbox,
            dominant_colors: emb_spec.dominant_colors,
            model_id: parsed.embedder_model_id,
            model_version: parsed.embedder_model_version,
            embedding_dim: parsed.embedding_dim,
            embedding: emb_spec.embedding
          },
          actor: @system_actor
        )
        |> Ash.create(actor: @system_actor)
    end)
  end

  defp compute_timeline_ts_us(entry, media_pts_ns) do
    base_ns = entry.media_start_ns || 0
    offset_us = div(max(0, media_pts_ns - base_ns), 1_000)
    candidate = entry.timeline_start_us + offset_us
    min(entry.timeline_end_us, candidate)
  end

  defp matching_job(parsed) do
    query =
      VisualIndexJob
      |> Ash.Query.filter(
        catalog_entry_id == ^parsed.catalog_entry_id and
          descriptor_sha256 == ^parsed.descriptor_sha256 and
          detector_model_id == ^parsed.detector_model_id and
          detector_model_version == ^parsed.detector_model_version and
          embedder_model_id == ^parsed.embedder_model_id and
          embedder_model_version == ^parsed.embedder_model_version and
          embedding_dim == ^parsed.embedding_dim
      )
      |> Ash.Query.lock(:for_update)

    query = if parsed.job_id, do: Ash.Query.filter(query, id == ^parsed.job_id), else: query
    Ash.read_one(query, actor: @system_actor)
  end

  defp complete_job(job, now) do
    job
    |> Ash.Changeset.for_update(:mark_completed, %{completed_at: now})
    |> Ash.Changeset.filter(expr(state in [:pending, :dispatched]))
    |> Ash.update(actor: @system_actor)
  end

  defp cancel_jobs_for_entry(entry_id) do
    VisualIndexJob
    |> Ash.Query.filter(catalog_entry_id == ^entry_id and state in [:pending, :dispatched])
    |> Ash.bulk_update(:mark_cancelled, %{last_error_class: "source_deleted_or_quarantined"},
      actor: @system_actor,
      strategy: [:atomic],
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :recording_gone
      %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
    end
  end

  defp unwrap_transaction({:ok, {:ok, _} = projection}), do: projection
  defp unwrap_transaction({:ok, :recording_gone}), do: {:error, :recording_gone}
  defp unwrap_transaction({:ok, :unmatched_result_job}), do: {:error, :unmatched_result_job}

  defp unwrap_transaction({:ok, {:reject, job, reason}}) do
    with {:ok, _} <- VisualIndexDispatcher.reconcile_exhausted_job(job, Atom.to_string(reason)) do
      {:error, reason}
    end
  end

  defp unwrap_transaction(other), do: other

  defp cast_uuid(val) when is_binary(val) do
    case Ecto.UUID.cast(val) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_result_envelope}
    end
  end

  defp cast_uuid(_), do: {:error, :invalid_result_envelope}

  defp cast_optional_uuid(nil), do: {:ok, nil}
  defp cast_optional_uuid(val), do: cast_uuid(val)

  defp parse_hex64(val) when is_binary(val) do
    if Regex.match?(@hex64, val), do: {:ok, val}, else: {:error, :invalid_result_envelope}
  end

  defp parse_hex64(_), do: {:error, :invalid_result_envelope}

  defp parse_non_empty(val, max_len) when is_binary(val) do
    trimmed = String.trim(val)

    if byte_size(trimmed) in 1..max_len and not String.contains?(trimmed, <<0>>) do
      {:ok, trimmed}
    else
      {:error, :invalid_result_envelope}
    end
  end

  defp parse_non_empty(_, _), do: {:error, :invalid_result_envelope}

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end

defmodule ServiceRadar.Camera.VisualIndexResultProjector do
  @moduledoc """
  Idempotent JetStream result projector (`media.results.visual_index.v1`) for
  `VisualFrame`, `VisualEmbedding`, and `VisualIndexJob` (`3.1`, `design.md` `4.2`).

  Core validates the worker envelope before resolving the admitted job and recording under lock.
  The following dispositions apply in order. A job match requires the catalog entry, descriptor
  digest, detector and embedder identities, dimension, and job ID when supplied.

  | Validation | Job | Recording | Action |
  | --- | --- | --- | --- |
  | Any | No matching identity | Any | Dead-letter without writes |
  | Invalid | Final | Any | Dead-letter without changing the job or health |
  | Valid | Final | Any | Acknowledge without writes |
  | Any | Active | Gone | Cancel active jobs for the recording and acknowledge |
  | Any | Active | Temporarily unavailable | Retry without writes |
  | Invalid, including a stale catalog digest | Active | Playable | Fail the job, report health, and dead-letter |
  | Valid | Active | Playable | Store optional block/frame thumbnails, frames and embeddings, complete the job, and acknowledge |

  Pending and dispatched jobs are active. Completed, cancelled and terminally failed jobs are final.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.VisualEmbedding
  alias ServiceRadar.Camera.VisualFrame
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.Camera.VisualIndexResultEnvelope
  alias ServiceRadar.JSONDocument

  require Ash.Query

  @max_envelope_bytes 4_194_304

  @system_actor SystemActor.system(:camera_visual_index_result_projector)

  @doc "JetStream result subject consumed by the projector."
  @spec result_subject() :: String.t()
  defdelegate result_subject(), to: VisualIndexResultEnvelope

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
    with {:ok, identity, validation} <- VisualIndexResultEnvelope.validate(envelope) do
      transact_projection(identity, validation, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
    end
  end

  def ingest_result(_, _), do: {:error, :invalid_result_envelope}

  defp decode_result(raw_json)
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

  defp decode_result(_), do: {:error, :invalid_result_envelope, nil}

  defp decode_float(token) do
    case Float.parse(token) do
      {value, ""} -> value
      _ -> :out_of_range
    end
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

  defp transact_projection(parsed, validation, now) do
    [RecordingCatalogEntry, VisualIndexJob, VisualFrame, VisualEmbedding]
    |> Ash.transact(fn ->
      execute_projection(parsed, validation, now)
    end)
    |> unwrap_transaction()
  end

  defp execute_projection(parsed, validation, now) do
    entry_id = parsed.catalog_entry_id

    entry =
      RecordingCatalogEntry
      |> Ash.Query.filter(id == ^entry_id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: @system_actor)

    with {:ok, job} <- matching_job(parsed) do
      recording = RecordingCatalogEntry.availability(entry)

      validation =
        if match?({:ok, _}, validation) and recording == :playable and
             entry.descriptor_sha256 != parsed.descriptor_sha256,
           do: {:error, :descriptor_sha256_mismatch},
           else: validation

      case disposition(validation, job && job.state, recording) do
        {:store, frames, block_thumbnail_jpeg} ->
          store_block_thumbnail(entry, block_thumbnail_jpeg)
          store_frames(entry, parsed, frames)

          with {:ok, _} <- complete_job(job, now) do
            projection_summary(job, frames)
          end

        :ack ->
          projection_summary(job, [])

        :cancel ->
          cancel_jobs_for_entry(entry_id)

        {:fail, reason} ->
          with {:ok, failed_job} <- fail_job(job, Atom.to_string(reason)) do
            {:failed_terminal, failed_job, reason}
          end

        {:report, reason} ->
          {:report, reason}
      end
    end
  end

  defp disposition(_, nil, _), do: {:report, :unmatched_result_job}

  defp disposition({:error, reason}, state, _)
       when state in [:completed, :cancelled, :failed_terminal],
       do: {:report, reason}

  defp disposition({:ok, _}, state, :recording_gone)
       when state in [:completed, :cancelled, :failed_terminal],
       do: {:report, :recording_gone}

  defp disposition({:ok, _}, state, _) when state in [:completed, :cancelled, :failed_terminal],
    do: :ack

  defp disposition(_, _, :recording_gone), do: :cancel
  defp disposition(_, _, :recording_unavailable), do: {:report, :recording_unavailable}
  defp disposition({:error, reason}, _, :playable), do: {:fail, reason}

  defp disposition({:ok, %{frames: frames} = body}, _, :playable) do
    {:store, frames, Map.get(body, :block_thumbnail_jpeg)}
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

  defp store_block_thumbnail(_entry, nil), do: :ok

  defp store_block_thumbnail(entry, thumbnail_jpeg) when is_binary(thumbnail_jpeg) do
    {:ok, _} =
      entry
      |> Ash.Changeset.for_update(:set_thumbnail, %{thumbnail_jpeg: thumbnail_jpeg},
        actor: @system_actor
      )
      |> Ash.update(actor: @system_actor)

    :ok
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
            detections: f_spec.detections,
            thumbnail_jpeg: Map.get(f_spec, :thumbnail_jpeg)
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

  defp fail_job(job, error_class) do
    job
    |> Ash.Changeset.for_update(:mark_failed_terminal, %{last_error_class: error_class})
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
  defp unwrap_transaction({:ok, {:report, reason}}), do: {:error, reason}

  defp unwrap_transaction({:ok, {:failed_terminal, job, reason}}) do
    try do
      _ = VisualIndexDispatcher.record_terminal_failure_health(job, Atom.to_string(reason))
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    {:error, reason}
  end

  defp unwrap_transaction(other), do: other
end

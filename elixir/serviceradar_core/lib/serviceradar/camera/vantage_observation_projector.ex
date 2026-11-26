defmodule ServiceRadar.Camera.VantageObservationProjector do
  @moduledoc """
  Idempotent JetStream result projector (`media.results.vantage.v1`) for
  `ServiceRadar.Camera.VantageObservation` and `ServiceRadar.Camera.VantageJob`,
  with pack `signal_schema` validation (`ExJsonSchema`), PubSub notifications,
  and optional canonical OCSF Event Log Activity (`1008`) emission.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingPubSub
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.Validations.VantageSignalSchema
  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Camera.VantageObservation
  alias ServiceRadar.Camera.VantageObservationEnvelope
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Camera.VantagePubSub
  alias ServiceRadar.Events.OcsfEventPublisher
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.EventWriter.StableId
  alias ServiceRadar.JSONDocument

  require Ash.Query
  require Logger

  @max_envelope_bytes VantageObservationEnvelope.max_envelope_bytes()
  @system_actor SystemActor.system(:camera_vantage_observation_projector)

  @doc "JetStream subject consumed by the Vantage observation projector."
  @spec result_subject() :: String.t()
  defdelegate result_subject(), to: VantageObservationEnvelope

  @doc "Returns `true` when Vantage pipeline ingestion is enabled."
  @spec deployment_enabled?((String.t(), String.t() -> String.t() | nil)) :: boolean()
  def deployment_enabled?(fetch \\ &System.get_env/2) when is_function(fetch, 2) do
    fetch.("SERVICERADAR_VANTAGE_PIPELINES_ENABLED", "false") == "true"
  end

  @doc """
  Returns `true` when an ingestion error indicates the message should be
  terminally dead-lettered (`:term`) without retry.
  """
  @spec terminal_drop?(term()) :: boolean()
  def terminal_drop?(:unmatched_result_job), do: true
  def terminal_drop?(:unmatched_pipeline), do: true
  def terminal_drop?(:camera_source_not_found), do: true
  def terminal_drop?(:recording_gone), do: true
  def terminal_drop?(:descriptor_sha256_mismatch), do: true
  def terminal_drop?(:invalid_result_envelope), do: true
  def terminal_drop?(:envelope_too_large), do: true
  def terminal_drop?(:invalid_bbox), do: true
  def terminal_drop?(:invalid_crop_jpeg), do: true
  def terminal_drop?(:crop_too_large), do: true
  def terminal_drop?(:signal_schema_violation), do: true
  def terminal_drop?(_), do: false

  @doc """
  Validates `attributes` against a pack `signal_schema` map using `ExJsonSchema`
  (cycle-checking `$ref` chains and normalizing Draft 2020-12 `$defs` /
  `dependentRequired` / top-level `$schema`).
  """
  @spec validate_signal_schema(map() | nil, map()) :: :ok | {:error, :signal_schema_violation}
  def validate_signal_schema(schema, attributes) do
    VantageSignalSchema.validate_attributes(schema, attributes)
  end

  @doc """
  Validates and projects one `media.results.vantage.v1` envelope (JSON binary
  or decoded map) idempotently into CNPG.
  """
  @spec ingest_result(binary() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_result(envelope, opts \\ [])

  def ingest_result(raw_json, _opts)
      when is_binary(raw_json) and byte_size(raw_json) > @max_envelope_bytes do
    {:error, :envelope_too_large}
  end

  def ingest_result(raw_json, opts) when is_binary(raw_json) and is_list(opts) do
    case decode_result(raw_json) do
      {:ok, envelope} -> ingest_result(envelope, opts)
      {:error, reason, nil} -> {:error, reason}
      {:error, :invalid_result_envelope, header} -> ingest_result(header, opts)
    end
  end

  def ingest_result(envelope, opts) when is_map(envelope) and is_list(opts) do
    with {:ok, identity, validation} <- VantageObservationEnvelope.validate(envelope) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      transact_projection(identity, validation, now, opts)
    end
  end

  def ingest_result(_, _), do: {:error, :invalid_result_envelope}

  defp decode_result(raw_json) when is_binary(raw_json) do
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

  defp decode_float(token) do
    case Float.parse(token) do
      {value, ""} -> value
      _ -> :out_of_range
    end
  end

  defp decode_integer(token) when byte_size(token) <= 20, do: String.to_integer(token)
  defp decode_integer(_), do: :out_of_range

  defp result_header(%Jason.OrderedObject{values: pairs}) do
    keys =
      ~w(source_mode job_id catalog_entry_id descriptor_sha256 camera_source_id stream_profile_id
         pack_id pipeline_id pipeline_version worker_kind worker_id model_id model_version capability)

    header = Jason.OrderedObject.new(Enum.filter(pairs, fn {key, _} -> key in keys end))

    case JSONDocument.to_map(header) do
      {:ok, map} -> map
      {:error, _} -> nil
    end
  end

  defp transact_projection(identity, validation, now, opts) do
    [RecordingCatalogEntry, VantagePipeline, VantageJob, VantageObservation, Source]
    |> Ash.transact(fn ->
      execute_projection(identity, validation, now)
    end)
    |> unwrap_transaction(opts)
  end

  defp execute_projection(identity, validation, now) do
    case load_pipeline(identity) do
      nil ->
        {:report, :unmatched_pipeline}

      pipeline ->
        validation = validate_observations_against_pipeline(validation, pipeline)
        project_for_mode(identity, pipeline, validation, now)
    end
  end

  defp load_pipeline(identity) do
    VantagePipeline
    |> Ash.Query.filter(
      pipeline_id == ^identity.pipeline_id and
        version == ^identity.pipeline_version
    )
    |> Ash.read_one!(actor: @system_actor)
  end

  defp validate_observations_against_pipeline({:error, _} = err, _pipeline), do: err

  defp validate_observations_against_pipeline(
         {:ok, %{observations: observations} = body},
         pipeline
       ) do
    valid? =
      Enum.all?(observations, fn obs ->
        obs.signal_schema_id == pipeline.signal_schema_id and
          obs.signal_schema_version == pipeline.signal_schema_version and
          validate_signal_schema(pipeline.signal_schema, obs.attributes) == :ok
      end)

    if valid? do
      {:ok, body}
    else
      {:error, :signal_schema_violation}
    end
  end

  defp project_for_mode(%{source_mode: :recorded_block} = identity, pipeline, validation, now) do
    entry_id = identity.catalog_entry_id

    entry =
      RecordingCatalogEntry
      |> Ash.Query.filter(id == ^entry_id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: @system_actor)

    with {:ok, job} <- matching_job(identity) do
      recording = RecordingCatalogEntry.availability(entry)

      validation =
        if match?({:ok, _}, validation) and recording == :playable and
             entry.descriptor_sha256 != identity.descriptor_sha256,
           do: {:error, :descriptor_sha256_mismatch},
           else: validation

      case disposition(validation, job && job.state, recording) do
        {:store, observations} ->
          stored = upsert_observations(identity, entry, job, observations)

          with {:ok, _} <- complete_job(job, now),
               {:ok, summary} <- projection_summary(job.catalog_entry_id, job.id, stored) do
            {:ingested, summary, stored, pipeline, :recorded_block}
          end

        :ack ->
          projection_summary(job.catalog_entry_id, job.id, [])

        :cancel ->
          cancel_jobs_for_entry(entry_id)

        {:fail, reason} ->
          with {:ok, _failed_job} <- fail_job(job, Atom.to_string(reason)) do
            {:report, reason}
          end

        {:report, reason} ->
          {:report, reason}
      end
    end
  end

  defp project_for_mode(%{source_mode: :live_keyframe_tap} = identity, pipeline, validation, _now) do
    cond do
      not pipeline.enabled or pipeline.source_mode != :live_keyframe_tap ->
        {:report, :unmatched_pipeline}

      is_nil(load_source(identity.camera_source_id)) ->
        {:report, :camera_source_not_found}

      true ->
        project_live_tap(identity, pipeline, validation)
    end
  end

  defp project_live_tap(identity, pipeline, {:ok, %{observations: observations}}) do
    entry =
      if is_binary(identity.catalog_entry_id) do
        RecordingCatalogEntry
        |> Ash.Query.filter(id == ^identity.catalog_entry_id)
        |> Ash.read_one!(actor: @system_actor)
      end

    if is_binary(identity.catalog_entry_id) and
         RecordingCatalogEntry.availability(entry) == :recording_gone do
      {:report, :recording_gone}
    else
      stored = upsert_observations(identity, entry, nil, observations)

      {:ok, summary} =
        projection_summary(identity.catalog_entry_id, nil, stored)

      {:ingested, summary, stored, pipeline, :live_keyframe_tap}
    end
  end

  defp project_live_tap(_identity, _pipeline, {:error, reason}), do: {:report, reason}

  defp load_source(camera_source_id) do
    case Ash.get(Source, camera_source_id, actor: @system_actor, not_found_error?: false) do
      {:ok, %Source{} = source} -> source
      _ -> nil
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
  defp disposition({:ok, %{observations: observations}}, _, :playable), do: {:store, observations}

  defp projection_summary(catalog_entry_id, job_id, stored) do
    {:ok,
     %{
       status: :ingested,
       catalog_entry_id: catalog_entry_id,
       job_id: job_id,
       observation_count: length(stored)
     }}
  end

  defp upsert_observations(identity, entry, job, observations) do
    Enum.map(observations, fn obs ->
      attrs = %{
        observation_key: obs.observation_key,
        pack_id: identity.pack_id,
        pipeline_id: identity.pipeline_id,
        pipeline_version: identity.pipeline_version,
        worker_kind: identity.worker_kind,
        worker_id: identity.worker_id,
        model_id: identity.model_id,
        model_version: identity.model_version,
        job_id: job && job.id,
        catalog_entry_id: entry && entry.id,
        camera_source_id: identity.camera_source_id,
        stream_profile_id: identity.stream_profile_id,
        source_mode: identity.source_mode,
        fragment_sequence: obs.fragment_sequence,
        frame_sequence: obs.frame_sequence,
        media_pts_ns: obs.media_pts_ns,
        timeline_ts_us: obs.timeline_ts_us,
        time_basis: obs.time_basis,
        track_id: obs.track_id,
        category: obs.category,
        label: obs.label,
        confidence: obs.confidence,
        bbox: obs.bbox,
        crop_jpeg: obs.crop_jpeg,
        attributes: obs.attributes,
        signal_schema_id: obs.signal_schema_id,
        signal_schema_version: obs.signal_schema_version,
        display_contract_id: obs.display_contract_id,
        search_text: obs.search_text
      }

      {:ok, record} =
        VantageObservation
        |> Ash.Changeset.for_create(:upsert_observation, attrs, actor: @system_actor)
        |> Ash.create(actor: @system_actor)

      record
    end)
  end

  defp matching_job(identity) do
    VantageJob
    |> Ash.Query.filter(
      id == ^identity.job_id and
        catalog_entry_id == ^identity.catalog_entry_id and
        pipeline_id == ^identity.pipeline_id and
        pipeline_version == ^identity.pipeline_version and
        camera_source_id == ^identity.camera_source_id and
        stream_profile_id == ^identity.stream_profile_id and
        descriptor_sha256 == ^identity.descriptor_sha256
    )
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @system_actor)
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
    VantageJob
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

  defp unwrap_transaction({:ok, {:ingested, summary, stored, pipeline, source_mode}}, opts) do
    broadcast_projected(stored, pipeline, source_mode)
    maybe_emit_ocsf_events(stored, pipeline, opts)
    {:ok, summary}
  end

  defp unwrap_transaction({:ok, {:ok, _} = projection}, _opts), do: projection
  defp unwrap_transaction({:ok, :recording_gone}, _opts), do: {:error, :recording_gone}
  defp unwrap_transaction({:ok, {:report, reason}}, _opts), do: {:error, reason}
  defp unwrap_transaction(other, _opts), do: other

  defp broadcast_projected([], _pipeline, _source_mode), do: :ok

  defp broadcast_projected([first | _] = stored, pipeline, source_mode) do
    camera_source_id = to_string(first.camera_source_id)

    payload = %{
      camera_source_id: camera_source_id,
      pipeline_id: pipeline.pipeline_id,
      pipeline_version: pipeline.version,
      source_mode: source_mode,
      observations:
        Enum.map(stored, fn obs ->
          %{
            id: to_string(obs.id),
            observation_key: obs.observation_key,
            catalog_entry_id: obs.catalog_entry_id && to_string(obs.catalog_entry_id),
            timeline_ts_us: obs.timeline_ts_us,
            time_basis: obs.time_basis,
            category: obs.category,
            label: obs.label,
            confidence: obs.confidence,
            bbox: obs.bbox,
            attributes: obs.attributes,
            signal_schema_id: obs.signal_schema_id,
            display_contract_id: obs.display_contract_id
          }
        end)
    }

    VantagePubSub.broadcast_observations(camera_source_id, payload)

    if source_mode == :recorded_block do
      RecordingPubSub.broadcast_updated(camera_source_id, :vantage_observations_ingested)
    end

    :ok
  end

  defp maybe_emit_ocsf_events([], _pipeline, _opts), do: :ok
  defp maybe_emit_ocsf_events(_stored, %{emit_ocsf_events: false}, _opts), do: :ok

  defp maybe_emit_ocsf_events(stored, %{emit_ocsf_events: true} = pipeline, opts) do
    ocsf_opts = Keyword.get(opts, :ocsf_opts, [])

    Enum.each(stored, fn obs ->
      event_id =
        "vantage-ocsf:#{obs.observation_key}"
        |> StableId.uuid()
        |> Ecto.UUID.load!()

      attrs = %{
        id: event_id,
        time: DateTime.from_unix!(obs.timeline_ts_us, :microsecond),
        class_uid: OCSF.class_event_log_activity(),
        category_uid: OCSF.category_system_activity(),
        type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), OCSF.activity_log_create()),
        activity_id: OCSF.activity_log_create(),
        activity_name: OCSF.log_activity_name(OCSF.activity_log_create()),
        severity_id: OCSF.severity_informational(),
        severity: OCSF.severity_name(OCSF.severity_informational()),
        status_id: OCSF.status_success(),
        status: OCSF.status_name(OCSF.status_success()),
        message: "Vantage #{obs.category}: #{obs.label}",
        log_name: "camera.vantage.observation",
        log_provider: "serviceradar.vantage",
        metadata: %{
          "service_radar" => %{
            "signal_schema" => %{
              "producer_id" => obs.pack_id || pipeline.pipeline_id,
              "producer_version" => obs.pipeline_version,
              "schema_id" => obs.signal_schema_id,
              "schema_version" => obs.signal_schema_version
            },
            "source_type" => "camera_vantage",
            "camera_source_id" => to_string(obs.camera_source_id),
            "stream_profile_id" => to_string(obs.stream_profile_id),
            "catalog_entry_id" => obs.catalog_entry_id && to_string(obs.catalog_entry_id),
            "pipeline_id" => obs.pipeline_id,
            "pipeline_version" => obs.pipeline_version,
            "observation_id" => to_string(obs.id),
            "observation_key" => obs.observation_key,
            "source_mode" => to_string(obs.source_mode),
            "timeline_ts_us" => obs.timeline_ts_us,
            "time_basis" => to_string(obs.time_basis),
            "category" => obs.category,
            "label" => obs.label,
            "confidence" => obs.confidence,
            "bbox" => obs.bbox,
            "attributes" => obs.attributes
          }
        }
      }

      case OcsfEventPublisher.publish(attrs, [{:family, :camera} | ocsf_opts]) do
        {:ok, _event} ->
          :ok

        {:error, :suppressed} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to publish Vantage OCSF event",
            observation_key: obs.observation_key,
            pipeline_id: pipeline.pipeline_id,
            reason: inspect(reason)
          )

          :ok
      end
    end)
  rescue
    error ->
      Logger.warning("Unexpected error publishing Vantage OCSF events",
        pipeline_id: pipeline.pipeline_id,
        reason: Exception.message(error)
      )

      :ok
  end
end

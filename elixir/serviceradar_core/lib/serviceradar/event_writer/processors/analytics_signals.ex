defmodule ServiceRadar.EventWriter.Processors.AnalyticsSignals do
  @moduledoc """
  Processor for external causal signals (BMP and SIEM) consumed via JetStream.

  This processor normalizes external events into a common causal envelope and
  persists them in `ocsf_events` so downstream topology overlays can evaluate
  causality from a durable source.

  Expected subjects include:
  - `arancini.updates.>`
  - `siem.events.>`
  - `signals.analytics.>`
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Automation.Northbound.EventHandlerRunner
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.DeviceCorrelation
  alias ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistry
  alias ServiceRadar.EventWriter.Telemetry, as: EventWriterTelemetry
  alias ServiceRadar.Inventory.EndpointVulnerabilityAssessment
  alias ServiceRadar.Observability.AnomalyDetection.SeriesKey
  alias ServiceRadar.Observability.AnomalyDispositionReporter
  alias ServiceRadar.Observability.BmpSettingsRuntime
  alias ServiceRadar.Observability.CausalPubSub
  alias ServiceRadar.Observability.StatefulAlertEvaluationQueue

  require Logger

  @schema_version "1.0"
  @max_grouped_contexts 32
  @routing_table "bmp_routing_events"
  @bmp_projection_ip_fields ~w(
    router_addr peer_addr prefix_addr
    router_id routerId router_ip routerIp device_ip source_ip
    peer_ip peerIp src_ip
    prefix nlri announced_prefix
  )
  @bmp_mapped_ipv4_pattern ~r/^::ffff:(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?:\/(?:3[0-2]|[12]?[0-9]))?$/i
  @ocsf_vulnerability_finding_class_uid 2002
  @ocsf_detection_finding_class_uid 2004
  @ocsf_findings_category_uid 2
  @ocsf_vulnerability_finding_type_uid 200_201
  @ocsf_vulnerability_finding_update_type_uid 200_202
  @ocsf_vulnerability_finding_close_type_uid 200_203
  @ocsf_detection_finding_type_uid 200_401
  @ocsf_create_activity_id 1
  @structured_series_key_pattern ~r/^v\d+[:|]/
  @legacy_anomaly_class1008_env "SERVICERADAR_ANOMALY_LEGACY_CLASS1008"
  @inventory_vulnerability_lifecycle_lock_prefix "serviceradar:inventory-vulnerability-lifecycle:"
  # Anomaly lifecycle states that represent a CONFIRMED-open anomaly (surface the
  # finding) versus its resolution (surface the clear so downstream alert state
  # machines can close it). Every other anomaly.state value (pending_anomaly, clean,
  # none, insufficient_baseline) is an unconfirmed breadcrumb and is withheld.
  @anomaly_open_states [
    "anomalous",
    "anomaly_open",
    "anomaly_update",
    "anomaly_drift",
    "anomaly_drift_open",
    "anomaly_drift_update"
  ]
  @anomaly_clear_states [
    "anomaly_clear",
    "anomaly_drift_clear",
    "clear",
    "cleared",
    "inactive",
    "resolved",
    "closed"
  ]
  @anomaly_pending_detector_state "pending_anomaly"
  @ocsf_event_conflict_target [:time, :id]
  @ocsf_event_replace_fields [
    :class_uid,
    :category_uid,
    :type_uid,
    :activity_id,
    :activity_name,
    :severity_id,
    :severity,
    :message,
    :status_id,
    :status,
    :status_code,
    :status_detail,
    :metadata,
    :observables,
    :trace_id,
    :span_id,
    :actor,
    :device,
    :src_endpoint,
    :dst_endpoint,
    :log_name,
    :log_provider,
    :log_level,
    :log_version,
    :unmapped,
    :raw_data
  ]

  @impl true
  def table_name, do: "ocsf_events"

  @impl true
  def process_batch(messages) do
    parsed_rows =
      messages
      |> Enum.map(&parse_components/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(parsed_rows) do
      {:ok, 0}
    else
      routing_rows =
        parsed_rows
        |> Enum.filter(&(&1.normalized["signal_type"] == "bmp"))
        |> Enum.map(&build_routing_event_row/1)
        |> Enum.reject(&is_nil/1)

      all_ocsf_rows =
        parsed_rows
        |> Enum.filter(&persist_to_ocsf?/1)
        |> Enum.map(fn %{
                         normalized: normalized,
                         payload: payload,
                         raw_data: raw_data,
                         metadata: metadata
                       } ->
          build_ocsf_event_row(normalized, payload, raw_data, metadata)
        end)
        |> Enum.reject(&is_nil/1)
        |> AnomalyEpisodeRegistry.transition_rows()

      {ash_ocsf_rows, bulk_ocsf_rows} = Enum.split_with(all_ocsf_rows, &ash_recorded_row?/1)

      _ = insert_rows(@routing_table, routing_rows)
      bulk_ocsf_count = insert_rows(table_name(), bulk_ocsf_rows)
      recorded_ocsf_events = record_ocsf_events(ash_ocsf_rows)

      dispatch_northbound_inventory_transitions(recorded_ocsf_events)
      enqueue_alert_evaluation(bulk_ocsf_rows, bulk_ocsf_count)
      enqueue_alert_evaluation(recorded_ocsf_events, length(recorded_ocsf_events))

      report_anomaly_dispositions(recorded_ocsf_events)

      ocsf_count = bulk_ocsf_count + length(recorded_ocsf_events)
      CausalPubSub.broadcast_ingest(%{count: ocsf_count})
      {:ok, length(parsed_rows)}
    end
  rescue
    e ->
      Logger.error("Causal signals batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case parse_components(%{data: data, metadata: metadata}) do
      %{normalized: normalized, payload: payload, raw_data: raw_data, metadata: row_metadata} ->
        build_ocsf_event_row(normalized, payload, raw_data, row_metadata)

      nil ->
        nil
    end
  end

  @doc false
  def alert_evaluation_rows(ocsf_rows) when is_list(ocsf_rows) do
    ocsf_rows
    |> Enum.filter(&alert_evaluation_event_row?/1)
    |> Enum.map(&alert_evaluation_row/1)
  end

  defp parse_components(%{data: data, metadata: metadata}) do
    with {:ok, payload} <- decode_payload(data, metadata),
         projection_payload = canonicalize_bmp_projection_payload(payload, metadata[:subject]),
         {:ok, normalized} <- normalize_payload(projection_payload, metadata, data) do
      %{
        normalized: normalized,
        payload: projection_payload,
        raw_data: data,
        metadata: metadata
      }
    else
      _ ->
        Logger.debug("Failed to parse causal signal payload", subject: metadata[:subject])
        nil
    end
  end

  defp parse_components(_), do: nil

  defp decode_payload(data, metadata) when is_binary(data) and is_map(metadata) do
    case Jason.decode(data) do
      {:ok, payload} ->
        {:ok, payload}

      _ ->
        decode_arancini_capnp_payload(data, metadata)
    end
  end

  defp decode_payload(_data, _metadata), do: {:error, :invalid_payload}

  defp decode_arancini_capnp_payload(data, %{subject: subject}) when is_binary(subject) do
    if arancini_subject?(subject) do
      with {:ok, json_payload} <- ServiceRadarSRQL.Native.decode_arancini_update_capnp(data),
           {:ok, payload} <- Jason.decode(json_payload) do
        {:ok, payload}
      else
        _ -> {:error, :invalid_payload}
      end
    else
      {:error, :invalid_payload}
    end
  end

  defp decode_arancini_capnp_payload(_data, _metadata), do: {:error, :invalid_payload}

  defp insert_rows(_table, []), do: 0

  defp insert_rows(table, rows) when is_list(rows) do
    {count, _} = BulkInsert.insert_all(table, rows, on_conflict: :nothing, returning: false)

    count
  end

  defp record_ocsf_events([]), do: []

  defp record_ocsf_events(rows) when is_list(rows) do
    {valid_rows, invalid_rows} = Enum.split_with(rows, &recordable_ocsf_row?/1)

    Enum.each(invalid_rows, fn row ->
      Logger.warning("Failed to record AnalyticsSignals OCSF event through bulk insert",
        reason: inspect(:missing_event_identity),
        event_id: inspect(row[:id])
      )
    end)

    {inventory_vulnerability_rows, other_rows} =
      Enum.split_with(valid_rows, &inventory_vulnerability_lifecycle_row?/1)

    {causal_rows, insert_only_rows} = Enum.split_with(other_rows, &causal_prediction_row?/1)

    insert_only_rows = record_insert_only_ocsf_events(insert_only_rows)

    inventory_vulnerability_rows =
      record_inventory_vulnerability_ocsf_events(inventory_vulnerability_rows)

    causal_rows = record_causal_prediction_ocsf_events(causal_rows)

    insert_only_rows ++ inventory_vulnerability_rows ++ causal_rows
  end

  defp record_insert_only_ocsf_events([]), do: []

  defp record_insert_only_ocsf_events(rows) when is_list(rows) do
    # Raw insert is intentional: build_ocsf_event_row/4 creates DB-complete rows,
    # including id, time, and created_at; the former Ash action was not providing
    # load-bearing normalization on this hot path.
    {_count, inserted_rows} =
      BulkInsert.insert_all(table_name(), rows,
        on_conflict: :nothing,
        conflict_target: @ocsf_event_conflict_target,
        returning: @ocsf_event_conflict_target
      )

    inserted_keys = MapSet.new(Enum.map(inserted_rows, &ocsf_event_conflict_key/1))

    rows
    |> Enum.filter(&MapSet.member?(inserted_keys, ocsf_event_conflict_key(&1)))
    |> dedupe_rows_by_conflict_key(&ocsf_event_conflict_key/1)
  end

  defp record_inventory_vulnerability_ocsf_events([]), do: []

  defp record_inventory_vulnerability_ocsf_events(rows) when is_list(rows) do
    rows = dedupe_rows_by_conflict_key(rows, &ocsf_event_id_key/1)

    # Transition detection reads the prior row before replacing it. Serialize that
    # read/write pair by stable event identity so concurrent redeliveries cannot
    # both observe the same prior state and publish the same transition.
    {:ok, transition_rows} =
      ServiceRadar.Repo.transaction(fn ->
        acquire_inventory_vulnerability_lifecycle_locks(rows)
        record_inventory_vulnerability_ocsf_events_locked(rows)
      end)

    transition_rows
  end

  defp record_inventory_vulnerability_ocsf_events_locked(rows) do
    existing = existing_inventory_vulnerability_lifecycle(rows)

    aligned_rows =
      rows
      |> Enum.filter(&persist_inventory_vulnerability_lifecycle?(&1, existing))
      |> Enum.map(&prepare_inventory_vulnerability_lifecycle(&1, existing))

    transition_keys =
      aligned_rows
      |> Enum.filter(&inventory_vulnerability_transition?(&1, existing))
      |> MapSet.new(&ocsf_event_conflict_key/1)

    {_count, upserted_rows} =
      BulkInsert.insert_all(table_name(), aligned_rows,
        on_conflict: {:replace, @ocsf_event_replace_fields},
        conflict_target: @ocsf_event_conflict_target,
        returning: @ocsf_event_conflict_target
      )

    upserted_keys = MapSet.new(Enum.map(upserted_rows, &ocsf_event_conflict_key/1))

    aligned_rows
    |> Enum.filter(fn row ->
      key = ocsf_event_conflict_key(row)
      MapSet.member?(transition_keys, key) and MapSet.member?(upserted_keys, key)
    end)
    |> dedupe_rows_by_conflict_key(&ocsf_event_conflict_key/1)
  end

  defp acquire_inventory_vulnerability_lifecycle_locks(rows) do
    rows
    |> Enum.map(&ocsf_event_id_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    # A batch can carry more than one assessment. A stable acquisition order
    # prevents two overlapping batches from deadlocking each other.
    |> Enum.sort()
    |> Enum.each(fn event_id ->
      ServiceRadar.Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        [@inventory_vulnerability_lifecycle_lock_prefix <> event_id]
      )
    end)
  end

  defp existing_inventory_vulnerability_lifecycle(rows) do
    ids =
      rows
      |> Enum.map(&ocsf_event_id_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&uuid_to_binary/1)
      |> Enum.reject(&is_nil/1)

    if ids == [] do
      %{}
    else
      sql = """
      SELECT DISTINCT ON (id) id::text, time, status
      FROM platform.ocsf_events
      WHERE id = ANY($1::uuid[])
      ORDER BY id, time ASC
      """

      %{rows: result_rows} = ServiceRadar.Repo.query!(sql, [ids])

      Map.new(result_rows, fn [id, time, status] ->
        {uuid_conflict_value(id), %{time: normalize_existing_time(time), status: status}}
      end)
    end
  end

  defp inventory_vulnerability_transition?(row, existing) do
    new_status = vulnerability_lifecycle_status(Map.get(row, :status))

    case Map.get(existing, ocsf_event_id_key(row)) do
      nil -> new_status == :open
      %{status: old_status} -> vulnerability_lifecycle_status(old_status) != new_status
    end
  end

  defp persist_inventory_vulnerability_lifecycle?(row, existing) do
    new_status = vulnerability_lifecycle_status(Map.get(row, :status))

    case Map.get(existing, ocsf_event_id_key(row)) do
      nil ->
        new_status == :open

      %{status: old_status} ->
        old_status = vulnerability_lifecycle_status(old_status)
        not (old_status == :resolved and new_status == :resolved)
    end
  end

  defp prepare_inventory_vulnerability_lifecycle(row, existing) do
    existing_row = Map.get(existing, ocsf_event_id_key(row))

    row =
      case existing_row do
        %{time: %DateTime{} = time} -> %{row | time: time}
        _ -> row
      end

    case {existing_row, vulnerability_lifecycle_status(Map.get(row, :status))} do
      {nil, :open} ->
        %{
          row
          | activity_id: 1,
            activity_name: "Create",
            type_uid: @ocsf_vulnerability_finding_type_uid
        }

      {_existing, :open} ->
        %{
          row
          | activity_id: 2,
            activity_name: "Update",
            type_uid: @ocsf_vulnerability_finding_update_type_uid
        }

      {_existing, :resolved} ->
        %{
          row
          | activity_id: 3,
            activity_name: "Close",
            type_uid: @ocsf_vulnerability_finding_close_type_uid
        }

      _ ->
        row
    end
  end

  defp vulnerability_lifecycle_status(status) when is_binary(status) do
    case normalize_event_type(status) do
      value when value in ["open", "active"] -> :open
      value when value in ["resolved", "closed", "fixed", "not_affected"] -> :resolved
      value -> value
    end
  end

  defp vulnerability_lifecycle_status(status), do: status

  defp normalize_existing_time(%DateTime{} = time), do: time

  defp normalize_existing_time(%NaiveDateTime{} = time), do: DateTime.from_naive!(time, "Etc/UTC")

  defp normalize_existing_time(time), do: time

  defp record_causal_prediction_ocsf_events([]), do: []

  defp record_causal_prediction_ocsf_events(rows) when is_list(rows) do
    {rows, existing_id_keys} = align_existing_ocsf_event_times_with_existing_ids(rows)

    rows = dedupe_rows_by_conflict_key(rows, &ocsf_event_id_key/1)

    {_count, upserted_rows} =
      BulkInsert.insert_all(table_name(), rows,
        on_conflict: {:replace, @ocsf_event_replace_fields},
        conflict_target: @ocsf_event_conflict_target,
        returning: @ocsf_event_conflict_target
      )

    upserted_keys = MapSet.new(Enum.map(upserted_rows, &ocsf_event_conflict_key/1))

    rows
    |> Enum.filter(fn row ->
      MapSet.member?(upserted_keys, ocsf_event_conflict_key(row)) and
        not MapSet.member?(existing_id_keys, ocsf_event_id_key(row))
    end)
    |> dedupe_rows_by_conflict_key(&ocsf_event_conflict_key/1)
  end

  @doc false
  def align_existing_ocsf_event_times(rows, repo \\ ServiceRadar.Repo)

  def align_existing_ocsf_event_times([], _repo), do: []

  def align_existing_ocsf_event_times(rows, repo) when is_list(rows) do
    {rows, _existing_id_keys} = align_existing_ocsf_event_times_with_existing_ids(rows, repo)
    rows
  end

  defp align_existing_ocsf_event_times_with_existing_ids(rows, repo \\ ServiceRadar.Repo)

  defp align_existing_ocsf_event_times_with_existing_ids([], _repo), do: {[], MapSet.new()}

  defp align_existing_ocsf_event_times_with_existing_ids(rows, repo) when is_list(rows) do
    ids =
      rows
      |> Enum.map(&ocsf_event_id_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case existing_ocsf_event_times(repo, ids) do
      {:ok, existing_times} when map_size(existing_times) > 0 ->
        aligned_rows =
          Enum.map(rows, fn row ->
            case Map.get(existing_times, ocsf_event_id_key(row)) do
              %DateTime{} = existing_time -> %{row | time: existing_time}
              _ -> row
            end
          end)

        {aligned_rows, MapSet.new(Map.keys(existing_times))}

      _ ->
        {rows, MapSet.new()}
    end
  end

  defp existing_ocsf_event_times(_repo, []), do: {:ok, %{}}

  defp existing_ocsf_event_times(repo, ids) when is_list(ids) do
    # `ids` arrive as canonical UUID strings (via `uuid_conflict_value/1`), but
    # Postgrex encodes a `uuid[]` bind as 16-byte binaries, so dump them back to
    # binary before the query — otherwise the bind fails with an EncodeError.
    binary_ids = ids |> Enum.map(&uuid_to_binary/1) |> Enum.reject(&is_nil/1)

    if binary_ids == [] do
      {:ok, %{}}
    else
      sql = """
      SELECT id::text, min(time)
      FROM platform.ocsf_events
      WHERE id = ANY($1::uuid[])
      GROUP BY id
      """

      case repo.query(sql, [binary_ids]) do
        {:ok, %{rows: rows}} ->
          {:ok, Map.new(rows, &existing_ocsf_time_row/1)}

        {:error, reason} = error ->
          Logger.warning("Failed to load existing OCSF event times",
            reason: inspect(reason),
            count: length(binary_ids)
          )

          error
      end
    end
  end

  defp recordable_ocsf_row?(%{id: <<_::128>>, time: %DateTime{}}), do: true

  defp recordable_ocsf_row?(%{id: id, time: %DateTime{}}) when is_binary(id) do
    match?({:ok, _uuid}, Ecto.UUID.cast(id))
  end

  defp recordable_ocsf_row?(_row), do: false

  defp existing_ocsf_time_row([id, %DateTime{} = time]), do: {uuid_conflict_value(id), time}

  defp existing_ocsf_time_row([id, %NaiveDateTime{} = time]) do
    {uuid_conflict_value(id), DateTime.from_naive!(time, "Etc/UTC")}
  end

  defp existing_ocsf_time_row([id, time]), do: {uuid_conflict_value(id), time}

  defp ocsf_event_id_key(%{id: id}), do: uuid_conflict_value(id)
  defp ocsf_event_id_key(%{"id" => id}), do: uuid_conflict_value(id)
  defp ocsf_event_id_key(_row), do: nil

  defp ocsf_event_conflict_key(%{id: id, time: time}),
    do: {uuid_conflict_value(id), time_conflict_value(time)}

  defp ocsf_event_conflict_key(%{"id" => id, "time" => time}),
    do: {uuid_conflict_value(id), time_conflict_value(time)}

  defp ocsf_event_conflict_key(_row), do: nil

  defp uuid_conflict_value(<<_::128>> = id) do
    case Ecto.UUID.load(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp uuid_conflict_value(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp uuid_conflict_value(id), do: id

  # Inverse of `uuid_conflict_value/1` for query binds: canonical UUID string -> 16-byte binary.
  defp uuid_to_binary(<<_::128>> = id), do: id

  defp uuid_to_binary(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, binary} -> binary
      :error -> nil
    end
  end

  defp uuid_to_binary(_), do: nil

  defp time_conflict_value(%DateTime{} = time), do: DateTime.to_unix(time, :microsecond)

  defp time_conflict_value(%NaiveDateTime{} = time) do
    time
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp time_conflict_value(time), do: time

  defp dedupe_rows_by_conflict_key(rows, key_fun)
       when is_list(rows) and is_function(key_fun, 1) do
    {latest_by_key, ordered_keys} =
      Enum.reduce(rows, {%{}, []}, fn row, {acc, keys} ->
        key = key_fun.(row)

        keys =
          if Map.has_key?(acc, key) do
            keys
          else
            [key | keys]
          end

        # Preserve first-seen key order but keep the latest row value for that DB
        # identity; the conflict key is the uniqueness contract enforced below.
        {Map.put(acc, key, row), keys}
      end)

    ordered_keys
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(latest_by_key, &1))
  end

  defp dispatch_northbound_inventory_transitions(ocsf_rows) when is_list(ocsf_rows) do
    ocsf_rows
    |> Enum.filter(&inventory_vulnerability_lifecycle_row?/1)
    |> Enum.each(&dispatch_northbound_inventory_transition/1)
  end

  defp dispatch_northbound_inventory_transition(row) do
    event = alert_evaluation_row(row)

    case northbound_event_handler_runner().handle_event(event) do
      {:ok, _results} ->
        :ok

      result ->
        Logger.warning("Failed to run northbound event handlers for inventory transition",
          event_id: Map.get(event, :id),
          reason: inspect(result)
        )
    end
  rescue
    exception ->
      Logger.warning("Failed to run northbound event handlers for inventory transition",
        event_id: ocsf_event_id_key(row),
        reason: Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning("Failed to run northbound event handlers for inventory transition",
        event_id: ocsf_event_id_key(row),
        reason: Exception.format(kind, reason, __STACKTRACE__)
      )

      :ok
  end

  defp northbound_event_handler_runner do
    Application.get_env(
      :serviceradar_core,
      :northbound_event_handler_runner,
      EventHandlerRunner
    )
  end

  defp enqueue_alert_evaluation(_ocsf_rows, inserted_count)
       when not is_integer(inserted_count) or inserted_count <= 0,
       do: :ok

  defp enqueue_alert_evaluation(ocsf_rows, _inserted_count) when is_list(ocsf_rows) do
    ocsf_rows
    |> alert_evaluation_rows()
    |> alert_evaluation_queue().enqueue_events()
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Causal signal alert evaluation enqueue failed",
          reason: inspect(reason)
        )
    end
  end

  defp alert_evaluation_event_row?(row),
    do: inventory_event_row?(row) or causal_prediction_row?(row)

  defp inventory_event_row?(%{metadata: %{"signal_type" => "inventory"}}), do: true
  defp inventory_event_row?(%{unmapped: %{"signal_type" => "inventory"}}), do: true
  defp inventory_event_row?(_row), do: false

  defp ash_recorded_row?(row),
    do: inventory_vulnerability_finding_row?(row) or causal_prediction_row?(row)

  defp inventory_vulnerability_finding_row?(
         %{class_uid: @ocsf_vulnerability_finding_class_uid} = row
       ) do
    inventory_event_row?(row)
  end

  defp inventory_vulnerability_finding_row?(_row), do: false

  defp inventory_vulnerability_lifecycle_row?(row) do
    inventory_vulnerability_finding_row?(row) and
      row_value(row, "event_type") == "vulnerability_assessment"
  end

  defp causal_prediction_row?(%{class_uid: @ocsf_detection_finding_class_uid} = row) do
    signal_type = row_value(row, "signal_type")
    event_type = row_value(row, "event_type")

    signal_type == "prediction" and
      event_type in ["anomaly", "anomaly_detection", "capacity_forecast"]
  end

  defp causal_prediction_row?(_row), do: false

  defp row_value(row, key) when is_map(row) and is_binary(key) do
    metadata = Map.get(row, :metadata) || Map.get(row, "metadata") || %{}
    unmapped = Map.get(row, :unmapped) || Map.get(row, "unmapped") || %{}

    Map.get(metadata, key) || Map.get(unmapped, key)
  end

  defp alert_evaluation_row(%{id: <<_::128>> = id} = row) do
    case_result =
      case Ecto.UUID.load(id) do
        {:ok, uuid} -> %{row | id: uuid}
        :error -> row
      end

    canonicalize_alert_evaluation_row(case_result)
  end

  defp alert_evaluation_row(%{id: id} = row) when is_binary(id) do
    case_result =
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> %{row | id: uuid}
        :error -> row
      end

    canonicalize_alert_evaluation_row(case_result)
  end

  defp alert_evaluation_row(row), do: canonicalize_alert_evaluation_row(row)

  defp canonicalize_alert_evaluation_row(
         %{class_uid: @ocsf_detection_finding_class_uid, unmapped: unmapped} = row
       )
       when is_map(unmapped) do
    case {row_value(row, "signal_type"), row_value(row, "event_type")} do
      {"prediction", event_type} when event_type in ["anomaly", "anomaly_detection"] ->
        %{
          row
          | unmapped:
              Map.merge(unmapped, %{"signal_type" => "prediction", "event_type" => event_type})
        }

      {"prediction", "capacity_forecast"} ->
        %{
          row
          | unmapped:
              Map.merge(unmapped, %{
                "signal_type" => "prediction",
                "event_type" => "capacity_forecast"
              })
        }

      _ ->
        row
    end
  end

  defp canonicalize_alert_evaluation_row(row), do: row

  defp alert_evaluation_queue do
    Application.get_env(
      :serviceradar_core,
      :stateful_alert_evaluation_queue,
      StatefulAlertEvaluationQueue
    )
  end

  # Out-of-band, report-only anomaly disposition (OpenSpec 1.11). After the class-2004
  # anomaly findings are persisted, fire-and-forget each to AnomalyDispositionReporter,
  # which drives AnomalyDisposition.report_finding/2 OFF the stateful-alert hot path.
  # Telemetry-only: it never mutates an alert and never blocks ingest. Wrapped so a
  # mapping defect can never fail the batch insert.
  defp report_anomaly_dispositions(rows) when is_list(rows) do
    Enum.each(rows, fn row ->
      with true <- anomaly_disposition_row?(row),
           %{} = finding <- anomaly_disposition_finding(row) do
        AnomalyDispositionReporter.report(finding)
      else
        _ -> :ok
      end
    end)

    :ok
  rescue
    error ->
      Logger.warning("anomaly disposition dispatch failed: #{inspect(error)}")
      :ok
  end

  # class-2004 anomaly findings only (NOT capacity_forecast, which carries no spike peak
  # and would only ever `:ignore` in the disposition).
  defp anomaly_disposition_row?(%{class_uid: @ocsf_detection_finding_class_uid} = row) do
    row_value(row, "signal_type") == "prediction" and
      row_value(row, "event_type") in ["anomaly", "anomaly_detection"]
  end

  defp anomaly_disposition_row?(_row), do: false

  # Map a persisted class-2004 anomaly OCSF row to the AnomalyDisposition.report_finding/2
  # shape. The canonical source_identity comes from metadata.service_radar (device_id is
  # the re-keyed canonical uid), and the FORWARDED edge spike peak from
  # finding_info.dimensions (episode_peak_value/episode_peak_at_unix_nano, emitted by the
  # anomaly add-on — see rust/anomaly-addon verdict.rs). Returns nil when the canonical id
  # or the forwarded peak is absent (report_finding/2 would `:ignore` it anyway).
  @doc false
  def anomaly_disposition_finding(row) do
    metadata = Map.get(row, :metadata) || Map.get(row, "metadata") || %{}
    service_radar = Map.get(metadata, "service_radar") || %{}
    dimensions = get_in(metadata, ["finding_info", "dimensions"]) || %{}

    device_id = service_radar["device_id"]
    peak_value = dimensions["episode_peak_value"]
    peak_at = dimensions["episode_peak_at_unix_nano"]

    if is_binary(device_id) and not is_nil(peak_value) and not is_nil(peak_at) do
      source_identity =
        %{
          "device_id" => device_id,
          "metric_class" => service_radar["metric_class"],
          "metric_name" => service_radar["metric_name"],
          "if_index" => service_radar["if_index"],
          "target_device_ip" => dimensions["target_device_ip"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      %{
        source_identity: source_identity,
        episode_peak_value: peak_value,
        episode_peak_at_unix_nano: peak_at
      }
    end
  end

  defp persist_to_ocsf?(%{normalized: normalized}) when is_map(normalized) do
    signal_type = normalized["signal_type"]
    event_type = normalized["event_type"]
    severity_id = normalized["severity_id"] || 0

    cond do
      signal_type != "bmp" ->
        true

      event_type in ["peer_up", "peer_down"] ->
        true

      severity_id >= bmp_ocsf_min_severity() ->
        true

      true ->
        false
    end
  end

  defp persist_to_ocsf?(_), do: false

  defp bmp_ocsf_min_severity do
    BmpSettingsRuntime.bmp_ocsf_min_severity()
  end

  defp build_routing_event_row(%{normalized: normalized, payload: payload, raw_data: raw_data}) do
    correlation = normalized["routing_correlation"] || %{}
    source_identity = normalized["source_identity"] || %{}

    %{
      id: Ecto.UUID.dump!(normalized["event_identity"]),
      time: normalized["event_time"],
      event_type: normalized["event_type"] || "unknown",
      severity_id: normalized["severity_id"],
      router_id: merged_identity(correlation, source_identity, "router_id"),
      router_ip: merged_identity(correlation, source_identity, "router_ip"),
      peer_ip: merged_identity(correlation, source_identity, "peer_ip"),
      peer_asn: correlation["peer_asn"],
      local_asn: correlation["local_asn"],
      prefix: correlation["prefix"],
      message: routing_message(payload, normalized),
      metadata: normalized,
      raw_data: normalize_raw_data(raw_data),
      created_at: DateTime.utc_now()
    }
  end

  defp build_routing_event_row(_), do: nil

  defp merged_identity(correlation, source_identity, key) do
    correlation[key] || source_identity[key]
  end

  defp routing_message(payload, normalized) do
    payload["message"] || payload["description"] ||
      "#{normalized["signal_type"] || "bmp"} routing signal"
  end

  defp normalize_payload(payload, metadata, raw_data) when is_map(payload) do
    subject = metadata[:subject] || ""

    if arancini_subject?(subject) and not valid_arancini_payload?(payload) do
      {:error, :invalid_arancini_payload}
    else
      signal_type = infer_signal_type(subject, payload)
      event_type = infer_event_type(subject, payload)

      severity_id =
        cond do
          hostile_ioc_exposure_signal?(signal_type, event_type, payload) ->
            5

          inventory_vulnerability_signal?(signal_type, event_type, payload) ->
            cvss_severity_id(payload) || normalize_severity(payload)

          true ->
            normalize_severity(payload)
        end

      grouped_contexts =
        payload
        |> grouped_contexts()
        |> maybe_add_inventory_vulnerability_contexts(signal_type, event_type, payload)

      routing_correlation = routing_correlation(payload)

      domains =
        payload
        |> signal_domains(signal_type)
        |> maybe_inventory_vulnerability_domains(signal_type, event_type, payload)
        |> maybe_hostile_ioc_exposure_domains(signal_type, event_type, payload)

      {primary_domain, precedence_rank} = primary_domain(domains)
      truncated_contexts = Enum.take(grouped_contexts, @max_grouped_contexts)
      contexts_truncated = length(grouped_contexts) > length(truncated_contexts)

      event_time =
        payload["timestamp"] ||
          payload["time"] ||
          payload["event_time"] ||
          payload["time_bmp_header_ns"] ||
          payload["time_received_ns"] ||
          metadata[:received_at]

      envelope = %{
        "schema_version" => @schema_version,
        "signal_type" => signal_type,
        "event_type" => event_type,
        "severity_id" => severity_id,
        "source" => normalize_source(payload, subject),
        "source_identity" => source_identity(payload),
        "event_identity" => stable_event_identity(subject, payload, raw_data),
        "event_time" => normalize_time(event_time, subject),
        "routing_correlation" => routing_correlation,
        "grouped_contexts" => truncated_contexts,
        "signal_domains" => domains,
        "primary_domain" => primary_domain,
        "explainability" => %{
          "source_signal_refs" => source_signal_refs(payload),
          "context_ids" => Enum.map(truncated_contexts, & &1["id"]),
          "routing_topology_keys" => routing_correlation["topology_keys"],
          "primary_domain" => primary_domain,
          "precedence_rank" => precedence_rank
        },
        "guardrails" => %{
          "max_grouped_contexts" => @max_grouped_contexts,
          "contexts_truncated" => contexts_truncated,
          "input_context_count" => length(grouped_contexts),
          "applied_context_count" => length(truncated_contexts)
        }
      }

      {:ok, envelope}
    end
  end

  defp normalize_payload(_, _, _), do: {:error, :invalid_payload}

  defp arancini_subject?(subject) when is_binary(subject),
    do: subject == "arancini.updates" or String.starts_with?(subject, "arancini.updates.")

  defp arancini_subject?(_), do: false

  defp bmp_subject?(subject) when is_binary(subject),
    do: String.starts_with?(subject, "bmp.events.") or arancini_subject?(subject)

  defp bmp_subject?(_), do: false

  # The migration repairs existing routing projections, but the Helm migration
  # hook runs before the BMP collector rollout. Keep this projection-side guard
  # until every collector is known to publish canonical IPv4 strings. `raw_data`
  # still receives the original producer bytes for replay and forensics.
  defp canonicalize_bmp_projection_payload(payload, subject) when is_map(payload) do
    if infer_signal_type(subject, payload) == "bmp" do
      payload
      |> canonicalize_bmp_ip_fields(@bmp_projection_ip_fields)
      |> canonicalize_bmp_attrs()
    else
      payload
    end
  end

  defp canonicalize_bmp_projection_payload(payload, _subject), do: payload

  defp canonicalize_bmp_attrs(%{"attrs" => attrs} = payload) when is_map(attrs) do
    Map.put(payload, "attrs", canonicalize_bmp_ip_fields(attrs, ["next_hop"]))
  end

  defp canonicalize_bmp_attrs(payload), do: payload

  defp canonicalize_bmp_ip_fields(payload, fields) do
    Enum.reduce(fields, payload, fn field, projected ->
      case Map.fetch(projected, field) do
        {:ok, value} -> Map.put(projected, field, canonical_bmp_ip(value))
        :error -> projected
      end
    end)
  end

  defp canonical_bmp_ip(value) when is_binary(value) do
    if Regex.match?(@bmp_mapped_ipv4_pattern, value) do
      {address, suffix} = split_bmp_ip_suffix(value)

      case :inet.parse_address(String.to_charlist(address)) do
        {:ok, {0, 0, 0, 0, 0, 65_535, high, low}} ->
          "#{div(high, 256)}.#{rem(high, 256)}.#{div(low, 256)}.#{rem(low, 256)}#{suffix}"

        _ ->
          value
      end
    else
      value
    end
  end

  defp canonical_bmp_ip(value), do: value

  defp split_bmp_ip_suffix(value) do
    case String.split(value, "/", parts: 2) do
      [address] -> {address, ""}
      [address, prefix_len] -> {address, "/#{prefix_len}"}
    end
  end

  defp valid_arancini_payload?(payload) when is_map(payload) do
    required_string_keys_present? =
      Enum.all?(["router_addr", "peer_addr", "prefix_addr"], fn key ->
        payload[key] |> normalize_optional_string() |> is_binary()
      end)

    required_numeric_keys_present? =
      is_integer(normalize_int(payload["peer_asn"])) and
        is_integer(normalize_int(payload["prefix_len"]))

    required_boolean_keys_present? = is_boolean(payload["announced"])

    required_string_keys_present? and required_numeric_keys_present? and
      required_boolean_keys_present?
  end

  defp infer_event_type(subject, payload) when is_binary(subject) and is_map(payload) do
    candidate =
      payload["event_type"] ||
        payload["eventType"] ||
        arancini_event_type(payload) ||
        subject_to_event_type(subject)

    normalize_event_type(candidate)
  end

  defp infer_event_type(subject, _payload) when is_binary(subject) do
    subject_to_event_type(subject)
  end

  defp infer_event_type(_, _), do: "unknown"

  defp subject_to_event_type(subject) do
    case String.split(subject, ".", trim: true) do
      ["bmp", "events", suffix | _] -> normalize_event_type(suffix)
      _ -> "unknown"
    end
  end

  defp arancini_event_type(payload) when is_map(payload) do
    cond do
      is_boolean(payload["announced"]) and payload["announced"] ->
        "route_update"

      is_boolean(payload["announced"]) and not payload["announced"] ->
        "route_withdraw"

      true ->
        nil
    end
  end

  defp normalize_event_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> "unknown"
      normalized -> normalized
    end
  end

  defp normalize_event_type(_), do: "unknown"

  defp build_ocsf_event_row(normalized, payload, raw_data, metadata) do
    cond do
      inventory_vulnerability_signal?(normalized, payload) ->
        build_inventory_vulnerability_finding_row(normalized, payload, raw_data, metadata)

      hostile_ioc_exposure_signal?(normalized, payload) ->
        build_hostile_ioc_exposure_finding_row(normalized, payload, raw_data, metadata)

      anomaly_detection_signal?(normalized, payload) ->
        build_anomaly_detection_finding_row(normalized, payload, raw_data, metadata)

      true ->
        build_causal_signal_event_row(normalized, payload, raw_data, metadata)
    end
  end

  defp build_inventory_vulnerability_finding_row(normalized, payload, raw_data, metadata) do
    with true <- inventory_assessment_finding_allowed?(payload),
         device_uid when is_binary(device_uid) <- payload_device_uid(payload) do
      severity_id = normalized["severity_id"] || 0
      {activity_id, activity_name, type_uid} = inventory_vulnerability_activity(payload)

      %{
        id: Ecto.UUID.dump!(normalized["event_identity"]),
        time: normalized["event_time"],
        class_uid: @ocsf_vulnerability_finding_class_uid,
        category_uid: @ocsf_findings_category_uid,
        type_uid: type_uid,
        activity_id: activity_id,
        activity_name: activity_name,
        severity_id: severity_id,
        severity: severity_name(severity_id),
        message: inventory_vulnerability_message(payload),
        status_id: nil,
        status: payload["status"] || payload["finding_status"] || "open",
        status_code: nil,
        status_detail: payload["status_detail"] || payload["transition_reason"],
        metadata: inventory_vulnerability_metadata(normalized, payload),
        observables: [],
        trace_id: nil,
        span_id: nil,
        actor: %{},
        device: %{"uid" => device_uid},
        src_endpoint: %{},
        dst_endpoint: %{},
        log_name: metadata[:subject],
        log_provider: payload["provider"] || payload["source"] || "endpoint_inventory",
        log_level: payload["level"],
        log_version: payload["version"] || @schema_version,
        unmapped: payload,
        raw_data: normalize_raw_data(raw_data),
        created_at: DateTime.utc_now()
      }
    else
      _ -> nil
    end
  end

  defp inventory_assessment_finding_allowed?(payload) do
    if normalize_event_type(payload["event_type"] || payload["eventType"]) ==
         "vulnerability_assessment" do
      case normalize_event_type(payload["status"] || payload["finding_status"]) do
        status when status in ["resolved", "closed"] ->
          true

        status when status in ["open", "active"] ->
          EndpointVulnerabilityAssessment.actionable?(%{
            status: payload["assessment_status"],
            assessment: payload["assessment"],
            disposition: payload["disposition"]
          })

        _ ->
          false
      end
    else
      true
    end
  end

  defp inventory_vulnerability_activity(payload) do
    case normalize_event_type(payload["status"] || payload["finding_status"]) do
      status when status in ["resolved", "closed"] ->
        {3, "Close", @ocsf_vulnerability_finding_close_type_uid}

      _ ->
        {@ocsf_create_activity_id, "Create", @ocsf_vulnerability_finding_type_uid}
    end
  end

  defp build_anomaly_detection_finding_row(normalized, payload, raw_data, metadata) do
    # A. Consumer backstop gate (primary, producer-version-independent). A
    # prediction-anomaly breadcrumb is surfaced as an OCSF Detection Finding ONLY
    # once the detector has CONFIRMED the anomaly. An UNCONFIRMED pending breadcrumb
    # (detector_state "pending_anomaly", a lifecycle state outside the confirmed/open
    # set, or fewer consecutive breaching slots than the producer's confirm_slots) is
    # withheld so a stale add-on that emits pre-confirmation cannot raise a
    # High-severity event. Mirrors the seasonal worker `surfaces?` contract
    # (observability/seasonal_disposition/worker.ex). Capacity forecasts and
    # anomaly_clear resolutions are never gated here (see anomaly_finding_unconfirmed?/2).
    if anomaly_finding_unconfirmed?(normalized, payload) do
      anomaly_detection_unconfirmed_telemetry(payload)
      nil
    else
      build_confirmed_anomaly_detection_finding_row(normalized, payload, raw_data, metadata)
    end
  end

  defp build_confirmed_anomaly_detection_finding_row(normalized, payload, _raw_data, metadata) do
    # B(i). Confirmation-aware severity (defense-in-depth behind the A gate): a
    # pending breadcrumb that ever reaches row-build is clamped to Informational/Low,
    # regardless of the producer's severity_id.
    severity_id = anomaly_detection_severity_id(normalized, payload)
    # Resolve the canonical device uid once and thread it through every consumer
    # (device.uid, metadata.service_radar.device_uid, finding_info dimensions, and
    # the deterministic finding_uid) so the re-key stays coherent and we pay at
    # most one (cache-backed) correlation lookup per row.
    case anomaly_detection_device_uid(payload) do
      {:withhold, reason} ->
        anomaly_detection_withheld_telemetry(payload, reason)
        nil

      device_uid ->
        %{
          id: Ecto.UUID.dump!(normalized["event_identity"]),
          time: normalized["event_time"],
          class_uid: @ocsf_detection_finding_class_uid,
          category_uid: @ocsf_findings_category_uid,
          type_uid: @ocsf_detection_finding_type_uid,
          activity_id: @ocsf_create_activity_id,
          activity_name: "Create",
          severity_id: severity_id,
          severity: severity_name(severity_id),
          message: anomaly_detection_message(payload),
          status_id: nil,
          status: payload["status"] || payload["finding_status"] || "open",
          status_code: nil,
          status_detail: payload["status_detail"],
          metadata: anomaly_detection_metadata(normalized, payload, device_uid),
          observables: [],
          trace_id: nil,
          span_id: nil,
          actor: %{},
          device: anomaly_detection_device(device_uid),
          src_endpoint: %{},
          dst_endpoint: %{},
          log_name: metadata[:subject],
          log_provider: payload["provider"] || payload["source"] || "anomaly_detection",
          log_level: payload["level"],
          log_version: payload["version"] || @schema_version,
          unmapped: payload,
          raw_data: nil,
          created_at: DateTime.utc_now()
        }
    end
  end

  defp build_causal_signal_event_row(normalized, payload, raw_data, metadata) do
    severity_id = normalized["severity_id"]
    signal_type = normalized["signal_type"]
    event_identity = normalized["event_identity"]

    %{
      id: Ecto.UUID.dump!(event_identity),
      time: normalized["event_time"],
      class_uid: 1008,
      category_uid: 1,
      type_uid: type_uid_for(signal_type),
      activity_id: 1,
      activity_name: "Causal Signal",
      severity_id: severity_id,
      severity: severity_name(severity_id),
      message: payload["message"] || payload["description"] || "#{signal_type} causal signal",
      status_id: nil,
      status: nil,
      status_code: nil,
      status_detail: nil,
      metadata: normalized,
      observables: [],
      trace_id: nil,
      span_id: nil,
      actor: %{},
      device: normalize_device(payload),
      src_endpoint: normalize_src_endpoint(payload),
      dst_endpoint: %{},
      log_name: metadata[:subject],
      log_provider: payload["provider"] || payload["source"] || "external",
      log_level: payload["level"],
      log_version: payload["version"] || @schema_version,
      unmapped: payload,
      raw_data: normalize_raw_data(raw_data),
      created_at: DateTime.utc_now()
    }
  end

  defp infer_signal_type(subject, payload) when is_map(payload) do
    subject = if is_binary(subject), do: subject, else: ""

    cond do
      is_binary(payload["signal_type"]) -> String.downcase(payload["signal_type"])
      bmp_subject?(subject) -> "bmp"
      String.starts_with?(subject, "siem.events.") -> "siem"
      true -> "unknown"
    end
  end

  defp infer_signal_type(_subject, _payload), do: "unknown"

  defp normalize_source(payload, subject) do
    %{
      "subject" => subject,
      "collector" => payload["collector"] || payload["source_collector"],
      "system" =>
        payload["source"] ||
          payload["provider"] ||
          if(arancini_subject?(subject), do: "arancini", else: "external")
    }
  end

  defp source_identity(payload) do
    %{
      "device_uid" =>
        first_non_blank([
          payload["device_id"],
          payload["deviceId"],
          payload["router_id"],
          payload["routerId"]
        ]),
      "router_id" => first_non_blank([payload["router_id"], payload["routerId"]]),
      "router_ip" =>
        first_non_blank([
          payload["router_ip"],
          payload["routerIp"],
          payload["router_addr"],
          payload["device_ip"],
          payload["source_ip"]
        ]),
      "peer_ip" =>
        first_non_blank([
          payload["peer_ip"],
          payload["peerIp"],
          payload["peer_addr"],
          payload["src_ip"]
        ])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp routing_correlation(payload) do
    router_id =
      first_non_blank([
        payload["router_id"],
        payload["routerId"],
        payload["router_addr"],
        payload["device_id"],
        payload["deviceId"]
      ])

    router_ip =
      first_non_blank([
        payload["router_ip"],
        payload["routerIp"],
        payload["router_addr"],
        payload["device_ip"],
        payload["source_ip"]
      ])

    peer_ip =
      first_non_blank([
        payload["peer_ip"],
        payload["peerIp"],
        payload["peer_addr"],
        payload["src_ip"]
      ])

    peer_asn = normalize_int(payload["peer_asn"] || payload["peerAsn"])

    local_asn =
      normalize_int(
        payload["local_asn"] || payload["localAsn"] || payload["local_as"] || payload["asn"]
      )

    vrf = first_non_blank([payload["vrf"], payload["routing_instance"]])

    prefix =
      first_non_blank([
        payload["prefix"],
        payload["nlri"],
        payload["announced_prefix"],
        arancini_prefix(payload)
      ])

    topology_keys =
      [router_id, router_ip, peer_ip, prefix]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      "router_id" => router_id,
      "router_ip" => router_ip,
      "peer_ip" => peer_ip,
      "peer_asn" => peer_asn,
      "local_asn" => local_asn,
      "vrf" => vrf,
      "prefix" => prefix,
      "topology_keys" => topology_keys
    }
  end

  defp grouped_contexts(payload) when is_map(payload) do
    security_zones =
      payload
      |> list_or_scalar(["security_zones", "security_zone"])
      |> Enum.map(&build_context("security_zone", &1))

    bgp_prefix_groups =
      payload
      |> list_or_scalar(["bgp_prefix_groups", "bgp_prefix_group"])
      |> Enum.map(&build_context("bgp_prefix_group", &1))

    (security_zones ++ bgp_prefix_groups)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1["type"], &1["id"]})
  end

  defp list_or_scalar(payload, [list_key, scalar_key]) do
    cond do
      is_list(payload[list_key]) ->
        payload[list_key]

      is_binary(payload[scalar_key]) ->
        [payload[scalar_key]]

      true ->
        []
    end
  end

  defp build_context(type, id) when is_binary(id) do
    normalized = String.trim(id)
    if normalized == "", do: nil, else: %{"type" => type, "id" => normalized}
  end

  defp build_context(_type, _id), do: nil

  defp signal_domains(payload, signal_type) do
    case_result =
      case payload["signal_domains"] do
        values when is_list(values) ->
          Enum.map(values, &normalize_domain/1)

        _ ->
          [normalize_domain(payload["signal_domain"] || signal_type)]
      end

    normalized =
      case_result
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if normalized == [], do: ["unknown"], else: normalized
  end

  defp maybe_inventory_vulnerability_domains(domains, signal_type, event_type, payload) do
    if inventory_vulnerability_signal?(signal_type, event_type, payload) do
      (["security", "inventory"] ++ domains)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    else
      domains
    end
  end

  defp maybe_hostile_ioc_exposure_domains(domains, signal_type, event_type, payload) do
    if hostile_ioc_exposure_signal?(signal_type, event_type, payload) do
      (["security", "inventory"] ++ domains)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    else
      domains
    end
  end

  defp normalize_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "security" -> "security"
      "routing" -> "routing"
      "health" -> "health"
      "inventory" -> "inventory"
      "bmp" -> "routing"
      "siem" -> "security"
      "unknown" -> "unknown"
      "" -> nil
      _ -> "unknown"
    end
  end

  defp normalize_domain(_), do: nil

  defp primary_domain(domains) when is_list(domains) do
    domains
    |> Enum.map(&{&1, domain_rank(&1)})
    |> Enum.max_by(fn {domain, rank} -> {rank, domain} end, fn -> {"unknown", 0} end)
  end

  defp domain_rank("security"), do: 3
  defp domain_rank("routing"), do: 2
  defp domain_rank("inventory"), do: 2
  defp domain_rank("health"), do: 1
  defp domain_rank(_), do: 0

  defp source_signal_refs(payload) when is_map(payload) do
    [
      payload["event_id"],
      payload["id"],
      payload["eventId"],
      payload["alert_id"],
      payload["arancini_message_id"],
      payload["bmp_message_id"],
      payload["message_id"]
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_add_inventory_vulnerability_contexts(contexts, signal_type, event_type, payload) do
    if inventory_vulnerability_signal?(signal_type, event_type, payload) do
      (contexts ++ inventory_vulnerability_contexts(payload))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&{&1["type"], &1["id"]})
    else
      contexts
    end
  end

  defp normalize_time(value, subject)

  defp normalize_time(%DateTime{} = dt, _subject), do: dt

  defp normalize_time(value, subject) when is_integer(value) do
    value
    |> unix_time_unit()
    |> then(&DateTime.from_unix(value, &1))
    |> case do
      {:ok, dt} -> dt
      _ -> fallback_ingest_time(subject, :invalid_unix_time)
    end
  rescue
    _ -> fallback_ingest_time(subject, :invalid_unix_time)
  end

  defp normalize_time(value, subject) when is_float(value) do
    value
    |> trunc()
    |> normalize_time(subject)
  end

  defp normalize_time(value, subject) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {int, ""} ->
        normalize_time(int, subject)

      _ ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, dt, _} -> dt
          _ -> fallback_ingest_time(subject, :malformed_timestamp)
        end
    end
  rescue
    _ -> fallback_ingest_time(subject, :malformed_timestamp)
  end

  defp normalize_time(value, subject) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _} -> dt
      _ -> fallback_ingest_time(subject, :malformed_timestamp)
    end
  rescue
    _ -> fallback_ingest_time(subject, :malformed_timestamp)
  end

  defp fallback_ingest_time(subject, reason) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :causal_signals, :timestamp_fallback],
      %{count: 1},
      %{
        subject_class: EventWriterTelemetry.subject_class(subject),
        reason: reason
      }
    )

    DateTime.utc_now()
  end

  defp unix_time_unit(value) do
    value
    |> abs()
    |> case do
      unix when unix >= 100_000_000_000_000_000 -> :nanosecond
      unix when unix >= 100_000_000_000_000 -> :microsecond
      unix when unix >= 100_000_000_000 -> :millisecond
      _ -> :second
    end
  end

  defp normalize_severity(payload) do
    severity_id =
      cond do
        is_integer(payload["severity_id"]) -> clamp_severity(payload["severity_id"])
        is_integer(payload["severity"]) -> clamp_severity(payload["severity"])
        is_binary(payload["severity"]) -> severity_from_string(payload["severity"])
        true -> 3
      end

    anomaly_severity_backstop(payload, severity_id)
  end

  defp anomaly_severity_backstop(payload, severity_id) when is_map(payload) do
    severity_id
    |> maybe_cap_pending_anomaly_severity(payload)
    |> maybe_cap_edge_drift_severity(payload)
  end

  defp anomaly_severity_backstop(_payload, severity_id), do: severity_id

  defp maybe_cap_pending_anomaly_severity(severity_id, payload) do
    if anomaly_pending_reason?(payload), do: min(severity_id, 2), else: severity_id
  end

  defp maybe_cap_edge_drift_severity(severity_id, payload) do
    if anomaly_edge_drift?(payload), do: min(severity_id, 4), else: severity_id
  end

  defp clamp_severity(value) when value < 0, do: 0
  defp clamp_severity(value) when value > 6, do: 6
  defp clamp_severity(value), do: value

  @severity_map %{
    "unknown" => 0,
    "informational" => 1,
    "info" => 1,
    "low" => 2,
    "medium" => 3,
    "high" => 4,
    "critical" => 5,
    "fatal" => 6
  }

  defp severity_from_string(value) do
    Map.get(@severity_map, String.downcase(value), 3)
  end

  defp severity_name(0), do: "Unknown"
  defp severity_name(1), do: "Informational"
  defp severity_name(2), do: "Low"
  defp severity_name(3), do: "Medium"
  defp severity_name(4), do: "High"
  defp severity_name(5), do: "Critical"
  defp severity_name(6), do: "Fatal"
  defp severity_name(_), do: "Unknown"

  defp cvss_severity_id(payload) when is_map(payload) do
    payload
    |> cvss_score()
    |> case do
      score when is_number(score) and score >= 9.0 -> 5
      score when is_number(score) and score >= 7.0 -> 4
      score when is_number(score) and score >= 4.0 -> 3
      score when is_number(score) and score > 0.0 -> 2
      score when is_number(score) -> 0
      _ -> nil
    end
  end

  defp cvss_score(payload) when is_map(payload) do
    [
      payload["cvss_score"],
      payload["cvssScore"],
      payload["cvss"],
      payload["cvss_base_score"],
      payload["cvssBaseScore"],
      get_in(payload, ["vulnerability", "cvss_score"]),
      get_in(payload, ["vulnerability", "cvssScore"]),
      get_in(payload, ["advisory", "cvss_score"]),
      get_in(payload, ["advisory", "cvssScore"])
    ]
    |> first_present()
    |> normalize_float()
  end

  defp type_uid_for("bmp"), do: 100_811
  defp type_uid_for("siem"), do: 100_812
  defp type_uid_for("inventory"), do: 100_813
  defp type_uid_for(_), do: 100_810

  defp normalize_device(payload) do
    device_id =
      payload["device_id"] || payload["deviceId"] || payload["router_id"] ||
        payload["router_addr"]

    if is_binary(device_id) and device_id != "" do
      %{"uid" => device_id}
    else
      %{}
    end
  end

  defp inventory_vulnerability_signal?(normalized, payload) when is_map(normalized) do
    inventory_vulnerability_signal?(
      normalized["signal_type"],
      normalized["event_type"],
      payload
    )
  end

  defp inventory_vulnerability_signal?(signal_type, event_type, payload) when is_map(payload) do
    normalized_event_type = normalize_event_type(event_type)
    finding_type = normalize_event_type(payload["finding_type"] || payload["findingType"])

    signal_type == "inventory" and
      (payload["class_uid"] == @ocsf_vulnerability_finding_class_uid or
         normalized_event_type in [
           "vulnerability",
           "vulnerability_match",
           "vulnerability_found",
           "vulnerability_finding",
           "vuln_match"
         ] or
         finding_type in ["vulnerability", "vulnerability_match", "vuln_match"])
  end

  defp inventory_vulnerability_signal?(_, _, _), do: false

  defp hostile_ioc_exposure_signal?(normalized, payload) when is_map(normalized) do
    hostile_ioc_exposure_signal?(
      normalized["signal_type"],
      normalized["event_type"],
      payload
    )
  end

  defp hostile_ioc_exposure_signal?(signal_type, event_type, payload) when is_map(payload) do
    signal_type == "inventory" and
      normalize_event_type(event_type) in [
        "hostile_ioc_vulnerable_service",
        "hostile_ioc_on_vulnerable_service"
      ]
  end

  defp hostile_ioc_exposure_signal?(_, _, _), do: false

  defp build_hostile_ioc_exposure_finding_row(normalized, payload, raw_data, metadata) do
    case payload_device_uid(payload) do
      nil ->
        nil

      device_uid ->
        severity_id = normalized["severity_id"] || 5
        hostile_ip = payload["hostile_ip"] || get_in(payload, ["src_endpoint", "ip"])
        dst_ip = payload["dst_ip"] || get_in(payload, ["dst_endpoint", "ip"])
        dst_port = payload["dst_port"] || get_in(payload, ["dst_endpoint", "port"])

        %{
          id: Ecto.UUID.dump!(normalized["event_identity"]),
          time: normalized["event_time"],
          class_uid: @ocsf_detection_finding_class_uid,
          category_uid: @ocsf_findings_category_uid,
          type_uid: @ocsf_detection_finding_type_uid,
          activity_id: @ocsf_create_activity_id,
          activity_name: "Create",
          severity_id: severity_id,
          severity: severity_name(severity_id),
          message:
            payload["message"] || payload["description"] || "hostile IOC on vulnerable service",
          status_id: nil,
          status: payload["status"] || "open",
          status_code: nil,
          status_detail: payload["status_detail"],
          metadata: hostile_ioc_exposure_metadata(normalized, payload, device_uid),
          observables: [],
          trace_id: nil,
          span_id: nil,
          actor: %{},
          device: %{"uid" => device_uid},
          src_endpoint: %{"ip" => hostile_ip},
          dst_endpoint: %{"ip" => dst_ip, "port" => dst_port},
          log_name: metadata[:subject],
          log_provider: payload["provider"] || payload["source"] || "device_risk_assessment",
          log_level: payload["level"],
          log_version: payload["version"] || @schema_version,
          unmapped: payload,
          raw_data: normalize_raw_data(raw_data),
          created_at: DateTime.utc_now()
        }
    end
  end

  defp hostile_ioc_exposure_metadata(normalized, payload, device_uid) do
    normalized
    |> Map.put("primary_domain", "security")
    |> Map.put("service_radar", %{
      "source_type" => "hostile_ioc_vulnerable_service",
      "device_uid" => device_uid,
      "agent_id" => payload["agent_id"] || payload["agentId"],
      "ocsf_class" => "detection_finding"
    })
    |> Map.put("hostile_ioc_vulnerable_service", %{
      "cve" => payload["cve"] || payload["cve_id"],
      "package" => get_in(payload, ["package", "name"]) || payload["package"],
      "hostile_ip" => payload["hostile_ip"],
      "dst_port" => payload["dst_port"],
      "comm" => payload["comm"],
      "kev" => payload["kev"],
      "ioc_sources" => payload["ioc_sources"]
    })
  end

  defp anomaly_detection_signal?(normalized, payload) when is_map(normalized) do
    anomaly_detection_signal?(
      normalized["signal_type"],
      normalized["event_type"],
      payload
    )
  end

  defp anomaly_detection_signal?(signal_type, event_type, payload) when is_map(payload) do
    anomaly_shaped? = anomaly_shaped_payload?(payload, event_type)

    if legacy_anomaly_class1008_enabled?() do
      signal_type == "prediction" and anomaly_shaped?
    else
      anomaly_shaped?
    end
  end

  defp anomaly_detection_signal?(_, _, _), do: false

  defp anomaly_shaped_payload?(payload, event_type \\ nil)

  defp anomaly_shaped_payload?(payload, event_type) when is_map(payload) do
    normalized_event_type =
      normalize_event_type(event_type || payload["event_type"] || payload["eventType"])

    finding_type = normalize_event_type(payload["finding_type"] || payload["findingType"])

    payload["class_uid"] == @ocsf_detection_finding_class_uid or
      is_map(payload["anomaly"]) or
      normalized_event_type in ["anomaly", "anomaly_detection"] or
      finding_type in ["detection", "anomaly", "anomaly_detection"]
  end

  defp anomaly_shaped_payload?(_, _), do: false

  defp legacy_anomaly_class1008_enabled? do
    @legacy_anomaly_class1008_env
    |> System.get_env("")
    |> normalize_env_truthy?()
  end

  defp normalize_env_truthy?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])
  end

  defp normalize_env_truthy?(_value), do: false

  defp payload_device_uid(payload) do
    first_non_blank([
      payload["device_uid"],
      payload["deviceUid"],
      get_in(payload, ["device", "uid"])
    ])
  end

  defp inventory_vulnerability_message(payload) do
    payload["message"] || payload["description"] ||
      [
        "endpoint vulnerability finding",
        vulnerability_id(payload),
        package_context_label(payload)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(": ")
  end

  defp inventory_vulnerability_metadata(normalized, payload) do
    device_uid = payload_device_uid(payload)
    source_type = payload["provider"] || payload["source"] || "endpoint_inventory"

    normalized
    |> Map.put("primary_domain", "security")
    |> Map.put("service_radar", %{
      "source_type" => normalize_event_type(source_type),
      "addon_id" => "endpoint-inventory",
      "device_uid" => device_uid,
      "agent_id" => payload["agent_id"] || payload["agentId"],
      "source_instance" => payload["source_instance"] || payload["sourceInstance"],
      "ocsf_class" => "vulnerability_finding"
    })
    |> Map.put("vulnerability_finding", %{
      "cve" => vulnerability_id(payload),
      "cvss_score" => cvss_score(payload),
      "package" => package_context(payload),
      "assessment_ref" => payload["assessment_ref"],
      "assessment" => payload["assessment"],
      "disposition" => payload["disposition"],
      "authority" => payload["authority"],
      "freshness" => payload["freshness"],
      "transition_reason" => payload["transition_reason"]
    })
  end

  defp anomaly_detection_message(payload) do
    payload["message"] || payload["description"] ||
      [
        "anomaly detection finding",
        get_in(payload, ["anomaly", "series_key"]),
        get_in(payload, ["anomaly", "state"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(": ")
  end

  defp anomaly_detection_metadata(normalized, payload, device_uid) do
    finding_info = anomaly_detection_finding_info(payload, device_uid)
    capacity_forecast? = capacity_forecast_signal?(normalized, payload)
    source_type = if capacity_forecast?, do: "capacity_forecasting", else: "anomaly_detection"
    addon_id = if capacity_forecast?, do: "capacity-forecasting", else: "anomaly-detection"
    finding_type = if capacity_forecast?, do: "capacity_forecast", else: "anomaly"

    finding_source =
      if capacity_forecast?,
        do: "capacity_forecasting",
        else: Map.get(payload, "verdict_source", "central")

    series_key = detection_series_key(payload, capacity_forecast?, device_uid)
    metric_class = detection_metric_class(payload, capacity_forecast?)
    metric_name = anomaly_detection_metric_name(payload, metric_class)
    if_index = anomaly_detection_if_index(payload)

    normalized
    |> Map.put("signal_type", "prediction")
    |> Map.put("event_type", finding_type)
    |> Map.put("primary_domain", "health")
    |> Map.put("finding_info", finding_info)
    |> Map.put(
      "security_signal",
      %{
        "kind" => "health",
        "source" => source_type,
        "finding_uid" => finding_info["uid"],
        "device_id" => device_uid,
        "series_key" => series_key,
        "metric_class" => metric_class,
        "metric_name" => metric_name,
        "if_index" => if_index
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    )
    |> Map.put("service_radar", %{
      "source_type" => source_type,
      "addon_id" => addon_id,
      "finding_uid" => finding_info["uid"],
      "device_uid" => device_uid,
      "device_id" => device_uid,
      "series_key" => series_key,
      "metric_class" => metric_class,
      "metric_name" => metric_name,
      "if_index" => if_index,
      # verdict_source distinguishes an edge spike verdict ("edge-spike") from a
      # central one (default "central", later "central-seasonal"). SRQL/alerts
      # can filter/group on metadata.service_radar.verdict_source.
      "verdict_source" => finding_source,
      "ocsf_class" => "detection_finding"
    })
    |> Map.put(
      "detection_finding",
      %{
        "type" => finding_type,
        "source" => finding_source,
        "device_id" => device_uid,
        "series_key" => series_key,
        "metric_class" => metric_class,
        "metric_name" => metric_name,
        "if_index" => if_index,
        "state" => get_in(payload, ["anomaly", "state"]),
        "score" => get_in(payload, ["anomaly", "score"]),
        "reason" => get_in(payload, ["anomaly", "reason"]),
        "consecutive_anomalous" => get_in(payload, ["anomaly", "consecutive_anomalous"]),
        "signals" => get_in(payload, ["anomaly", "signals"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    )
  end

  defp capacity_forecast_signal?(normalized, payload) do
    event_type =
      normalized["event_type"] || payload["event_type"] || payload["eventType"] ||
        get_in(payload, ["capacity_forecast", "event_type"])

    provider = payload["provider"] || payload["source"] || payload["log_provider"]

    normalize_event_type(event_type) == "capacity_forecast" or
      normalize_event_type(provider) == "capacity_forecasting"
  end

  defp detection_series_key(payload, true) do
    get_in(payload, ["capacity_forecast", "resource_key"]) ||
      payload["resource_key"] ||
      get_in(payload, ["anomaly", "series_key"])
  end

  defp detection_series_key(payload, false, device_uid),
    do: anomaly_detection_series_key(payload, device_uid)

  defp detection_series_key(payload, capacity_forecast?, _device_uid),
    do: detection_series_key(payload, capacity_forecast?)

  defp detection_metric_class(payload, true) do
    get_in(payload, ["capacity_forecast", "metric_name"]) ||
      payload["metric_name"] ||
      get_in(payload, ["anomaly", "metric_class"])
  end

  defp detection_metric_class(payload, false), do: get_in(payload, ["anomaly", "metric_class"])

  defp anomaly_detection_finding_info(payload, device_uid) do
    existing = if is_map(payload["finding_info"]), do: payload["finding_info"], else: %{}
    series_key = anomaly_detection_series_key(payload, device_uid)
    metric_class = get_in(payload, ["anomaly", "metric_class"])
    uid = anomaly_detection_finding_uid(device_uid, series_key, metric_class)

    existing
    |> Map.put("uid", uid)
    |> Map.put("group_uid", uid)
    |> Map.put("title", anomaly_detection_title(payload, series_key, metric_class))
    |> Map.put_new("type", "ServiceRadar Anomaly")
    |> Map.put_new("type_id", 99)
    |> Map.put("source", "anomaly_detection")
    |> Map.put(
      "dimensions",
      anomaly_detection_finding_dimensions(payload, device_uid, series_key, metric_class)
    )
  end

  defp anomaly_detection_finding_dimensions(payload, device_uid, series_key, metric_class) do
    metric_name = anomaly_detection_metric_name(payload, metric_class)
    if_index = anomaly_detection_if_index(payload)

    %{
      "class_uid" => @ocsf_detection_finding_class_uid,
      "source" => "anomaly_detection",
      "device_uid" => device_uid,
      "device_id" => device_uid,
      "series_key" => series_key,
      "metric_class" => metric_class,
      "metric_name" => metric_name,
      "target_device_ip" => anomaly_detection_target_device_ip(payload),
      "if_index" => if_index,
      "interface_name" => get_in(payload, ["anomaly", "interface_name"]),
      "resource_label" => anomaly_detection_display_label(payload, series_key),
      "state" => get_in(payload, ["anomaly", "state"]),
      "subject" => get_in(payload, ["anomaly", "subject"]),
      "detector_state" => get_in(payload, ["anomaly", "detector_state"]),
      "score" => get_in(payload, ["anomaly", "score"]),
      "baseline_count" => get_in(payload, ["anomaly", "baseline_count"]),
      "consecutive_anomalous" => get_in(payload, ["anomaly", "consecutive_anomalous"]),
      "signals" => get_in(payload, ["anomaly", "signals"]),
      "sample_value" =>
        get_in(payload, ["anomaly", "sample_value"]) || get_in(payload, ["anomaly", "value"]),
      "observed_at_unix_nano" => get_in(payload, ["anomaly", "observed_at_unix_nano"]),
      "episode_started_at_unix_nano" =>
        get_in(payload, ["anomaly", "episode_started_at_unix_nano"]),
      "episode_ended_at_unix_nano" => get_in(payload, ["anomaly", "episode_ended_at_unix_nano"]),
      "episode_peak_value" => get_in(payload, ["anomaly", "episode_peak_value"]),
      "episode_peak_at_unix_nano" => get_in(payload, ["anomaly", "episode_peak_at_unix_nano"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp anomaly_detection_title(payload, series_key, metric_class) do
    metric =
      first_non_blank([
        anomaly_detection_metric_name(payload, metric_class),
        metric_class
      ]) || "metric"

    label = anomaly_detection_display_label(payload, series_key) || "series"

    "Anomaly detection: #{metric} #{label}"
  end

  defp anomaly_detection_display_label(payload, series_key) do
    first_non_blank([
      get_in(payload, ["anomaly", "resource_label"]),
      get_in(payload, ["anomaly", "label"]),
      anomaly_detection_interface_label(payload),
      readable_series_key(series_key)
    ])
  end

  defp anomaly_detection_interface_label(payload) do
    target_device_ip = anomaly_detection_target_device_ip(payload)
    if_index = anomaly_detection_if_index(payload)
    interface_name = get_in(payload, ["anomaly", "interface_name"])

    [target_device_ip, interface_name, if_index_label(if_index)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp if_index_label(nil), do: nil
  defp if_index_label(value), do: "ifIndex #{value}"

  defp anomaly_detection_metric_name(payload, fallback) do
    source_identity = get_in(payload, ["source_identity"]) || %{}

    first_non_blank([
      get_in(payload, ["anomaly", "metric_name"]),
      get_in(payload, ["anomaly", "metadata", "metric_name"]),
      source_identity["metric_name"],
      payload["metric_name"],
      fallback
    ])
  end

  defp anomaly_detection_if_index(payload) do
    source_identity = get_in(payload, ["source_identity"]) || %{}
    source_tags = source_identity["tags"] || %{}
    anomaly_tags = get_in(payload, ["anomaly", "tags"]) || %{}

    [
      get_in(payload, ["anomaly", "if_index"]),
      get_in(payload, ["anomaly", "metadata", "if_index"]),
      source_identity["if_index"],
      source_tags["if_index"],
      anomaly_tags["if_index"],
      payload["if_index"]
    ]
    |> first_present()
    |> normalize_int()
    |> positive_int()
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp readable_series_key(value) when is_binary(value) and value != "" do
    if structured_series_key?(value), do: nil, else: value
  end

  defp readable_series_key(_value), do: nil

  defp structured_series_key?(value), do: String.match?(value, @structured_series_key_pattern)

  defp anomaly_detection_finding_uid(device_uid, series_key, metric_class) do
    [
      "anomaly",
      "finding",
      "anomaly",
      @ocsf_detection_finding_class_uid,
      "anomaly_detection",
      device_uid,
      series_key,
      metric_class
    ]
    |> Enum.map_join(":", &to_string/1)
    |> deterministic_uuid()
  end

  defp anomaly_detection_series_key(payload, device_uid) do
    canonical_key =
      case canonical_anomaly_source_identity(payload, device_uid) do
        %{} = source_identity -> SeriesKey.from_source_identity(source_identity)
        _ -> nil
      end

    case canonical_key do
      key when is_binary(key) and key != "" -> key
      _ -> get_in(payload, ["anomaly", "series_key"])
    end
  end

  defp canonical_anomaly_source_identity(payload, device_uid) do
    source_identity =
      case Map.get(payload, "source_identity") do
        %{} = identity -> identity
        _ -> nil
      end

    if source_identity_with_producer_key?(source_identity) do
      source_identity
      |> put_if_missing("metric_class", get_in(payload, ["anomaly", "metric_class"]))
      |> put_if_missing("metric_name", get_in(payload, ["anomaly", "metric_name"]))
      |> put_canonical_device_id(device_uid)
    end
  end

  defp source_identity_with_producer_key?(%{"series_key" => value}) when is_binary(value) do
    String.trim(value) != ""
  end

  defp source_identity_with_producer_key?(_source_identity), do: false

  defp put_if_missing(map, _key, nil), do: map
  defp put_if_missing(map, key, value), do: Map.put_new(map, key, value)

  defp put_canonical_device_id(map, device_uid) when is_binary(device_uid) and device_uid != "" do
    Map.put(map, "device_id", device_uid)
  end

  defp put_canonical_device_id(map, _device_uid), do: map

  defp anomaly_detection_device(nil), do: %{}
  defp anomaly_detection_device(device_uid), do: %{"uid" => device_uid}

  # Canonical re-key on ingest. Anomaly verdicts (edge spike + central seasonal)
  # and capacity-forecast verdicts arrive keyed by a raw host/agent/series id (for
  # example "ns03", "agent-ns03", "k8s-cp3-worker3"). Findings written under those
  # raw ids never join the canonical `sr:` device, so device-detail queries the
  # canonical uid and shows "No anomaly findings". We resolve the raw identity to
  # the canonical inventory device uid here so device.uid,
  # metadata.service_radar.device_uid, finding_info dimensions, and the deterministic
  # finding_uid are all coherently keyed off the canonical uid.
  #
  # `DeviceCorrelation.resolve/1` is cache-backed (one DB lookup per device per
  # burst) and fail-open (returns nil on miss or error), so on a miss we fall back
  # to the raw id label exactly as before — re-key is additive, never lossy.
  defp anomaly_detection_device_uid(payload) do
    raw = anomaly_detection_raw_device_uid(payload)
    target_device_ip = anomaly_detection_target_device_ip(payload)
    metric_class = get_in(payload, ["anomaly", "metric_class"])

    if snmp_metric_class?(metric_class) do
      resolve_snmp_anomaly_device_uid(payload, target_device_ip)
    else
      case DeviceCorrelation.resolve(
             anomaly_detection_correlation_candidate(payload, raw, target_device_ip)
           ) do
        uid when is_binary(uid) and uid != "" -> uid
        _ -> raw
      end
    end
  end

  defp resolve_snmp_anomaly_device_uid(payload, nil) do
    resolve_snmp_anomaly_device_uid(payload, nil, anomaly_detection_raw_device_uid(payload))
  end

  defp resolve_snmp_anomaly_device_uid(payload, target_device_ip) do
    resolve_snmp_anomaly_device_uid(
      payload,
      target_device_ip,
      anomaly_detection_raw_device_uid(payload)
    )
  end

  defp resolve_snmp_anomaly_device_uid(payload, target_device_ip, raw_device_uid) do
    metric_class = get_in(payload, ["anomaly", "metric_class"])

    case DeviceCorrelation.resolve_snmp_interface_metric(%{
           device_uid: raw_device_uid,
           target_device_ip: target_device_ip,
           partition: anomaly_detection_partition(payload),
           metric_name: anomaly_detection_metric_name(payload, metric_class),
           if_index: anomaly_detection_if_index(payload)
         }) do
      uid when is_binary(uid) and uid != "" -> uid
      _ -> {:withhold, snmp_anomaly_withhold_reason(target_device_ip)}
    end
  end

  defp snmp_anomaly_withhold_reason(nil), do: :snmp_target_missing
  defp snmp_anomaly_withhold_reason(_target_device_ip), do: :snmp_interface_metric_unresolvable

  defp anomaly_detection_withheld_telemetry(payload, reason) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :anomaly_detection, :withheld],
      %{count: 1},
      %{
        reason: reason,
        metric_class: get_in(payload, ["anomaly", "metric_class"]),
        metric_name:
          anomaly_detection_metric_name(payload, get_in(payload, ["anomaly", "metric_class"])),
        if_index: anomaly_detection_if_index(payload),
        target_device_ip: anomaly_detection_target_device_ip(payload)
      }
    )
  end

  # A. Confirmation backstop. True when an anomaly-detection finding is an UNCONFIRMED
  # pending breadcrumb that must NOT be surfaced as an OCSF event. Capacity-forecast
  # verdicts (no anomaly lifecycle) and anomaly resolutions (anomaly_clear, so a
  # previously-confirmed finding can be closed downstream) always surface.
  defp anomaly_finding_unconfirmed?(normalized, payload) do
    cond do
      capacity_forecast_signal?(normalized, payload) -> false
      not is_map(payload["anomaly"]) -> false
      anomaly_pending_reason?(payload) -> true
      anomaly_clear_finding?(payload) -> false
      true -> not anomaly_finding_confirmed?(payload)
    end
  end

  defp anomaly_clear_finding?(payload) do
    get_in(payload, ["anomaly", "state"]) in @anomaly_clear_states or
      get_in(payload, ["anomaly", "detector_state"]) in @anomaly_clear_states
  end

  defp anomaly_finding_confirmed?(payload) do
    detector_state = get_in(payload, ["anomaly", "detector_state"])
    state = get_in(payload, ["anomaly", "state"])

    detector_state != @anomaly_pending_detector_state and
      state in @anomaly_open_states and
      not anomaly_consecutive_below_confirm?(payload)
  end

  # Only treat the slot count as disqualifying when the producer reported BOTH the
  # observed consecutive count AND its confirm_slots threshold — we must not assume a
  # default threshold against a producer that may be tuned lower (we would wrongly drop
  # a legitimately confirmed finding). Absent confirm_slots, detector_state/state are
  # the authoritative confirmation signals.
  defp anomaly_consecutive_below_confirm?(payload) do
    with consecutive when is_integer(consecutive) <-
           get_in(payload, ["anomaly", "consecutive_anomalous"]),
         confirm_slots when is_integer(confirm_slots) and confirm_slots > 0 <-
           get_in(payload, ["anomaly", "confirm_slots"]) do
      consecutive < confirm_slots
    else
      _ -> false
    end
  end

  # B(i). Confirmation-aware severity clamp (defense-in-depth behind the A gate): an
  # unconfirmed pending breadcrumb is never allowed past Low (severity_id 2), regardless
  # of the producer's severity_id. A confirmed finding keeps its producer severity.
  @doc false
  def anomaly_detection_severity_id(normalized, payload) do
    severity_id = normalized["severity_id"] || 0

    severity_id
    |> maybe_cap_pending_anomaly_severity(payload)
    |> maybe_cap_edge_drift_severity(payload)
    |> then(fn severity_id ->
      if anomaly_finding_unconfirmed?(normalized, payload) do
        min(severity_id, 2)
      else
        severity_id
      end
    end)
  end

  defp anomaly_pending_reason?(payload) when is_map(payload) do
    anomaly_shaped_payload?(payload) and
      Enum.any?(
        [
          get_in(payload, ["anomaly", "reason"]),
          payload["reason"],
          payload["message"]
        ],
        fn
          value when is_binary(value) ->
            value
            |> String.trim()
            |> String.downcase()
            |> String.starts_with?("breach pending")

          _ ->
            false
        end
      )
  end

  defp anomaly_pending_reason?(_payload), do: false

  defp anomaly_edge_drift?(payload) when is_map(payload) do
    anomaly_shaped_payload?(payload) and
      (payload["verdict_source"] == "edge-drift" or
         get_in(payload, ["anomaly", "verdict_source"]) == "edge-drift" or
         payload["detector_method"] == "cusum_drift" or
         get_in(payload, ["anomaly", "detector_method"]) == "cusum_drift")
  end

  defp anomaly_edge_drift?(_payload), do: false

  defp anomaly_detection_unconfirmed_telemetry(payload) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :anomaly_detection, :unconfirmed_skipped],
      %{count: 1},
      %{
        metric_class: get_in(payload, ["anomaly", "metric_class"]),
        detector_state: get_in(payload, ["anomaly", "detector_state"]),
        state: get_in(payload, ["anomaly", "state"]),
        consecutive_anomalous: get_in(payload, ["anomaly", "consecutive_anomalous"]),
        verdict_source: payload["verdict_source"]
      }
    )
  end

  defp anomaly_detection_raw_device_uid(payload) do
    first_non_blank([
      payload["device_uid"],
      payload["deviceUid"],
      payload["device_id"],
      payload["deviceId"],
      get_in(payload, ["device", "uid"]),
      get_in(payload, ["anomaly", "metadata", "device_uid"]),
      get_in(payload, ["anomaly", "metadata", "device_id"]),
      get_in(payload, ["anomaly", "metadata", "host_id"]),
      get_in(payload, ["anomaly", "series_key"])
    ])
  end

  defp anomaly_detection_correlation_candidate(payload, raw, target_device_ip) do
    anomaly_metadata = get_in(payload, ["anomaly", "metadata"]) || %{}

    # `target_device_ip` is the SNMP target identity (see
    # Observability.AnomalyDetection.SeriesKey: it is the polled device, not the
    # polling agent's own host). For an SNMP poll of a *remote* target the raw
    # device_uid/agent_id name the polling agent, so resolving by agent first
    # (DeviceCorrelation.resolve order: agent before ip) would re-key the finding
    # to the polling agent instead of the polled target. We surface the target ip
    # as the leading `:ip` candidate and, for SNMP findings that actually carry a
    # target ip, omit `agent_id` so the polled target wins. Self-poll SNMP (no
    # target ip) keeps `agent_id`, which is the only path that resolves the
    # agent-keyed device.
    metric_class = get_in(payload, ["anomaly", "metric_class"])
    snmp_target_poll? = snmp_metric_class?(metric_class) and not is_nil(target_device_ip)

    agent_id =
      if snmp_target_poll? do
        nil
      else
        first_non_blank([
          payload["agent_id"],
          payload["agentId"],
          anomaly_metadata["agent_id"],
          anomaly_metadata["agentId"]
        ])
      end

    %{
      device_uid: raw,
      agent_id: agent_id,
      hostname:
        first_non_blank([
          anomaly_metadata["host_id"],
          anomaly_metadata["hostname"],
          get_in(payload, ["device", "hostname"]),
          payload["hostname"],
          payload["host"]
        ]),
      ip:
        first_non_blank([
          target_device_ip,
          payload["device_ip"],
          payload["source_ip"],
          anomaly_metadata["device_ip"],
          anomaly_metadata["ip"]
        ]),
      partition:
        first_non_blank([
          payload["partition"],
          anomaly_metadata["partition"]
        ])
    }
  end

  defp anomaly_detection_target_device_ip(payload) do
    source_identity = get_in(payload, ["source_identity"]) || %{}

    first_non_blank([
      payload["target_device_ip"],
      get_in(payload, ["anomaly", "target_device_ip"]),
      get_in(payload, ["anomaly", "metadata", "target_device_ip"]),
      source_identity["target_device_ip"]
    ])
  end

  defp anomaly_detection_partition(payload) do
    source_identity = get_in(payload, ["source_identity"]) || %{}
    anomaly_metadata = get_in(payload, ["anomaly", "metadata"]) || %{}

    first_non_blank([
      payload["partition"],
      payload["partition_id"],
      anomaly_metadata["partition"],
      anomaly_metadata["partition_id"],
      source_identity["partition"],
      source_identity["partition_id"]
    ])
  end

  defp snmp_metric_class?(metric_class) when is_binary(metric_class) do
    metric_class == "snmp" or String.starts_with?(metric_class, "snmp.")
  end

  defp snmp_metric_class?(_metric_class), do: false

  defp inventory_vulnerability_contexts(payload) do
    [
      build_context("cve", vulnerability_id(payload)),
      build_context("package", package_context_id(payload))
    ]
  end

  defp vulnerability_id(payload) do
    first_non_blank([
      payload["cve"],
      payload["cve_id"],
      payload["cveId"],
      payload["vulnerability_id"],
      payload["vulnerabilityId"],
      payload["finding_id"],
      payload["findingId"],
      get_in(payload, ["vulnerability", "id"]),
      get_in(payload, ["vulnerability", "cve"]),
      get_in(payload, ["advisory", "id"]),
      get_in(payload, ["advisory", "cve"])
    ])
  end

  defp package_context(payload) do
    case payload["package"] || payload["affected_package"] || payload["affectedPackage"] do
      package when is_map(package) -> package
      _ -> %{}
    end
  end

  defp package_context_id(payload) do
    package = package_context(payload)

    first_non_blank([
      package["purl_canonical"],
      package["purlCanonical"],
      package["purl"],
      package_context_label(payload)
    ])
  end

  defp package_context_label(payload) do
    package = package_context(payload)
    name = first_non_blank([package["name"], package["package_name"], payload["package_name"]])
    version = first_non_blank([package["version"], payload["package_version"]])

    manager =
      first_non_blank([
        package["package_manager"],
        package["manager"],
        payload["package_manager"]
      ])

    cond do
      is_binary(name) and is_binary(version) and is_binary(manager) ->
        "#{manager}:#{name}@#{version}"

      is_binary(name) and is_binary(version) ->
        "#{name}@#{version}"

      is_binary(name) ->
        name

      true ->
        nil
    end
  end

  defp normalize_src_endpoint(payload) do
    ip = payload["peer_ip"] || payload["peer_addr"] || payload["src_ip"] || payload["source_ip"]
    asn = normalize_int(payload["peer_asn"] || payload["peerAsn"])

    %{"ip" => normalize_optional_string(ip), "asn" => asn}
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stable_event_identity(subject, payload, raw_data) do
    source_id =
      payload["event_id"] ||
        payload["id"] ||
        payload["eventId"] ||
        payload["alert_id"] ||
        payload["arancini_message_id"] ||
        payload["bmp_message_id"] ||
        payload["message_id"]

    stable_key =
      if is_binary(source_id) and source_id != "" do
        "#{subject}:#{source_id}"
      else
        hash = Base.encode16(:crypto.hash(:sha256, raw_data), case: :lower)
        "#{subject}:#{hash}"
      end

    deterministic_uuid(stable_key)
  end

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    # Set version 4 and variant 10xx for UUID compliance.
    versioned_a3 = a3 |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x4000)
    versioned_a4 = a4 |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a1, a2, versioned_a3, versioned_a4, a5])
    |> IO.iodata_to_binary()
  end

  defp first_non_blank(values) when is_list(values) do
    values
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.find(&is_binary/1)
  end

  defp first_present(values) when is_list(values) do
    Enum.find(values, fn
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(value) when is_float(value), do: Float.to_string(value)
  defp normalize_optional_string(_), do: nil

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(value) when is_integer(value), do: value / 1

  defp normalize_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp normalize_float(_), do: nil

  defp arancini_prefix(payload) when is_map(payload) do
    with prefix_addr when is_binary(prefix_addr) <-
           normalize_optional_string(payload["prefix_addr"]),
         prefix_len when is_integer(prefix_len) <- normalize_int(payload["prefix_len"]) do
      "#{prefix_addr}/#{prefix_len}"
    else
      _ -> nil
    end
  end

  defp normalize_raw_data(data) when is_binary(data) do
    if String.valid?(data) do
      data
    else
      Base.encode64(data)
    end
  end

  defp normalize_raw_data(data), do: inspect(data)
end

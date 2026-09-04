defmodule ServiceRadar.StatusHandler do
  @moduledoc """
  Handles service status updates forwarded from agent-gateway.

  Results payloads are routed to ResultsRouter when available.

  When `source == "flow-attribution"` the status message carries a
  `Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch` payload drained by the agent's
  netprobe sidecar. Each contained `FlowAttributionEvent` is written to CNPG
  with the gateway-derived partition and agent identity; the in-cluster
  correlation worker joins it against collected flow rows without publishing a
  `flow.attributed.*` read-back message.
  """

  use GenServer

  alias ServiceRadar.Admission.FlowLane
  alias ServiceRadar.Admission.RetainedPluginLane
  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch
  alias ServiceRadar.Inventory.DiscoveryIngestor
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Observability.AnomalyDetection.SeriesKey
  alias ServiceRadar.Observability.CausalPredictionSubject
  alias ServiceRadar.ResultsRouter

  require Logger

  @flow_attribution_source "flow-attribution"
  @retained_plugin_capability "plugin-result-retained:v1"
  @workload_identity_source "workload-identity"
  @addon_source_prefix "addon:"
  @plugin_source_prefix "plugin:"
  @metric_only_sources [
    "sysmon-metrics",
    :sysmon_metrics,
    "snmp-metrics",
    :snmp_metrics,
    "icmp-metrics",
    :icmp_metrics,
    "rperf-metrics",
    :rperf_metrics,
    "mtr-metrics",
    :mtr_metrics,
    "sweep-metrics",
    :sweep_metrics
  ]
  @addon_ocsf_subject "pdns.ocsf"
  @addon_otel_log_subject "logs.otel.addon"
  @plugin_ocsf_subject "events.ocsf.processed"
  @plugin_otel_log_subject "logs.otel.plugin"
  @results_router_timeout_ms 30_000
  @signal_schema_metadata_keys %{
    producer_id: "serviceradar.signal_schema.producer_id",
    producer_version: "serviceradar.signal_schema.producer_version",
    schema_id: "serviceradar.signal_schema.schema_id",
    schema_version: "serviceradar.signal_schema.schema_version",
    display_contract_id: "serviceradar.signal_schema.display_contract_id",
    display_contract_version: "serviceradar.signal_schema.display_contract_version",
    display_contract: "serviceradar.signal_schema.display_contract",
    signal_type: "serviceradar.signal_schema.signal_type",
    payload_kind: "serviceradar.signal_schema.payload_kind"
  }
  @signal_schema_ref_max_length 160
  @signal_schema_path_max_length 240

  @telemetry_batch_received [
    :serviceradar,
    :event_writer,
    :attributed_flow,
    :batch_received
  ]
  @telemetry_batch_decode_failed [
    :serviceradar,
    :event_writer,
    :attributed_flow,
    :batch_decode_failed
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("StatusHandler started on node #{Node.self()}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:status_update, status}, state) do
    case process_cast_status_update(status) do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Status update processing failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:status_update, status}, from, state) do
    cond do
      flow_attribution_status?(status) ->
        admission_reply(FlowLane.admit(status, from), state)

      retained_plugin_result_status?(status) ->
        admission_reply(RetainedPluginLane.admit(status, from), state)

      endpoint_inventory_result_status?(status) ->
        # Endpoint inventory has its own bounded admission queue. Admitting through
        # the singleton ResultsRouter first couples scan acknowledgements to every
        # unrelated result handler and lets slow plugin ingestion block the fleet.
        admission_reply(ResultsRouter.admit_endpoint_inventory(status, from), state)

      true ->
        {:reply, process_status_update(status, sync_results?: true), state}
    end
  end

  defp process_cast_status_update(status) do
    cond do
      flow_attribution_status?(status) -> FlowLane.admit_cast(status)
      retained_plugin_result_status?(status) -> RetainedPluginLane.admit_cast(status)
      true -> process_status_update(status, sync_results?: false)
    end
  end

  defp admission_reply(:ok, state), do: {:noreply, state}
  defp admission_reply({:error, _reason} = error, state), do: {:reply, error, state}
  defp admission_reply({:ok, _result} = ok, state), do: {:reply, ok, state}

  defp process_status_update(status, opts) do
    # No per-message log here — this is the hot ingestion path. Useful breadcrumbs
    # come from the OTel span on process/2, not a log line per status.
    process(status, opts)
  end

  defp process(%{source: source}, _opts) when source in @metric_only_sources do
    {:error, {:gateway_metric_status_not_core_routable, source}}
  end

  defp process(%{source: source} = status, opts)
       when source in ["results", :results, "plugin-result", :plugin_result] do
    case Process.whereis(ResultsRouter) do
      pid when is_pid(pid) ->
        if Keyword.get(opts, :sync_results?, false) do
          call_results_router(pid, status)
        else
          GenServer.cast(pid, {:results_update, status})
          :ok
        end

      _ ->
        process_legacy_results(status)
    end
  end

  defp process(%{source: source} = status, _opts)
       when source in [@flow_attribution_source, :flow_attribution] do
    process_flow_attribution(status)
  end

  defp process(%{source: source} = status, _opts)
       when source in [@workload_identity_source, :workload_identity] do
    ServiceRadar.WorkloadIdentity.persist_snapshot(status)
  end

  defp process(%{source: @addon_source_prefix <> addon_id} = status, _opts) do
    handle_package_telemetry(status, :addon, addon_id)
  end

  defp process(%{source: @plugin_source_prefix <> plugin_id} = status, _opts) do
    handle_package_telemetry(status, :plugin, plugin_id)
  end

  defp process(%{service_name: service_name} = status, _opts)
       when service_name in ["agent", :agent] do
    # The agent capability status carries per-add-on state in its payload; record it
    # in the add-on status read model (issue 3425, task 7.2). No-op when there are no
    # add-ons in the payload.
    ServiceRadar.Plugins.AddonStatusIngestor.ingest(status)
  end

  defp process(_status, _opts), do: :ok

  defp call_results_router(pid, status) do
    GenServer.call(pid, {:results_update, status}, results_router_timeout_ms())
  catch
    :exit, {:timeout, _call} ->
      Logger.warning("ResultsRouter status update timed out")
      {:error, :results_router_timeout}

    :exit, reason ->
      Logger.warning("ResultsRouter status update failed: #{inspect(reason)}")
      {:error, {:results_router_unavailable, reason}}
  end

  defp endpoint_inventory_result_status?(%{source: source, service_type: service_type})
       when source in ["results", :results] and
              service_type in ["endpoint_inventory", :endpoint_inventory], do: true

  defp endpoint_inventory_result_status?(_status), do: false

  defp flow_attribution_status?(%{source: source})
       when source in [@flow_attribution_source, :flow_attribution], do: true

  defp flow_attribution_status?(_status), do: false

  defp retained_plugin_result_status?(%{source: source} = status)
       when source in ["plugin-result", :plugin_result] do
    retained_plugin_admission_enabled?() and
      @retained_plugin_capability in (status[:delivery_capabilities] ||
                                        status["delivery_capabilities"] || [])
  end

  defp retained_plugin_result_status?(_status), do: false

  defp retained_plugin_admission_enabled? do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retained_plugin_admission_enabled, false)
  end

  defp results_router_timeout_ms do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:results_router_timeout_ms, @results_router_timeout_ms)
  end

  @doc false
  def process_flow_attribution(status) do
    partition_id = status[:partition] || "default"
    agent_id = status[:agent_id]
    message = status[:message]

    case decode_batch(message) do
      {:ok, %FlowAttributionEventBatch{events: events, dropped_since_last: dropped}} ->
        # Persist the pushed attributions to CNPG so the correlation worker can
        # join them against collected NetFlow into attributed_flow rows. NetFlow
        # stays the flow source; netprobe only supplies the process context.
        case persist_flow_attribution(events || [], partition_id, agent_id) do
          :ok ->
            committed_flow_result(events, dropped, partition_id, agent_id)

          {:ok, _result} ->
            committed_flow_result(events, dropped, partition_id, agent_id)

          {:error, _reason} = error ->
            error

          other ->
            {:error, {:unexpected_flow_attribution_persist_result, other}}
        end

      :error ->
        :telemetry.execute(
          @telemetry_batch_decode_failed,
          %{count: 1},
          %{partition_id: partition_id, agent_id: agent_id}
        )

        Logger.warning(
          "StatusHandler: failed to decode FlowAttributionEventBatch",
          partition_id: partition_id,
          agent_id: agent_id,
          message_size: byte_size_or_nil(message)
        )

        {:error, :flow_attribution_decode_failed}
    end
  end

  defp decode_batch(message) when is_binary(message) and byte_size(message) > 0 do
    case FlowAttributionEventBatch.decode(message) do
      {:ok, %FlowAttributionEventBatch{} = batch} -> {:ok, batch}
      %FlowAttributionEventBatch{} = batch -> {:ok, batch}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_batch(_), do: :error

  @doc false
  def emit_flow_attribution_committed(%{
        event_count: event_count,
        dropped_since_last: dropped,
        partition_id: partition_id,
        agent_id: agent_id
      }) do
    :telemetry.execute(
      @telemetry_batch_received,
      %{count: 1, event_count: event_count, dropped_since_last: dropped},
      %{partition_id: partition_id, agent_id: agent_id}
    )
  end

  defp committed_flow_result(events, dropped, partition_id, agent_id) do
    {:ok,
     %{
       event_count: length(events || []),
       dropped_since_last: dropped || 0,
       partition_id: partition_id,
       agent_id: agent_id
     }}
  end

  defp persist_flow_attribution(events, partition_id, agent_id) do
    case flow_attribution_persister() do
      {mod, fun, extra_args} -> apply(mod, fun, [events, partition_id, agent_id | extra_args])
      fun when is_function(fun, 3) -> fun.(events, partition_id, agent_id)
      mod when is_atom(mod) -> mod.persist(events, partition_id, agent_id)
    end
  end

  defp flow_attribution_persister do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:flow_attribution_persister, ServiceRadar.FlowAttribution)
  end

  defp handle_package_telemetry(status, producer_type, producer_id) do
    partition_id = status[:partition] || "default"
    agent_id = status[:agent_id]
    message = status[:message]

    metadata = %{
      producer_type: producer_type,
      producer_id: producer_id,
      partition_id: partition_id,
      agent_id: agent_id,
      gateway_id: status[:gateway_id],
      source_ip: status[:source_ip]
    }

    case decode_addon_telemetry_batch(message) do
      {:ok, %TelemetryBatch{records: records} = batch} ->
        publish_package_telemetry_records(records || [], batch, metadata)

      :error ->
        Logger.warning(
          "StatusHandler: failed to decode add-on TelemetryBatch",
          partition_id: partition_id,
          agent_id: agent_id,
          producer_type: producer_type,
          producer_id: producer_id,
          message_size: byte_size_or_nil(message)
        )

        {:error, :addon_telemetry_decode_failed}
    end
  end

  defp decode_addon_telemetry_batch(message) when is_binary(message) and byte_size(message) > 0 do
    case TelemetryBatch.decode(message) do
      {:ok, %TelemetryBatch{} = batch} -> {:ok, batch}
      %TelemetryBatch{} = batch -> {:ok, batch}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_addon_telemetry_batch(_), do: :error

  defp publish_package_telemetry_records(records, batch, metadata) do
    Enum.each(records, fn %TelemetryRecord{} = record ->
      publish_package_telemetry_record(record, batch, metadata)
    end)

    :ok
  end

  defp publish_package_telemetry_record(%TelemetryRecord{} = record, batch, metadata) do
    cond do
      ocsf_record?(record) ->
        publish_ocsf_telemetry_record(record, batch, metadata)

      otel_log_record?(record) ->
        publish_otel_log_telemetry_record(record, batch, metadata)

      discovery_record?(record) ->
        DiscoveryIngestor.ingest(record.payload, metadata)

      handled_off_this_path?(record) ->
        count_unpublished_payload_kind(record, metadata, :handled_elsewhere)

      true ->
        drop_unknown_payload_kind(record, metadata)
    end
  end

  # Payload kinds that legitimately reach this function and are consumed
  # somewhere else, so arriving here is not a fault.
  #
  # SERVICERADAR_METRICS is the volume case: the Rust add-on SDK sends metrics
  # through StreamTelemetry, the gateway's PluginMetricsPublisher publishes them
  # to JetStream, and the status is still forwarded here with those records
  # intact. Treating them as unknown would log a warning per metric record from
  # every Rust add-on in the fleet.
  #
  # The OTLP kinds ride AddonService.RelayOtlp rather than StreamTelemetry, so
  # they should not appear in a batch at all -- but they are a known kind that
  # belongs elsewhere, not an unrecognized one, and the distinction is worth
  # keeping in the telemetry.
  # Device observations an add-on made about OTHER hosts. Unlike every other kind
  # on this path they are INVENTORY, not observability, so they leave here for
  # DiscoveryIngestor rather than a JetStream subject.
  defp discovery_record?(%TelemetryRecord{payload_kind: :TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1}),
    do: true

  defp discovery_record?(%TelemetryRecord{payload_kind: 8}), do: true
  defp discovery_record?(_record), do: false

  defp handled_off_this_path?(%TelemetryRecord{payload_kind: kind}) do
    kind in [
      :TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
      7,
      :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
      3,
      :TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
      4,
      :TELEMETRY_PAYLOAD_KIND_OTLP_METRICS,
      5,
      :TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC,
      6
    ]
  end

  # A payload kind nothing on this path recognizes.
  #
  # This used to be a bare `true -> :ok`, which meant an add-on could ship a new
  # payload kind, have every record discarded, and see the service report
  # HEALTHY -- the failure is indistinguishable from an add-on that produced
  # nothing. Say it out loud instead.
  #
  # Unthrottled, matching drop_misbucketed_metric/2 directly above. After the
  # handled_off_this_path?/1 enumeration the remaining case is a genuinely
  # unrecognized kind, which means a version skew between an add-on and core --
  # rare, and worth one line per occurrence while it lasts.
  defp drop_unknown_payload_kind(%TelemetryRecord{} = record, metadata) do
    count_unpublished_payload_kind(record, metadata, :unknown_payload_kind)

    Logger.warning(
      "StatusHandler: dropped an add-on telemetry record with an unrecognized payload kind",
      payload_kind: inspect(record.payload_kind),
      producer_type: metadata.producer_type,
      producer_id: metadata.producer_id,
      partition_id: metadata.partition_id,
      agent_id: metadata.agent_id
    )

    :ok
  end

  defp count_unpublished_payload_kind(%TelemetryRecord{} = record, metadata, reason) do
    :telemetry.execute(
      [:serviceradar, :status_handler, :addon_telemetry, :unpublished],
      %{count: 1},
      %{
        reason: reason,
        payload_kind: record.payload_kind,
        producer_id: metadata.producer_id,
        partition_id: metadata.partition_id
      }
    )

    :ok
  end

  defp publish_ocsf_telemetry_record(%TelemetryRecord{payload: payload} = record, batch, metadata) do
    with {:ok, event} <- decode_json_payload(payload),
         :ok <- ensure_ocsf_shape(event, metadata) do
      if anomaly_verdict?(event) do
        publish_edge_anomaly_verdict(event, metadata)
      else
        publish_generic_ocsf_event(event, record, batch, metadata)
      end
    else
      # A mis-bucketed metric is dropped at the source, not republished. It is not
      # a transport failure, so ack it (:ok) rather than logging a publish error.
      {:drop, :misbucketed_metric} ->
        :ok

      {:error, reason} ->
        log_package_telemetry_publish_failure("OCSF", reason, metadata)
    end
  end

  defp publish_generic_ocsf_event(event, record, batch, metadata) do
    with {:ok, enriched} <- enrich_ocsf_event(event, record, batch, metadata),
         {:ok, json} <- Jason.encode(enriched),
         :ok <- publish(addon_telemetry_publisher(), ocsf_subject(metadata), json) do
      :ok
    else
      {:error, reason} ->
        log_package_telemetry_publish_failure("OCSF", reason, metadata)
    end
  end

  # An edge anomaly add-on emits an OCSF Detection Finding shaped as a causal
  # anomaly verdict (signal_type=causal, event_type=anomaly). Route it onto the
  # prediction spine (signals.analytics.predictions.<series>) so the
  # EventWriter AnalyticsSignals processor persists + alert-enqueues it through the
  # same OCSF finding path, instead of the generic OCSF add-on subject. The
  # verdict_source label (edge-spike) rides through in the body and is surfaced
  # by AnalyticsSignals.
  defp anomaly_verdict?(event) when is_map(event) do
    # 1.f3 dual-consume: accept the honest new routing value alongside the legacy "causal".
    Map.get(event, "signal_type") in ["causal", "prediction"] and
      Map.get(event, "event_type") == "anomaly"
  end

  defp anomaly_verdict?(_), do: false

  defp publish_edge_anomaly_verdict(event, metadata) do
    # The edge add-on routes on a provisional producer hint; re-key the verdict to
    # the canonical series_key central derives from the attested source_identity so
    # it lands on the same subject/series central would (the basis for the
    # edge<->central + seasonal joins). Fall back to the hint only when no
    # source_identity is present (move-anomaly-detection-to-edge §3.4b).
    hint = get_in(event, ["anomaly", "series_key"])
    series_key = canonical_series_key(Map.get(event, "source_identity"), metadata) || hint

    event = rekey_anomaly_verdict(event, series_key)
    subject = causal_prediction_subject(series_key)

    with {:ok, json} <- Jason.encode(event),
         :ok <- publish(addon_telemetry_publisher(), subject, json) do
      :ok
    else
      {:error, reason} ->
        log_package_telemetry_publish_failure("anomaly_verdict", reason, metadata)
    end
  end

  defp canonical_series_key(source_identity, metadata) when is_map(source_identity) do
    SeriesKey.from_source_identity(source_identity, partition_id: metadata.partition_id)
  end

  defp canonical_series_key(_source_identity, _metadata), do: nil

  defp causal_prediction_subject(series_key) when is_binary(series_key) and series_key != "" do
    CausalPredictionSubject.build(series_key)
  end

  defp causal_prediction_subject(_series_key), do: CausalPredictionSubject.build(nil)

  # Stamp the canonical key onto the persisted verdict so AnalyticsSignals stores it
  # under the same series_key edge-derived consumers use (and the producer hint becomes dead
  # debug metadata). Only rewrites blocks that already exist.
  defp rekey_anomaly_verdict(event, series_key) when is_binary(series_key) do
    event
    |> put_nested_series_key("anomaly", series_key)
    |> put_nested_series_key("source_identity", series_key)
  end

  defp rekey_anomaly_verdict(event, _series_key), do: event

  defp put_nested_series_key(event, key, series_key) do
    case Map.get(event, key) do
      %{} = nested -> Map.put(event, key, Map.put(nested, "series_key", series_key))
      _ -> event
    end
  end

  # REC10 (fj #3788): the events-vs-metrics plane is selected from the producer's
  # `payload_kind`, which is untrusted. Without this guard, a metric body a plugin
  # mislabels as an OCSF event would be published verbatim onto the events stream
  # (and only the consumer-side guardrail in Processors.Events would catch it).
  # Reject it at the source: a real OCSF event always carries `class_uid` and never
  # carries metric-only fields (`temporality`/`points`/`serviceradar.metric.*`).
  defp ensure_ocsf_shape(event, metadata) when is_map(event) do
    cond do
      metric_shaped_payload?(event) ->
        drop_misbucketed_metric(metadata, :metric_fields_present)

      not Map.has_key?(event, "class_uid") ->
        drop_misbucketed_metric(metadata, :missing_class_uid)

      true ->
        :ok
    end
  end

  defp ensure_ocsf_shape(_event, _metadata), do: :ok

  defp metric_shaped_payload?(event) do
    String.starts_with?(to_string(Map.get(event, "schema", "")), "serviceradar.metric") or
      Map.has_key?(event, "temporality") or Map.has_key?(event, "points")
  end

  defp drop_misbucketed_metric(metadata, reason) do
    :telemetry.execute(
      [:serviceradar, :status_handler, :ocsf, :misbucketed],
      %{count: 1},
      %{
        reason: reason,
        producer_id: metadata.producer_id,
        partition_id: metadata.partition_id
      }
    )

    Logger.warning(
      "StatusHandler: dropped a non-OCSF payload tagged as an OCSF event (mis-bucketed metric)",
      reason: reason,
      producer_type: metadata.producer_type,
      producer_id: metadata.producer_id,
      partition_id: metadata.partition_id,
      agent_id: metadata.agent_id
    )

    {:drop, :misbucketed_metric}
  end

  defp publish_otel_log_telemetry_record(
         %TelemetryRecord{payload: payload} = record,
         batch,
         metadata
       ) do
    with {:ok, log} <- decode_json_payload(payload),
         {:ok, enriched} <- enrich_otel_log(log, record, batch, metadata),
         {:ok, json} <- Jason.encode(enriched),
         :ok <- publish(addon_telemetry_publisher(), otel_log_subject(metadata), json) do
      :ok
    else
      {:error, reason} ->
        log_package_telemetry_publish_failure("OTEL log", reason, metadata)
    end
  end

  defp log_package_telemetry_publish_failure(signal_type, reason, metadata) do
    Logger.warning(
      "StatusHandler: failed to publish package #{signal_type} telemetry",
      reason: inspect(reason),
      producer_type: metadata.producer_type,
      producer_id: metadata.producer_id,
      partition_id: metadata.partition_id,
      agent_id: metadata.agent_id
    )
  end

  defp ocsf_record?(%TelemetryRecord{payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT}), do: true
  defp ocsf_record?(%TelemetryRecord{payload_kind: 1}), do: true

  defp ocsf_record?(_), do: false

  defp otel_log_record?(%TelemetryRecord{payload_kind: :TELEMETRY_PAYLOAD_KIND_OTEL_LOG}),
    do: true

  defp otel_log_record?(%TelemetryRecord{payload_kind: 2}), do: true

  defp otel_log_record?(_), do: false

  defp decode_json_payload(payload) when is_binary(payload) and byte_size(payload) > 0 do
    Jason.decode(payload)
  end

  defp decode_json_payload(_), do: {:error, :empty_payload}

  defp enrich_ocsf_event(event, record, batch, metadata) when is_map(event) do
    existing_metadata = map_value(event["metadata"])
    signal_schema = signal_schema_ref(record.metadata)

    ocsf_metadata =
      existing_metadata
      |> Map.put_new("product", %{"name" => "ServiceRadar"})
      |> Map.put("service_radar", service_radar_metadata(record, batch, metadata))
      |> maybe_put_signal_schema(signal_schema)

    {:ok, Map.put(event, "metadata", ocsf_metadata)}
  end

  defp enrich_ocsf_event(_event, _record, _batch, _metadata), do: {:error, :invalid_ocsf_event}

  defp enrich_otel_log(log, record, batch, metadata) when is_map(log) do
    signal_schema = signal_schema_ref(record.metadata)

    service_radar =
      record
      |> service_radar_metadata(batch, metadata)
      |> maybe_put_flat_signal_schema(signal_schema)

    attributes =
      log
      |> Map.get("attributes", %{})
      |> map_value()
      |> Map.put("service_radar", service_radar)

    {:ok, Map.put(log, "attributes", attributes)}
  end

  defp enrich_otel_log(_log, _record, _batch, _metadata), do: {:error, :invalid_otel_log}

  defp service_radar_metadata(record, batch, metadata) do
    source = batch.source

    base = %{
      "agent_id" => metadata.agent_id,
      "gateway_id" => metadata.gateway_id,
      "partition_id" => metadata.partition_id,
      "source_ip" => metadata.source_ip,
      "source_type" => source && source.source_type,
      "source_instance" => source && source.source_instance,
      "event_id" => record.event_id,
      "observed_time_unix_nano" => record.observed_time_unix_nano,
      "event_time_unix_nano" => record.event_time_unix_nano
    }

    case metadata.producer_type do
      :plugin -> Map.put(base, "plugin_id", metadata.producer_id)
      _ -> Map.put(base, "addon_id", metadata.producer_id)
    end
  end

  defp ocsf_subject(%{producer_type: :plugin}), do: @plugin_ocsf_subject
  defp ocsf_subject(_metadata), do: @addon_ocsf_subject

  defp otel_log_subject(%{producer_type: :plugin}), do: @plugin_otel_log_subject
  defp otel_log_subject(_metadata), do: @addon_otel_log_subject

  defp signal_schema_ref(metadata) when is_map(metadata) do
    ref = %{
      "producer_id" => metadata_value(metadata, :producer_id),
      "producer_version" => metadata_value(metadata, :producer_version),
      "schema_id" => metadata_value(metadata, :schema_id),
      "schema_version" => metadata_value(metadata, :schema_version),
      "display_contract_id" => metadata_value(metadata, :display_contract_id),
      "display_contract_version" => metadata_value(metadata, :display_contract_version),
      "display_contract" => metadata_value(metadata, :display_contract),
      "signal_type" => metadata_value(metadata, :signal_type),
      "payload_kind" => metadata_value(metadata, :payload_kind)
    }

    if valid_signal_schema_ref?(ref) do
      ref
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp signal_schema_ref(_metadata), do: nil

  defp metadata_value(metadata, key) do
    metadata_key = Map.fetch!(@signal_schema_metadata_keys, key)

    case Map.get(metadata, metadata_key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp valid_signal_schema_ref?(ref) do
    ref_id?(ref["schema_id"]) and semver?(ref["schema_version"]) and
      ref_id?(ref["display_contract_id"]) and semver?(ref["display_contract_version"]) and
      optional_ref_id?(ref["producer_id"]) and optional_semver?(ref["producer_version"]) and
      optional_bundle_path?(ref["display_contract"]) and ref["signal_type"] in ["event", "log"] and
      ref["payload_kind"] in ["ocsf_event", "otel_log"]
  end

  defp ref_id?(value)
       when is_binary(value) and byte_size(value) <= @signal_schema_ref_max_length do
    Regex.match?(~r/^[a-z0-9][a-z0-9_.-]*$/, value)
  end

  defp ref_id?(_value), do: false

  defp optional_ref_id?(nil), do: true
  defp optional_ref_id?(value), do: ref_id?(value)

  defp semver?(value) when is_binary(value) do
    case Version.parse(value) do
      {:ok, _version} -> true
      :error -> false
    end
  end

  defp semver?(_value), do: false

  defp optional_semver?(nil), do: true
  defp optional_semver?(value), do: semver?(value)

  defp optional_bundle_path?(nil), do: true

  defp optional_bundle_path?(value)
       when is_binary(value) and byte_size(value) <= @signal_schema_path_max_length do
    not String.starts_with?(value, "/") and String.ends_with?(value, ".json") and
      not Enum.any?(String.split(value, "/"), &(&1 == ".."))
  end

  defp optional_bundle_path?(_value), do: false

  defp maybe_put_signal_schema(metadata, nil), do: metadata

  defp maybe_put_signal_schema(metadata, signal_schema),
    do: update_in(metadata, ["service_radar"], &Map.put(&1, "signal_schema", signal_schema))

  defp maybe_put_flat_signal_schema(metadata, nil), do: metadata

  defp maybe_put_flat_signal_schema(metadata, signal_schema),
    do: Map.put(metadata, "signal_schema", signal_schema)

  defp map_value(value) when is_map(value), do: value
  defp map_value(_), do: %{}

  defp addon_telemetry_publisher do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:addon_telemetry_publisher, {Connection, :publish, []})
  end

  defp publish({mod, fun, extra_args}, subject, payload) do
    apply(mod, fun, [subject, payload | extra_args])
  end

  defp publish(fun, subject, payload) when is_function(fun, 2), do: fun.(subject, payload)

  defp byte_size_or_nil(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_nil(_), do: nil

  defp process_legacy_results(%{source: source}) when source in @metric_only_sources do
    {:error, {:gateway_metric_status_not_core_routable, source}}
  end

  defp process_legacy_results(%{service_type: "sync"} = status) do
    # In schema-agnostic mode, DB schema is set by CNPG search_path
    schedule_sync_ingestion(status)
  end

  defp process_legacy_results(_status), do: :ok

  defp schedule_sync_ingestion(status) do
    message = status[:message]
    async_enabled = Application.get_env(:serviceradar_core, :sync_ingestor_async, true)

    if async_enabled do
      SyncIngestorQueue.enqueue(message)
    else
      SyncIngestorQueue.ingest_sync_results(message)
    end
  end
end

defmodule ServiceRadar.StatusHandler do
  @moduledoc """
  Handles service status updates forwarded from agent-gateway.

  Results payloads are routed to ResultsRouter when available.

  When `source == "flow-attribution"` the status message carries a
  `Netprobepb.FlowAttributionEventBatch` payload drained by the agent's
  netprobe sidecar. Each contained `FlowAttributionEvent` is routed into
  `ServiceRadar.EventWriter.AttributedFlowJoiner.put_attribution/3` for the
  5-tuple join with host-slice flow records. The partition we tag the
  attribution with is the partition the agent-gateway derived from the mTLS
  certificate (carried as `status[:partition]`) — agent-claimed values cannot
  influence the published subject.
  """

  use GenServer

  alias Netprobepb.FlowAttributionEvent
  alias Netprobepb.FlowAttributionEventBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias ServiceRadar.EventWriter.AttributedFlowJoiner
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.ResultsRouter

  require Logger

  @flow_attribution_source "flow-attribution"
  @workload_identity_source "workload-identity"
  @addon_source_prefix "addon:"
  @addon_ocsf_subject "pdns.ocsf"

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
    case process_status_update(status, sync_results?: false) do
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
  def handle_call({:status_update, status}, _from, state) do
    {:reply, process_status_update(status, sync_results?: true), state}
  end

  defp process_status_update(status, opts) do
    service_type = status[:service_type] || "unknown"
    source = status[:source] || "unknown"
    service_name = status[:service_name] || "unknown"

    Logger.info(
      "StatusHandler received: service_type=#{service_type} source=#{source} " <>
        "service=#{service_name}"
    )

    process(status, opts)
  end

  defp process(%{source: source} = status, opts)
       when source in [
              "results",
              :results,
              "sysmon-metrics",
              :sysmon_metrics,
              "snmp-metrics",
              :snmp_metrics,
              "plugin-result",
              :plugin_result
            ] do
    case Process.whereis(ResultsRouter) do
      pid when is_pid(pid) ->
        if Keyword.get(opts, :sync_results?, false) do
          GenServer.call(pid, {:results_update, status}, 30_000)
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
    handle_flow_attribution(status)
  end

  defp process(%{source: source} = status, _opts)
       when source in [@workload_identity_source, :workload_identity] do
    ServiceRadar.WorkloadIdentity.persist_snapshot(status)
  end

  defp process(%{source: @addon_source_prefix <> addon_id} = status, _opts) do
    handle_addon_telemetry(status, addon_id)
  end

  defp process(%{service_name: service_name} = status, _opts)
       when service_name in ["agent", :agent] do
    # The agent capability status carries per-add-on state in its payload; record it
    # in the add-on status read model (issue 3425, task 7.2). No-op when there are no
    # add-ons in the payload.
    ServiceRadar.Plugins.AddonStatusIngestor.ingest(status)
  end

  defp process(_status, _opts), do: :ok

  defp handle_flow_attribution(status) do
    partition_id = status[:partition] || "default"
    agent_id = status[:agent_id]
    message = status[:message]

    case decode_batch(message) do
      {:ok, %FlowAttributionEventBatch{events: events, dropped_since_last: dropped}} ->
        :telemetry.execute(
          @telemetry_batch_received,
          %{count: 1, event_count: length(events || []), dropped_since_last: dropped || 0},
          %{partition_id: partition_id, agent_id: agent_id}
        )

        Enum.each(events || [], fn
          %FlowAttributionEvent{} = event ->
            AttributedFlowJoiner.put_attribution(event, partition_id, agent_id: agent_id)

          _ ->
            :ok
        end)

        # Persist the pushed attributions to CNPG so the correlation worker can
        # join them against collected NetFlow into attributed_flow rows. NetFlow
        # stays the flow source; netprobe only supplies the process context.
        ServiceRadar.FlowAttribution.persist(events || [], partition_id, agent_id)

        :ok

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

  defp handle_addon_telemetry(status, addon_id) do
    partition_id = status[:partition] || "default"
    agent_id = status[:agent_id]
    message = status[:message]

    case decode_addon_telemetry_batch(message) do
      {:ok, %TelemetryBatch{records: records} = batch} ->
        publish_addon_ocsf_records(records || [], batch, %{
          addon_id: addon_id,
          partition_id: partition_id,
          agent_id: agent_id,
          gateway_id: status[:gateway_id],
          source_ip: status[:source_ip]
        })

      :error ->
        Logger.warning(
          "StatusHandler: failed to decode add-on TelemetryBatch",
          partition_id: partition_id,
          agent_id: agent_id,
          addon_id: addon_id,
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

  defp publish_addon_ocsf_records(records, batch, metadata) do
    records
    |> Enum.filter(&ocsf_record?/1)
    |> Enum.each(fn %TelemetryRecord{payload: payload} = record ->
      with {:ok, event} <- decode_ocsf_payload(payload),
           {:ok, enriched} <- enrich_ocsf_event(event, record, batch, metadata),
           {:ok, json} <- Jason.encode(enriched),
           :ok <- publish(addon_telemetry_publisher(), @addon_ocsf_subject, json) do
        :ok
      else
        {:error, reason} ->
          Logger.warning(
            "StatusHandler: failed to publish add-on OCSF telemetry",
            reason: inspect(reason),
            addon_id: metadata.addon_id,
            partition_id: metadata.partition_id,
            agent_id: metadata.agent_id
          )
      end
    end)

    :ok
  end

  defp ocsf_record?(%TelemetryRecord{payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT}), do: true
  defp ocsf_record?(%TelemetryRecord{payload_kind: 1}), do: true

  defp ocsf_record?(_), do: false

  defp decode_ocsf_payload(payload) when is_binary(payload) and byte_size(payload) > 0 do
    Jason.decode(payload)
  end

  defp decode_ocsf_payload(_), do: {:error, :empty_payload}

  defp enrich_ocsf_event(event, record, batch, metadata) when is_map(event) do
    source = batch.source
    existing_metadata = map_value(event["metadata"])

    ocsf_metadata =
      existing_metadata
      |> Map.put_new("product", %{"name" => "ServiceRadar"})
      |> Map.put("service_radar", %{
        "addon_id" => metadata.addon_id,
        "agent_id" => metadata.agent_id,
        "gateway_id" => metadata.gateway_id,
        "partition_id" => metadata.partition_id,
        "source_ip" => metadata.source_ip,
        "source_type" => source && source.source_type,
        "source_instance" => source && source.source_instance,
        "event_id" => record.event_id,
        "observed_time_unix_nano" => record.observed_time_unix_nano,
        "event_time_unix_nano" => record.event_time_unix_nano
      })

    {:ok, Map.put(event, "metadata", ocsf_metadata)}
  end

  defp enrich_ocsf_event(_event, _record, _batch, _metadata), do: {:error, :invalid_ocsf_event}

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

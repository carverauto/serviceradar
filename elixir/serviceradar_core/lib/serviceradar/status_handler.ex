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
  alias ServiceRadar.EventWriter.AttributedFlowJoiner
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias ServiceRadar.ResultsRouter

  require Logger

  @flow_attribution_source "flow-attribution"

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
    service_type = status[:service_type] || "unknown"
    source = status[:source] || "unknown"
    service_name = status[:service_name] || "unknown"

    Logger.info(
      "StatusHandler received: service_type=#{service_type} source=#{source} " <>
        "service=#{service_name}"
    )

    case process(status) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Status update processing failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp process(%{source: source} = status)
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
        GenServer.cast(pid, {:results_update, status})
        :ok

      _ ->
        process_legacy_results(status)
    end
  end

  defp process(%{source: source} = status)
       when source in [@flow_attribution_source, :flow_attribution] do
    handle_flow_attribution(status)
  end

  defp process(%{service_name: service_name} = status)
       when service_name in ["agent", :agent] do
    # The agent capability status carries per-add-on state in its payload; record it
    # in the add-on status read model (issue 3425, task 7.2). No-op when there are no
    # add-ons in the payload.
    ServiceRadar.Plugins.AddonStatusIngestor.ingest(status)
  end

  defp process(_status), do: :ok

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

defmodule ServiceRadar.StatusHandler do
  @moduledoc """
  Handles service status updates forwarded from agent-gateway.

  The handler focuses on sync result ingestion for push-first discovery.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Inventory.SyncIngestorQueue

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
    tenant_id = status[:tenant_id] || "unknown"
    service_name = status[:service_name] || "unknown"

    Logger.info(
      "StatusHandler received: service_type=#{service_type} source=#{source} " <>
        "tenant=#{tenant_id} service=#{service_name}"
    )

    case process(status) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("Status update processing failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp process(%{service_type: "sync"} = status) do
    case status do
      %{source: "results"} ->
        tenant_id = status[:tenant_id]

        if is_binary(tenant_id) and tenant_id != "" do
          schedule_sync_ingestion(status, tenant_id)
        else
          {:error, :missing_tenant_id}
        end

      _ ->
        :ok
    end
  end

  defp process(_status), do: :ok

  defp schedule_sync_ingestion(status, tenant_id) do
    message = status[:message]
    async_enabled = Application.get_env(:serviceradar_core, :sync_ingestor_async, true)

    if async_enabled do
      SyncIngestorQueue.enqueue(message, tenant_id)
    else
      SyncIngestorQueue.ingest_sync_results(message, tenant_id)
    end
  end
end

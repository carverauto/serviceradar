defmodule ServiceRadar.StatusHandler do
  @moduledoc """
  Handles service status updates forwarded from agent-gateway.

  The handler focuses on sync result ingestion for push-first discovery.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.SyncIngestor

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
      case start_ingestion_task(message, tenant_id) do
        :ok -> :ok
        {:error, :inflight_limit} -> ingest_sync_results(message, tenant_id)
        {:error, _} = error -> error
      end
    else
      ingest_sync_results(message, tenant_id)
    end
  end

  defp start_ingestion_task(message, tenant_id) do
    task_fun = fn -> ingest_sync_results(message, tenant_id) end

    task_result =
      case Process.whereis(ServiceRadar.SyncIngestor.TaskSupervisor) do
        nil ->
          Task.start(task_fun)

        _pid ->
          max_inflight = max_inflight_chunks()
          %{active: active} =
            Supervisor.count_children(ServiceRadar.SyncIngestor.TaskSupervisor)

          if active >= max_inflight do
            {:error, :inflight_limit}
          else
            Task.Supervisor.start_child(ServiceRadar.SyncIngestor.TaskSupervisor, task_fun)
          end
      end

    case task_result do
      {:ok, _pid} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to start sync ingestion task for tenant=#{tenant_id}: #{inspect(reason)}")
        {:error, reason}

      _ ->
        :ok
    end
  end

  defp max_inflight_chunks do
    configured = Application.get_env(:serviceradar_core, :sync_ingestor_max_inflight, 2)

    if is_integer(configured) and configured > 0 do
      configured
    else
      1
    end
  end

  defp ingest_sync_results(message, tenant_id) do
    Logger.info("Processing sync results for tenant=#{tenant_id}")

    case decode_results(message) do
      {:ok, updates} ->
        Logger.info("Decoded #{length(updates)} sync updates for tenant=#{tenant_id}")
        actor = system_actor(tenant_id)
        result = sync_ingestor().ingest_updates(updates, tenant_id, actor: actor)
        Logger.info("SyncIngestor result for tenant=#{tenant_id}: #{inspect(result)}")

        # Record sync status on the IntegrationSource
        record_sync_status(updates, tenant_id, actor, result)

        result

      {:error, reason} ->
        Logger.warning("Sync results decode failed for tenant=#{tenant_id}: #{inspect(reason)}")
        {:error, {:invalid_sync_results, reason}}
    end
  rescue
    error ->
      Logger.warning("Sync results ingestion failed for tenant=#{tenant_id}: #{inspect(error)}")
      {:error, error}
  end

  # Record sync status on the IntegrationSource if we have a sync_service_id
  defp record_sync_status(updates, tenant_id, actor, ingest_result) do
    # Extract sync_service_id from the first update's metadata
    sync_service_id = extract_sync_service_id(updates)

    if sync_service_id do
      tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

      sync_result =
        case ingest_result do
          :ok -> :success
          {:error, _} -> :failed
        end

      case IntegrationSource.get_by_id(sync_service_id,
             tenant: tenant_schema,
             actor: actor,
             authorize?: false
           ) do
        {:ok, source} ->
          source
          |> Ash.Changeset.for_update(:record_sync, %{
            result: sync_result,
            device_count: length(updates)
          })
          |> Ash.update(tenant: tenant_schema, actor: actor, authorize?: false)
          |> case do
            {:ok, _} ->
              Logger.debug("Recorded sync status for IntegrationSource #{sync_service_id}")

            {:error, reason} ->
              Logger.warning(
                "Failed to record sync status for #{sync_service_id}: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          Logger.debug(
            "Could not find IntegrationSource #{sync_service_id} to record sync: #{inspect(reason)}"
          )
      end
    end
  rescue
    error ->
      Logger.warning("Error recording sync status: #{inspect(error)}")
  end

  defp extract_sync_service_id([update | _]) when is_map(update) do
    # Check both string and atom keys
    metadata = update["metadata"] || update[:metadata] || %{}
    metadata["sync_service_id"] || metadata[:sync_service_id]
  end

  defp extract_sync_service_id(_), do: nil

  defp decode_results(nil), do: {:ok, []}

  defp decode_results(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:ok, _other} -> {:error, :unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_results(_message), do: {:error, :unsupported_payload}

  defp system_actor(tenant_id) do
    %{
      id: "system",
      email: "gateway@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end

  defp sync_ingestor do
    Application.get_env(:serviceradar_core, :sync_ingestor, SyncIngestor)
  end
end

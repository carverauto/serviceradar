defmodule ServiceRadar.StatusHandler do
  @moduledoc """
  Handles service status updates forwarded from agent-gateway.

  The handler focuses on sync result ingestion for push-first discovery.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Integrations.SyncService

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:status_update, status}, state) do
    case process(status) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("Status update processing failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp process(%{service_type: "sync"} = status) do
    _ = update_sync_service_heartbeat(status)

    case status do
      %{source: "results"} ->
        tenant_id = status[:tenant_id]

        if is_binary(tenant_id) and tenant_id != "" do
          case decode_results(status[:message]) do
            {:ok, updates} ->
              actor = system_actor(tenant_id)
              sync_ingestor().ingest_updates(updates, tenant_id, actor: actor)

            {:error, reason} ->
              {:error, {:invalid_sync_results, reason}}
          end
        else
          {:error, :missing_tenant_id}
        end

      _ ->
        :ok
    end
  end

  defp process(_status), do: :ok

  defp update_sync_service_heartbeat(status) do
    if not repo_enabled?() do
      :ok
    else
      tenant_id = status[:tenant_id]
      component_id = status[:agent_id]

      if is_binary(tenant_id) and tenant_id != "" and is_binary(component_id) and component_id != "" do
        update_sync_service_record(tenant_id, component_id, status)
      else
        :ok
      end
    end
  end

  defp update_sync_service_record(tenant_id, component_id, status) do
    require Ash.Query

    query =
      SyncService
      |> Ash.Query.for_read(:read, %{}, tenant: nil, authorize?: false)
      |> Ash.Query.filter(component_id == ^component_id and tenant_id == ^tenant_id)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, authorize?: false) do
      {:ok, nil} ->
        :ok

      {:ok, service} ->
        availability = Map.get(status, :available, true)
        new_status = if availability, do: :online, else: :degraded

        service
        |> Ash.Changeset.for_update(:update, %{
          last_heartbeat_at: DateTime.utc_now(),
          status: new_status
        }, tenant: tenant_id, authorize?: false)
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      Process.whereis(ServiceRadar.Repo)
  end

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

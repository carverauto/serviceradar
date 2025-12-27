defmodule ServiceRadar.Integrations.Workers.SyncToDataSvcWorker do
  @moduledoc """
  Oban worker for reliably syncing IntegrationSource config to datasvc.

  Uses Oban for reliable background processing with retries, ensuring
  configuration changes are eventually synced to the datasvc KV store
  even if the datasvc is temporarily unavailable.

  ## Usage

      # Enqueue a sync job
      SyncToDataSvcWorker.enqueue(source_id, :put)

      # Enqueue a delete job
      SyncToDataSvcWorker.enqueue(source_id, :delete)
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 5,
    unique: [period: 30, keys: [:source_id, :operation]]

  require Logger

  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Infrastructure.Poller

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id, "operation" => operation}}) do
    case operation do
      "put" -> sync_source(source_id)
      "delete" -> delete_source(source_id)
      _ -> {:error, "Unknown operation: #{operation}"}
    end
  end

  @doc """
  Enqueues a sync job for an integration source.

  ## Options

  - `:operation` - `:put` (default) or `:delete`
  - `:scheduled_at` - Optional DateTime for delayed execution
  """
  @spec enqueue(String.t(), atom(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(source_id, operation \\ :put, opts \\ []) do
    args = %{
      "source_id" => source_id,
      "operation" => Atom.to_string(operation)
    }

    job_opts =
      case opts[:scheduled_at] do
        %DateTime{} = at -> [scheduled_at: at]
        _ -> []
      end

    args
    |> new(job_opts)
    |> Oban.insert()
  end

  defp sync_source(source_id) do
    # Fetch the source without authorization (system job)
    case IntegrationSource
         |> Ash.Query.for_read(:by_id, %{id: source_id})
         |> Ash.Query.set_tenant(nil)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Logger.warning("IntegrationSource #{source_id} not found, skipping sync")
        :ok

      {:ok, source} ->
        do_sync(source)

      {:error, error} ->
        Logger.error("Failed to fetch IntegrationSource #{source_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp do_sync(source) do
    config = build_sync_config(source)
    key = "sync/sources/#{source.id}"

    case ServiceRadar.DataService.Client.put(key, Jason.encode!(config)) do
      :ok ->
        Logger.info("Synced integration source #{source.name} (#{source.id}) to datasvc")
        :ok

      {:error, {:not_connected, _}} ->
        Logger.warning("DataService not connected, will retry sync for #{source.name}")
        {:error, :not_connected}

      {:error, reason} ->
        Logger.error("Failed to sync #{source.name} to datasvc: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp delete_source(source_id) do
    key = "sync/sources/#{source_id}"

    case ServiceRadar.DataService.Client.delete(key) do
      :ok ->
        Logger.info("Removed integration source #{source_id} from datasvc")
        :ok

      {:error, :not_found} ->
        Logger.debug("Integration source #{source_id} not found in datasvc, already removed")
        :ok

      {:error, {:not_connected, _}} ->
        Logger.warning("DataService not connected, will retry delete for #{source_id}")
        {:error, :not_connected}

      {:error, reason} ->
        Logger.error("Failed to remove #{source_id} from datasvc: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_sync_config(source) do
    credentials =
      case source.credentials_encrypted do
        nil -> %{}
        "" -> %{}
        json -> Jason.decode!(json)
      end

    # Find available pollers in the source's partition
    available_pollers = find_pollers_for_partition(source.partition, source.tenant_id)

    %{
      "id" => source.id,
      "name" => source.name,
      "type" => Atom.to_string(source.source_type),
      "endpoint" => source.endpoint,
      "enabled" => source.enabled,
      "prefix" => "#{source.source_type}/",
      "poll_interval" => format_duration(source.poll_interval_seconds),
      "sweep_interval" => format_duration(source.sweep_interval_seconds),
      "discovery_interval" => format_duration(source.discovery_interval_seconds),
      "agent_id" => source.agent_id,
      "poller_id" => source.poller_id,
      "partition" => source.partition,
      "tenant_id" => source.tenant_id,
      "credentials" => credentials,
      "page_size" => source.page_size,
      "network_blacklist" => source.network_blacklist,
      "queries" => source.queries,
      "custom_fields" => source.custom_fields,
      "settings" => source.settings,
      # Include available pollers for load balancing decisions
      "available_pollers" => available_pollers
    }
  end

  defp find_pollers_for_partition(nil, _tenant_id), do: []
  defp find_pollers_for_partition("", _tenant_id), do: []

  defp find_pollers_for_partition(partition_slug, tenant_id) do
    case Poller
         |> Ash.Query.for_read(:by_partition, %{partition_slug: partition_slug})
         |> Ash.read(tenant: tenant_id, authorize?: false) do
      {:ok, pollers} ->
        Enum.map(pollers, fn p ->
          %{
            "id" => p.id,
            "status" => p.status,
            "is_healthy" => p.is_healthy,
            "agent_count" => p.agent_count,
            "last_seen" => p.last_seen && DateTime.to_iso8601(p.last_seen)
          }
        end)

      {:error, reason} ->
        Logger.warning("Failed to find pollers for partition #{partition_slug}: #{inspect(reason)}")
        []
    end
  end

  defp format_duration(seconds) when is_integer(seconds) do
    cond do
      rem(seconds, 3600) == 0 -> "#{div(seconds, 3600)}h"
      rem(seconds, 60) == 0 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  defp format_duration(_), do: "5m"
end

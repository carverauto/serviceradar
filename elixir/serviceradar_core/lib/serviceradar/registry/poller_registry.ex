defmodule ServiceRadar.PollerRegistry do
  @moduledoc """
  Distributed registry for tracking available pollers across the ERTS cluster.

  Uses Horde.Registry with CRDT-based synchronization for eventually consistent
  poller discovery. Pollers register with metadata including tenant, partition,
  domain, capabilities, and availability status.

  ## Registration Format

  Pollers register with a tenant-scoped composite key and metadata:

      key = {tenant_id, partition_id, node()}
      metadata = %{
        tenant_id: "tenant-uuid",
        partition_id: "partition-1",
        domain: "site-a",
        capabilities: [:snmp, :grpc, :sweep],
        node: :"poller1@192.168.1.20",
        status: :available,
        registered_at: ~U[2024-01-01 00:00:00Z],
        last_heartbeat: ~U[2024-01-01 00:01:00Z]
      }

  ## Multi-Tenancy

  All lookups are tenant-scoped to ensure isolation:

      # Find all pollers for a tenant's partition
      ServiceRadar.PollerRegistry.find_pollers_for_partition(tenant_id, partition_id)

      # Find available pollers for a tenant
      ServiceRadar.PollerRegistry.find_available_pollers(tenant_id)

  ## Querying Pollers

      # Find all pollers for a partition (requires tenant_id)
      ServiceRadar.PollerRegistry.find_pollers_for_partition("tenant-uuid", "partition-1")

      # Find available pollers for a tenant
      ServiceRadar.PollerRegistry.find_available_pollers("tenant-uuid")
  """

  use Horde.Registry

  def start_link(opts) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique] ++ opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    [members: members()]
    |> Keyword.merge(opts)
    |> Horde.Registry.init()
  end

  defp members do
    # Auto-discover cluster members
    :auto
  end

  @doc """
  Register a poller with the given key and metadata.
  """
  @spec register(term(), map()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(key, metadata) do
    Horde.Registry.register(__MODULE__, key, metadata)
  end

  @doc """
  Unregister a poller by key.
  """
  @spec unregister(term()) :: :ok
  def unregister(key) do
    Horde.Registry.unregister(__MODULE__, key)
  end

  @doc """
  Update the metadata for a registered poller.
  """
  @spec update_value(term(), (map() -> map())) :: {any(), any()} | :error
  def update_value(key, callback) do
    Horde.Registry.update_value(__MODULE__, key, callback)
  end

  @doc """
  Look up a poller by key.
  """
  @spec lookup(term()) :: [{pid(), map()}]
  def lookup(key) do
    Horde.Registry.lookup(__MODULE__, key)
  end

  @doc """
  Register a poller with the given poller_id and metadata.

  Called by the poller process when starting up.
  This is a convenience function that constructs metadata from poller_info.
  """
  @spec register_poller(String.t(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register_poller(poller_id, poller_info) do
    metadata = %{
      poller_id: poller_id,
      tenant_id: Map.get(poller_info, :tenant_id),
      partition_id: Map.get(poller_info, :partition_id),
      node: Node.self(),
      status: Map.get(poller_info, :status, :available),
      registered_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    case register(poller_id, metadata) do
      {:ok, _pid} = result ->
        # Broadcast registration event
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "poller:registrations",
          {:poller_registered, metadata}
        )

        result

      error ->
        error
    end
  end

  @doc """
  Unregister a poller when it shuts down.
  """
  @spec unregister_poller(String.t()) :: :ok
  def unregister_poller(poller_id) do
    Horde.Registry.unregister(__MODULE__, poller_id)

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "poller:registrations",
      {:poller_disconnected, poller_id}
    )

    :ok
  end

  @doc """
  Update poller heartbeat timestamp.
  """
  @spec heartbeat(String.t()) :: :ok | :error
  def heartbeat(poller_id) do
    case Horde.Registry.update_value(__MODULE__, poller_id, fn meta ->
           %{meta | last_heartbeat: DateTime.utc_now()}
         end) do
      {_new, _old} -> :ok
      :error -> :error
    end
  end

  @doc """
  Find all pollers for a specific tenant and partition.

  Uses tenant-scoped lookup to ensure multi-tenant isolation.
  """
  @spec find_pollers_for_partition(String.t(), String.t()) :: [map()]
  def find_pollers_for_partition(tenant_id, partition_id) do
    match_spec = [
      {{:"$1", :"$2", %{tenant_id: tenant_id, partition_id: partition_id}}, [],
       [{{:"$1", :"$2"}}]}
    ]

    Horde.Registry.select(__MODULE__, match_spec)
    |> Enum.map(fn {key, pid} ->
      case Horde.Registry.lookup(__MODULE__, key) do
        [{^pid, metadata}] -> Map.put(metadata, :pid, pid)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Find all pollers for a specific tenant.
  """
  @spec find_pollers_for_tenant(String.t()) :: [map()]
  def find_pollers_for_tenant(tenant_id) do
    match_spec = [
      {{:"$1", :"$2", %{tenant_id: tenant_id}}, [], [{{:"$1", :"$2"}}]}
    ]

    Horde.Registry.select(__MODULE__, match_spec)
    |> Enum.map(fn {key, pid} ->
      case Horde.Registry.lookup(__MODULE__, key) do
        [{^pid, metadata}] -> Map.put(metadata, :pid, pid)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Find an available poller for a tenant's partition.

  Returns `{:ok, metadata}` if found, `{:error, :no_available_poller}` otherwise.
  """
  @spec find_available_poller_for_partition(String.t(), String.t()) ::
          {:ok, map()} | {:error, :no_available_poller}
  def find_available_poller_for_partition(tenant_id, partition_id) do
    pollers = find_pollers_for_partition(tenant_id, partition_id)

    case Enum.find(pollers, &(&1.status == :available)) do
      nil -> {:error, :no_available_poller}
      poller -> {:ok, poller}
    end
  end

  @doc """
  Find all available pollers for a tenant.
  """
  @spec find_available_pollers(String.t()) :: [map()]
  def find_available_pollers(tenant_id) do
    find_pollers_for_tenant(tenant_id)
    |> Enum.filter(&(&1.status == :available))
  end

  @doc """
  Find all available pollers across the cluster (all tenants).

  Note: Use tenant-scoped functions for production. This is primarily
  for admin/debugging purposes.
  """
  @spec find_all_available_pollers() :: [map()]
  def find_all_available_pollers do
    # Get all registered pollers
    Horde.Registry.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
    |> Enum.filter(&(&1.status == :available))
  end

  @doc """
  Get all registered pollers.
  """
  @spec all_pollers() :: [map()]
  def all_pollers do
    Horde.Registry.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
  end

  @doc """
  Count of registered pollers.
  """
  @spec count() :: non_neg_integer()
  def count do
    Horde.Registry.count(__MODULE__)
  end
end

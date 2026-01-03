defmodule ServiceRadar.GatewayTracker do
  @moduledoc """
  Platform-level tracker for agent gateways.

  Unlike tenant-scoped registries, gateways are platform infrastructure that
  serve all tenants. This tracker maintains a platform-wide view of all
  registered gateways using ETS and PubSub for cluster-wide visibility.

  ## Usage

      # Register a gateway (typically called by GatewayRegistrationWorker)
      GatewayTracker.register("gateway-001", %{
        partition: "default",
        domain: "default",
        node: Node.self()
      })

      # List all gateways
      GatewayTracker.list_gateways()

      # Check if a gateway is active
      GatewayTracker.active?("gateway-001")
  """

  use GenServer

  require Logger

  @table :gateway_tracker
  @stale_threshold_ms :timer.minutes(2)
  @cleanup_interval_ms :timer.minutes(1)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register or update a gateway.
  """
  @spec register(String.t(), map()) :: :ok
  def register(gateway_id, metadata \\ %{}) do
    now = System.monotonic_time(:millisecond)

    gateway_info = %{
      gateway_id: gateway_id,
      node: Map.get(metadata, :node, Node.self()),
      partition: Map.get(metadata, :partition, "default"),
      domain: Map.get(metadata, :domain, "default"),
      status: Map.get(metadata, :status, :available),
      registered_at: Map.get(metadata, :registered_at, DateTime.utc_now()),
      last_heartbeat: DateTime.utc_now(),
      last_heartbeat_mono: now
    }

    # Insert into local ETS (may fail if table not ready)
    try do
      :ets.insert(@table, {gateway_id, gateway_info})
    rescue
      ArgumentError ->
        Logger.warning("[GatewayTracker] ETS table not ready, skipping local insert for #{gateway_id}")
    end

    # Broadcast for UI updates across all nodes
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "gateway:platform",
      {:gateway_registered, gateway_info}
    )

    Logger.debug("[GatewayTracker] Registered gateway: #{gateway_id} on node #{inspect(gateway_info.node)}")

    :ok
  end

  @doc """
  Update heartbeat for a gateway.
  Also broadcasts the updated info so UI can stay in sync.
  """
  @spec heartbeat(String.t()) :: :ok
  def heartbeat(gateway_id) do
    now = System.monotonic_time(:millisecond)

    # If ETS table doesn't exist or entry not found, we may need to re-register
    case :ets.lookup(@table, gateway_id) do
      [{_key, info}] ->
        updated = %{info | last_heartbeat: DateTime.utc_now(), last_heartbeat_mono: now}
        :ets.insert(@table, {gateway_id, updated})

        # Broadcast heartbeat so UI can stay in sync (catches missed registration)
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "gateway:platform",
          {:gateway_registered, updated}
        )

      [] ->
        Logger.debug("[GatewayTracker] Heartbeat for unknown gateway #{gateway_id}, skipping")
    end

    :ok
  rescue
    ArgumentError ->
      Logger.debug("[GatewayTracker] ETS table not ready for heartbeat")
      :ok
  end

  @doc """
  Unregister a gateway.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(gateway_id) do
    :ets.delete(@table, gateway_id)

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "gateway:platform",
      {:gateway_unregistered, gateway_id}
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  List all tracked gateways with their active status.
  """
  @spec list_gateways() :: [map()]
  def list_gateways do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.map(fn {_key, info} ->
      age_ms = now - Map.get(info, :last_heartbeat_mono, now)
      Map.put(info, :active, age_ms < @stale_threshold_ms)
    end)
    |> Enum.sort_by(& &1.gateway_id)
  rescue
    ArgumentError -> []
  end

  @doc """
  Check if a gateway is active (heartbeat within threshold).
  """
  @spec active?(String.t()) :: boolean()
  def active?(gateway_id) do
    case :ets.lookup(@table, gateway_id) do
      [{_key, info}] ->
        now = System.monotonic_time(:millisecond)
        age_ms = now - Map.get(info, :last_heartbeat_mono, now)
        age_ms < @stale_threshold_ms

      [] ->
        false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Get info for a specific gateway.
  """
  @spec get_gateway(String.t()) :: map() | nil
  def get_gateway(gateway_id) do
    case :ets.lookup(@table, gateway_id) do
      [{_key, info}] -> info
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Count of tracked gateways.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for tracking gateways
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    # Schedule periodic cleanup of stale entries
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_stale_gateways()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_stale_gateways do
    now = System.monotonic_time(:millisecond)
    stale_threshold = now - :timer.hours(24)

    # Remove gateways that haven't sent heartbeat in 24 hours
    :ets.tab2list(@table)
    |> Enum.each(fn {gateway_id, info} ->
      last_heartbeat_mono = Map.get(info, :last_heartbeat_mono, now)

      if last_heartbeat_mono < stale_threshold do
        :ets.delete(@table, gateway_id)
        Logger.debug("[GatewayTracker] Removed stale gateway: #{gateway_id}")
      end
    end)
  rescue
    _ -> :ok
  end
end

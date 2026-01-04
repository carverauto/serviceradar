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
    now_dt = DateTime.utc_now()

    # Note: We use wall-clock time (DateTime) for last_heartbeat since
    # monotonic time is not comparable across different nodes in a distributed cluster
    gateway_info = %{
      gateway_id: gateway_id,
      node: Map.get(metadata, :node, Node.self()),
      partition: Map.get(metadata, :partition, "default"),
      domain: Map.get(metadata, :domain, "default"),
      status: Map.get(metadata, :status, :available),
      registered_at: Map.get(metadata, :registered_at, now_dt),
      last_heartbeat: now_dt
    }

    # Insert into local ETS (may fail if table not ready)
    try do
      :ets.insert(@table, {gateway_id, gateway_info})
    rescue
      ArgumentError ->
        Logger.warning(
          "[GatewayTracker] ETS table not ready, skipping local insert for #{gateway_id}"
        )
    end

    # Broadcast for UI updates across all nodes
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "gateway:platform",
      {:gateway_registered, gateway_info}
    )

    Logger.debug(
      "[GatewayTracker] Registered gateway: #{gateway_id} on node #{inspect(gateway_info.node)}"
    )

    :ok
  end

  @doc """
  Update heartbeat for a gateway.
  Also broadcasts the updated info so UI can stay in sync.
  """
  @spec heartbeat(String.t()) :: :ok
  def heartbeat(gateway_id) do
    now_dt = DateTime.utc_now()

    # If ETS table doesn't exist or entry not found, we may need to re-register
    case :ets.lookup(@table, gateway_id) do
      [{_key, info}] ->
        updated = %{info | last_heartbeat: now_dt}
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
  Uses wall-clock time for distributed staleness detection.
  """
  @spec list_gateways() :: [map()]
  def list_gateways do
    now_ms = System.system_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.map(fn {_key, info} ->
      last_heartbeat_ms =
        case Map.get(info, :last_heartbeat) do
          %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
          _ -> now_ms
        end

      age_ms = max(now_ms - last_heartbeat_ms, 0)
      Map.put(info, :active, age_ms < @stale_threshold_ms)
    end)
    |> Enum.sort_by(& &1.gateway_id)
  rescue
    ArgumentError -> []
  end

  @doc """
  Check if a gateway is active (heartbeat within threshold).
  Uses wall-clock time for distributed staleness detection.
  """
  @spec active?(String.t()) :: boolean()
  def active?(gateway_id) do
    case :ets.lookup(@table, gateway_id) do
      [{_key, info}] ->
        now_ms = System.system_time(:millisecond)

        last_heartbeat_ms =
          case Map.get(info, :last_heartbeat) do
            %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
            _ -> now_ms
          end

        age_ms = max(now_ms - last_heartbeat_ms, 0)
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
    now_dt = DateTime.utc_now()
    stale_threshold_seconds = div(:timer.hours(24), 1_000)

    # Remove gateways that haven't sent heartbeat in 24 hours
    :ets.tab2list(@table)
    |> Enum.each(fn {gateway_id, info} ->
      last_heartbeat =
        info
        |> Map.get(:last_heartbeat)
        |> normalize_datetime()
        |> case do
          nil -> now_dt
          dt -> dt
        end

      if DateTime.diff(now_dt, last_heartbeat, :second) > stale_threshold_seconds do
        :ets.delete(@table, gateway_id)
        Logger.debug("[GatewayTracker] Removed stale gateway: #{gateway_id}")
      end
    end)
  rescue
    _ -> :ok
  end

  defp normalize_datetime(%DateTime{} = dt), do: dt
  defp normalize_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  defp normalize_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_datetime(_), do: nil
end

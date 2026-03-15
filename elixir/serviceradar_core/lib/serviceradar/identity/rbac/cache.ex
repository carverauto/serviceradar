defmodule ServiceRadar.Identity.RBAC.Cache do
  @moduledoc """
  ETS-based cross-process permission cache for RBAC.

  Provides a shared cache keyed by user_id, storing permissions as MapSets
  with configurable TTL. All BEAM processes in the VM share this cache,
  eliminating redundant DB queries for the same user's permissions.

  ## Cache Tiers

  This cache serves as L2 in a two-tier strategy:
  - **L1**: Process dictionary (fastest, per-process, no TTL)
  - **L2**: This ETS table (shared, with TTL, invalidation via PubSub)
  - **L3**: Database query (fallback when both caches miss)
  """
  use GenServer

  require Logger

  @table :rbac_permissions_cache
  @cleanup_interval to_timeout(minute: 1)
  @default_ttl_seconds 300

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Fetch cached permissions for a user. Returns `{:ok, MapSet.t()}` or `:miss`."
  @spec get(String.t()) :: {:ok, MapSet.t()} | :miss
  def get(user_id) when is_binary(user_id) do
    case safe_lookup(user_id) do
      [{^user_id, permissions, expiry}] ->
        if System.monotonic_time(:second) < expiry do
          {:ok, permissions}
        else
          :ets.delete(@table, user_id)
          :miss
        end

      _ ->
        :miss
    end
  end

  def get(_), do: :miss

  @doc "Store permissions for a user in the cache."
  @spec put(String.t(), MapSet.t()) :: :ok
  def put(user_id, %MapSet{} = permissions) when is_binary(user_id) do
    ttl = ttl_seconds()
    expiry = System.monotonic_time(:second) + ttl
    safe_insert(user_id, permissions, expiry)
    :ok
  end

  def put(_, _), do: :ok

  @doc "Remove a specific user's cached permissions."
  @spec invalidate(String.t()) :: :ok
  def invalidate(user_id) when is_binary(user_id) do
    safe_delete(user_id)
    :ok
  end

  def invalidate(_), do: :ok

  @doc "Clear the entire permission cache."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    safe_delete_all()
    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    table_opts = [:set, :public, :named_table, read_concurrency: true]
    @table = :ets.new(@table, table_opts)

    # Subscribe to RBAC invalidation events
    if pubsub_available?() do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "rbac:cache_invalidation")
    end

    schedule_cleanup()

    {:ok, %{ttl_seconds: Keyword.get(opts, :ttl_seconds, config_ttl())}}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    now = System.monotonic_time(:second)

    :ets.foldl(
      fn {user_id, _perms, expiry}, acc ->
        if now >= expiry, do: :ets.delete(@table, user_id)
        acc
      end,
      :ok,
      @table
    )

    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info({:rbac_cache_invalidate, user_id}, state) do
    invalidate(user_id)
    {:noreply, state}
  end

  def handle_info({:rbac_cache_invalidate_all}, state) do
    invalidate_all()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private Helpers ---

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, @cleanup_interval)
  end

  defp ttl_seconds do
    config_ttl()
  end

  defp config_ttl do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_seconds, @default_ttl_seconds)
  end

  defp pubsub_available? do
    case Process.whereis(ServiceRadar.PubSub) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  # Safe ETS operations that handle table-not-yet-created scenarios
  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp safe_insert(user_id, permissions, expiry) do
    :ets.insert(@table, {user_id, permissions, expiry})
  rescue
    ArgumentError -> :ok
  end

  defp safe_delete(key) do
    :ets.delete(@table, key)
  rescue
    ArgumentError -> :ok
  end

  defp safe_delete_all do
    :ets.delete_all_objects(@table)
  rescue
    ArgumentError -> :ok
  end
end

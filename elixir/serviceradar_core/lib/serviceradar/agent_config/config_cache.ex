defmodule ServiceRadar.AgentConfig.ConfigCache do
  @moduledoc """
  ETS-based cache for compiled agent configurations.

  Provides fast lookups for compiled configs with hash-based change detection.
  Cache is invalidated via NATS events when source resources change.

  ## Cache Key Structure

  Keys are tuples: `{tenant_id, config_type, partition, agent_id}`

  ## Cache Entry Structure

  Values are maps with:
  - `config`: The compiled configuration
  - `hash`: SHA256 hash of the config for change detection
  - `version`: Config version number
  - `cached_at`: When the config was cached
  - `source_ids`: IDs of resources that contributed to this config
  """

  use GenServer

  require Logger

  @table_name :agent_config_cache
  @default_ttl_ms :timer.minutes(5)

  # Client API

  @doc """
  Starts the cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a cached config by key.

  Returns `{:ok, entry}` if found, `:miss` if not cached.
  """
  @spec get(String.t(), atom(), String.t(), String.t() | nil) ::
          {:ok, map()} | :miss
  def get(tenant_id, config_type, partition, agent_id \\ nil) do
    key = cache_key(tenant_id, config_type, partition, agent_id)

    case :ets.lookup(@table_name, key) do
      [{^key, entry, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, entry}
        else
          # Expired - delete and return miss
          :ets.delete(@table_name, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Gets a cached config only if the hash matches.

  Returns `:unchanged` if hash matches (no need to download),
  `{:ok, entry}` if hash differs or not cached,
  `:miss` if not cached.
  """
  @spec get_if_changed(String.t(), atom(), String.t(), String.t() | nil, String.t()) ::
          :unchanged | {:ok, map()} | :miss
  def get_if_changed(tenant_id, config_type, partition, agent_id, current_hash) do
    case get(tenant_id, config_type, partition, agent_id) do
      {:ok, entry} ->
        if entry.hash == current_hash do
          :unchanged
        else
          {:ok, entry}
        end

      :miss ->
        :miss
    end
  end

  @doc """
  Puts a compiled config into the cache.
  """
  @spec put(String.t(), atom(), String.t(), String.t() | nil, map()) :: :ok
  def put(tenant_id, config_type, partition, agent_id, entry, ttl_ms \\ @default_ttl_ms) do
    key = cache_key(tenant_id, config_type, partition, agent_id)
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    :ets.insert(@table_name, {key, entry, expires_at})
    :ok
  end

  @doc """
  Invalidates all cached configs for a tenant and config type.
  """
  @spec invalidate(String.t(), atom()) :: :ok
  def invalidate(tenant_id, config_type) do
    # Match all keys for this tenant and config type
    match_spec = [
      {{{tenant_id, config_type, :_, :_}, :_, :_}, [], [true]}
    ]

    :ets.select_delete(@table_name, match_spec)
    :ok
  end

  @doc """
  Invalidates all cached configs for a tenant.
  """
  @spec invalidate_tenant(String.t()) :: :ok
  def invalidate_tenant(tenant_id) do
    match_spec = [
      {{{tenant_id, :_, :_, :_}, :_, :_}, [], [true]}
    ]

    :ets.select_delete(@table_name, match_spec)
    :ok
  end

  @doc """
  Invalidates a specific cache entry.
  """
  @spec invalidate_key(String.t(), atom(), String.t(), String.t() | nil) :: :ok
  def invalidate_key(tenant_id, config_type, partition, agent_id) do
    key = cache_key(tenant_id, config_type, partition, agent_id)
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Clears all cached configs.
  """
  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Returns cache statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      size: :ets.info(@table_name, :size),
      memory_bytes: :ets.info(@table_name, :memory) * :erlang.system_info(:wordsize)
    }
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

    # Schedule periodic cleanup of expired entries
    schedule_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private helpers

  defp cache_key(tenant_id, config_type, partition, agent_id) do
    {tenant_id, config_type, partition, agent_id}
  end

  defp schedule_cleanup do
    # Run cleanup every minute
    Process.send_after(self(), :cleanup, :timer.minutes(1))
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    # Delete all entries where expires_at < now
    match_spec = [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ]

    deleted = :ets.select_delete(@table_name, match_spec)

    if deleted > 0 do
      Logger.debug("ConfigCache: cleaned up #{deleted} expired entries")
    end
  end
end

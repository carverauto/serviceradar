defmodule ServiceRadar.AgentConfig.ConfigCache do
  @moduledoc """
  ETS-based cache for compiled agent configurations.

  Provides fast lookups for compiled configs with hash-based change detection.
  Cache is invalidated via NATS events when source resources change.

  ## Cache Key Structure

  Keys are tuples: `{config_type, partition, agent_id, scope}`

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
  @spec get(atom(), String.t(), String.t() | nil, term()) ::
          {:ok, map()} | :miss
  def get(config_type, partition, agent_id \\ nil, scope \\ nil) do
    if :ets.whereis(@table_name) == :undefined do
      :miss
    else
      key = cache_key(config_type, partition, agent_id, scope)
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table_name, key) do
        [{^key, entry, expires_at}] when now < expires_at ->
          {:ok, entry}

        [{^key, _entry, _expires_at}] ->
          # Expired - delete and return miss
          :ets.delete(@table_name, key)
          :miss

        [] ->
          :miss
      end
    end
  end

  @doc """
  Gets a cached config only if the hash matches.

  Returns `:unchanged` if hash matches (no need to download),
  `{:ok, entry}` if hash differs or not cached,
  `:miss` if not cached.
  """
  @spec get_if_changed(atom(), String.t(), String.t() | nil, String.t(), term()) ::
          :unchanged | {:ok, map()} | :miss
  def get_if_changed(config_type, partition, agent_id, current_hash, scope \\ nil) do
    case get(config_type, partition, agent_id, scope) do
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
  @spec put(atom(), String.t(), String.t() | nil, map(), term(), integer()) :: :ok
  def put(config_type, partition, agent_id, entry, scope \\ nil, ttl_ms \\ @default_ttl_ms) do
    if :ets.whereis(@table_name) == :undefined do
      :ok
    else
      key = cache_key(config_type, partition, agent_id, scope)
      expires_at = System.monotonic_time(:millisecond) + ttl_ms

      :ets.insert(@table_name, {key, entry, expires_at})
      :ok
    end
  end

  @doc """
  Invalidates all cached configs for a config type.
  """
  @spec invalidate(atom()) :: :ok
  def invalidate(config_type) do
    if :ets.whereis(@table_name) == :undefined do
      :ok
    else
      # Match all keys for this config type
      match_spec = [
        {{{config_type, :_, :_, :_}, :_, :_}, [], [true]}
      ]

      :ets.select_delete(@table_name, match_spec)
      :ok
    end
  end

  @doc """
  Invalidates a specific cache entry.
  """
  @spec invalidate_key(atom(), String.t(), String.t() | nil, term()) :: :ok
  def invalidate_key(config_type, partition, agent_id, scope \\ nil) do
    if :ets.whereis(@table_name) == :undefined do
      :ok
    else
      key = cache_key(config_type, partition, agent_id, scope)
      :ets.delete(@table_name, key)
      :ok
    end
  end

  @doc """
  Clears all cached configs.
  """
  @spec clear_all() :: :ok
  def clear_all do
    if :ets.whereis(@table_name) == :undefined do
      :ok
    else
      :ets.delete_all_objects(@table_name)
      :ok
    end
  end

  @doc """
  Returns cache statistics.
  """
  @spec stats() :: map()
  def stats do
    if :ets.whereis(@table_name) == :undefined do
      %{size: 0, memory_bytes: 0}
    else
      %{
        size: :ets.info(@table_name, :size),
        memory_bytes: :ets.info(@table_name, :memory) * :erlang.system_info(:wordsize)
      }
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table_name, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

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

  defp cache_key(config_type, partition, agent_id, scope) do
    {config_type, partition, agent_id, scope}
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

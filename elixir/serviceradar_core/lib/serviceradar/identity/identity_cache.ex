defmodule ServiceRadar.Identity.IdentityCache do
  @moduledoc """
  ETS-based identity cache with TTL support.

  Caches canonical device records to avoid repeated database lookups
  during sweep processing. Port of Go core's canonical_cache.go.

  ## Configuration

  - Cache TTL: 5 minutes (configurable)
  - Cleanup interval: 1 minute
  - Maximum size: 100,000 entries (soft limit)

  ## Usage

      # Single entry
      IdentityCache.put("192.168.1.100", record)
      record = IdentityCache.get("192.168.1.100")

      # Batch operations
      {hits, misses} = IdentityCache.get_batch(["192.168.1.100", "192.168.1.101"])
  """

  use GenServer

  require Logger

  @table_name :serviceradar_identity_cache
  @default_ttl_ms :timer.minutes(5)
  @cleanup_interval_ms :timer.minutes(1)
  @max_size 100_000

  @type cached_record :: %{
          canonical_device_id: String.t(),
          partition: String.t(),
          metadata_hash: String.t() | nil,
          attributes: map(),
          updated_at: DateTime.t()
        }

  # Client API

  @doc """
  Start the identity cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached record by key (typically IP address).
  """
  @spec get(String.t()) :: cached_record() | nil
  def get(key) when is_binary(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, record, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          emit_cache_telemetry(:hit)
          record
        else
          # Expired - delete and return nil
          :ets.delete(@table_name, key)
          emit_cache_telemetry(:expired)
          nil
        end

      [] ->
        emit_cache_telemetry(:miss)
        nil
    end
  rescue
    ArgumentError ->
      # Table doesn't exist
      nil
  end

  @doc """
  Get multiple cached records at once.

  Returns `{hits, misses}` where:
  - `hits` is a map of key => record for found entries
  - `misses` is a list of keys not found in cache
  """
  @spec get_batch([String.t()]) :: {%{String.t() => cached_record()}, [String.t()]}
  def get_batch(keys) when is_list(keys) do
    now = System.monotonic_time(:millisecond)

    {hits, misses} =
      Enum.reduce(keys, {%{}, []}, fn key, {hits_acc, misses_acc} ->
        case :ets.lookup(@table_name, key) do
          [{^key, record, expires_at}] when expires_at > now ->
            {Map.put(hits_acc, key, record), misses_acc}

          _ ->
            {hits_acc, [key | misses_acc]}
        end
      end)

    emit_batch_telemetry(map_size(hits), length(misses))
    {hits, Enum.reverse(misses)}
  rescue
    ArgumentError ->
      {%{}, keys}
  end

  @doc """
  Store a record in the cache.
  """
  @spec put(String.t(), cached_record(), keyword()) :: :ok
  def put(key, record, opts \\ []) when is_binary(key) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    :ets.insert(@table_name, {key, record, expires_at})
    :ok
  rescue
    ArgumentError ->
      # Table doesn't exist - start was not called or cache is disabled
      :ok
  end

  @doc """
  Store multiple records at once.
  """
  @spec put_batch(%{String.t() => cached_record()}, keyword()) :: :ok
  def put_batch(records, opts \\ []) when is_map(records) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    entries = Enum.map(records, fn {key, record} -> {key, record, expires_at} end)
    :ets.insert(@table_name, entries)
    :ok
  rescue
    ArgumentError ->
      :ok
  end

  @doc """
  Delete a cached entry.
  """
  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    :ets.delete(@table_name, key)
    :ok
  rescue
    ArgumentError ->
      :ok
  end

  @doc """
  Clear all cached entries.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  rescue
    ArgumentError ->
      :ok
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    try do
      info = :ets.info(@table_name)

      %{
        size: info[:size] || 0,
        memory_bytes: (info[:memory] || 0) * :erlang.system_info(:wordsize),
        table_name: @table_name
      }
    rescue
      ArgumentError ->
        %{size: 0, memory_bytes: 0, table_name: @table_name, error: :table_not_found}
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    # Create ETS table
    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule cleanup
    schedule_cleanup()

    Logger.info("Identity cache started with TTL=#{ttl_ms}ms")

    {:ok, %{ttl_ms: ttl_ms}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    maybe_evict_oversized()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    # Use match spec to find expired entries
    match_spec = [{{:"$1", :_, :"$2"}, [{:<, :"$2", now}], [:"$1"]}]
    expired_keys = :ets.select(@table_name, match_spec)

    Enum.each(expired_keys, fn key ->
      :ets.delete(@table_name, key)
    end)

    if length(expired_keys) > 0 do
      Logger.debug("Identity cache: evicted #{length(expired_keys)} expired entries")
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp maybe_evict_oversized do
    case :ets.info(@table_name, :size) do
      size when is_integer(size) and size > @max_size ->
        # Evict oldest 10% of entries
        evict_count = div(size, 10)
        evict_oldest(evict_count)

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp evict_oldest(count) when count > 0 do
    # Get all entries sorted by expiration time (oldest first)
    entries =
      :ets.tab2list(@table_name)
      |> Enum.sort_by(fn {_key, _record, expires_at} -> expires_at end)
      |> Enum.take(count)

    Enum.each(entries, fn {key, _record, _expires_at} ->
      :ets.delete(@table_name, key)
    end)

    Logger.debug("Identity cache: evicted #{count} oldest entries (size limit)")
  end

  defp evict_oldest(_count), do: :ok

  defp emit_cache_telemetry(result) do
    :telemetry.execute(
      [:serviceradar, :identity, :cache],
      %{count: 1},
      %{result: result}
    )
  end

  defp emit_batch_telemetry(hit_count, miss_count) do
    :telemetry.execute(
      [:serviceradar, :identity, :cache, :batch],
      %{hits: hit_count, misses: miss_count, total: hit_count + miss_count},
      %{}
    )
  end
end

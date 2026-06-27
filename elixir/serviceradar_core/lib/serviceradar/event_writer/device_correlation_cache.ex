defmodule ServiceRadar.EventWriter.DeviceCorrelationCache do
  @moduledoc """
  Short-TTL ETS cache for `ServiceRadar.EventWriter.DeviceCorrelation` results.

  Event-writer processors resolve a canonical device UID for *every* incoming
  security event (Falco) and vulnerability finding (Trivy). Each resolution can
  fan out to several TLS database round-trips (agent lookup, workload identity,
  IP/hostname lookups). Under load (e.g. 13 agents) that is one-or-more DB
  queries *per event*, which serialises the processors on the DB connection
  pool.

  This cache keys on the correlation inputs (the resolver candidate) and stores
  the resolved device UID (or a `:negative` sentinel for misses) so repeated
  events for the same device cost a single DB lookup per device, not per event.

  ## Design

  - Backing store: a `:public` named ETS table (`read_concurrency: true`) so
    processors read without a GenServer round-trip.
  - Key: a normalized, order-stable fingerprint of the candidate fields that
    actually drive the lookup. Two events that would resolve identically share a
    cache entry.
  - Value: `{:hit, uid}` for a positive resolution or `:negative` for a
    confirmed miss. Negatives are cached with a shorter TTL so a device that
    later joins inventory is picked up quickly.
  - TTL: device<->identity correlation is stable, so a short TTL (default 30s,
    configurable) keeps correctness drift bounded while absorbing bursts.
  - Size bound: a soft maximum; the periodic cleanup evicts expired entries and,
    if still oversized, the oldest entries.

  The cache is intentionally fail-open: any ETS error (e.g. table missing in a
  stripped-down test process) degrades to a cache miss and the caller performs
  the live lookup.
  """

  use GenServer

  require Logger

  @table_name :serviceradar_device_correlation_cache
  @default_ttl_ms to_timeout(second: 30)
  @negative_ttl_ms to_timeout(second: 10)
  @cleanup_interval_ms to_timeout(second: 30)
  @max_size 50_000

  @type result :: {:hit, String.t()} | :negative

  # Candidate fields that influence the resolved device UID. The order only
  # needs to be stable so the fingerprint is deterministic; the values are
  # normalized before hashing.
  @key_fields [
    :device_uid,
    :agent_id,
    :ip,
    :target_device_ip,
    :partition,
    :metric_name,
    :if_index,
    :pod_uid,
    :pod_namespace,
    :pod_name,
    :container_id,
    :hostname,
    :name
  ]

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Resolve a candidate through the cache, falling back to `resolver` on a miss.

  `resolver` is a zero-arity function that performs the live lookup and returns
  the device UID (a binary) or `nil`. Its result is cached: a binary as a
  positive hit, `nil` as a negative hit (shorter TTL).
  """
  @spec fetch(map(), (-> String.t() | nil)) :: String.t() | nil
  def fetch(candidate, resolver) when is_map(candidate) and is_function(resolver, 0) do
    key = cache_key(candidate)

    case lookup(key) do
      {:hit, uid} ->
        emit_telemetry(:hit)
        uid

      :negative ->
        emit_telemetry(:negative_hit)
        nil

      :miss ->
        emit_telemetry(:miss)
        resolve_and_store(key, resolver)
    end
  end

  @doc "Look up a key without resolving. Returns `{:hit, uid}`, `:negative`, or `:miss`."
  @spec lookup(term()) :: result() | :miss
  def lookup(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      [{^key, _value, _expired}] ->
        :ets.delete(@table_name, key)
        :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError ->
      # Table does not exist (cache not started); degrade to a miss.
      :miss
  end

  @doc "Store a resolution result for a candidate key."
  @spec put(term(), String.t() | nil) :: :ok
  def put(key, uid) do
    {value, ttl_ms} =
      case uid do
        uid when is_binary(uid) and uid != "" -> {{:hit, uid}, ttl_ms()}
        _ -> {:negative, negative_ttl_ms()}
      end

    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table_name, {key, value, expires_at})
    :ok
  rescue
    ArgumentError ->
      :ok
  end

  @doc "Clear all cached entries (primarily for tests)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  rescue
    ArgumentError ->
      :ok
  end

  @doc "Compute the stable cache key for a candidate (exposed for tests)."
  @spec cache_key(map()) :: term()
  def cache_key(candidate) when is_map(candidate) do
    @key_fields
    |> Enum.map(fn field -> normalize(candidate[field] || candidate[to_string(field)]) end)
    |> List.to_tuple()
  end

  @doc "Cache table size."
  @spec size() :: non_neg_integer()
  def size do
    case :ets.info(@table_name, :size) do
      size when is_integer(size) -> size
      _ -> 0
    end
  rescue
    ArgumentError ->
      0
  end

  # Server callbacks

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table_name, @table_name)

    :ets.new(table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()

    {:ok, %{table: table, max_size: Keyword.get(opts, :max_size, @max_size)}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired(state.table)
    maybe_evict_oversized(state.table, state.max_size)
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private functions

  defp resolve_and_store(key, resolver) do
    uid = resolver.()
    put(key, uid)
    uid
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired(table) do
    now = System.monotonic_time(:millisecond)
    match_spec = [{{:"$1", :_, :"$2"}, [{:<, :"$2", now}], [:"$1"]}]

    table
    |> :ets.select(match_spec)
    |> Enum.each(&:ets.delete(table, &1))
  rescue
    ArgumentError ->
      :ok
  end

  defp maybe_evict_oversized(table, max_size) do
    case :ets.info(table, :size) do
      size when is_integer(size) and size > max_size ->
        evict_count = div(size, 10)
        evict_oldest(table, evict_count)

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp evict_oldest(_table, count) when count <= 0, do: :ok

  defp evict_oldest(table, count) do
    match_spec = [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    table
    |> :ets.select(match_spec)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.take(count)
    |> Enum.each(fn {key, _expires_at} -> :ets.delete(table, key) end)
  end

  defp ttl_ms do
    Application.get_env(:serviceradar_core, :device_correlation_cache_ttl_ms, @default_ttl_ms)
  end

  defp negative_ttl_ms do
    Application.get_env(
      :serviceradar_core,
      :device_correlation_cache_negative_ttl_ms,
      @negative_ttl_ms
    )
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize(_), do: nil

  defp emit_telemetry(result) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :device_correlation, :cache],
      %{count: 1},
      %{result: result}
    )
  end
end

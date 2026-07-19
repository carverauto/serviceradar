defmodule ServiceRadar.EventWriter.ProviderCidrCache do
  @moduledoc """
  Legacy cross-batch ETS cache for FlowEnrichment hosting-provider lookups.

  **Deprecated path.** Prefer `ServiceRadar.PrefixTags.ProviderSource` and
  `:prefix_tag_provider_trie_enabled` (default true). This module remains for
  rollback when the trie flag is disabled; `Application` only starts it in that
  case.

  Historical context: FlowEnrichment resolved a hosting provider for every flow
  src/dst IP via GiST LPM against `platform.netflow_provider_cidrs` (~388k
  CIDRs). The per-batch Process-dict cache only deduped within one batch, so
  this ETS layer absorbed cross-batch repeats. The in-memory prefix-tag trie
  removes the SQL hot path entirely when loaded.
  """

  use GenServer

  require Logger

  @table_name :serviceradar_provider_cidr_cache
  @default_ttl_ms to_timeout(hour: 6)
  @negative_ttl_ms to_timeout(minute: 30)
  @cleanup_interval_ms to_timeout(minute: 5)
  @max_size 200_000

  @type result :: {:hit, String.t()} | :negative

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Resolve {snapshot_id, ip_key} through the cache, falling back to `resolver`
  (a zero-arity fun returning a provider binary or nil) on a miss.
  """
  @spec fetch(term(), String.t(), (-> String.t() | nil)) :: String.t() | nil
  def fetch(snapshot_id, ip_key, resolver) when is_binary(ip_key) and is_function(resolver, 0) do
    key = {snapshot_id, ip_key}

    case lookup(key) do
      {:hit, provider} ->
        emit_telemetry(:hit)
        provider

      :negative ->
        emit_telemetry(:negative_hit)
        nil

      :miss ->
        emit_telemetry(:miss)
        provider = resolver.()
        put(key, provider)
        provider
    end
  end

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
    ArgumentError -> :miss
  end

  @spec put(term(), String.t() | nil) :: :ok
  def put(key, provider) do
    {value, ttl_ms} =
      case provider do
        p when is_binary(p) and p != "" -> {{:hit, p}, ttl_ms()}
        _ -> {:negative, negative_ttl_ms()}
      end

    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table_name, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec size() :: non_neg_integer()
  def size do
    case :ets.info(@table_name, :size) do
      n when is_integer(n) -> n
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table_name, @table_name)

    :ets.new(table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])

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

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)

  defp cleanup_expired(table) do
    now = System.monotonic_time(:millisecond)
    match_spec = [{{:"$1", :_, :"$2"}, [{:<, :"$2", now}], [:"$1"]}]
    table |> :ets.select(match_spec) |> Enum.each(&:ets.delete(table, &1))
  rescue
    ArgumentError -> :ok
  end

  defp maybe_evict_oversized(table, max_size) do
    case :ets.info(table, :size) do
      size when is_integer(size) and size > max_size ->
        evict_oldest(table, div(size, 10))

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp evict_oldest(_table, count) when count <= 0, do: :ok

  defp evict_oldest(table, count) do
    match_spec = [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    table
    |> :ets.select(match_spec)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.take(count)
    |> Enum.each(fn {key, _exp} -> :ets.delete(table, key) end)
  end

  defp ttl_ms,
    do: Application.get_env(:serviceradar_core, :provider_cidr_cache_ttl_ms, @default_ttl_ms)

  defp negative_ttl_ms,
    do:
      Application.get_env(
        :serviceradar_core,
        :provider_cidr_cache_negative_ttl_ms,
        @negative_ttl_ms
      )

  defp emit_telemetry(result) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :provider_cidr, :cache],
      %{count: 1},
      %{result: result}
    )
  end
end

defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Runtime do
  @moduledoc false

  alias ServiceRadar.Observability.AnomalyDetection.ContextCheckpoint
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.ShardEvaluator
  alias ServiceRadar.Observability.CausalReasoner

  @spec setup(keyword(), map()) :: map()
  def setup(opts, config) do
    shard_count = positive_int(Keyword.get(opts, :shard_count), config.default_shard_count)

    resources =
      List.to_tuple(Enum.map(1..shard_count, fn _ -> CausalReasoner.new_shard_state() end))

    workers = ShardEvaluator.start_workers(resources)

    reset_table(config.seen_table)
    reset_table(config.seen_events_table)
    reset_table(config.open_series_table)

    :persistent_term.put(config.resources_key, resources)
    :persistent_term.put(config.workers_key, workers)
    :persistent_term.put(config.shard_count_key, shard_count)
    :persistent_term.put(config.opts_key, opts)

    %{
      shard_count: shard_count,
      resources: resources,
      workers: workers,
      max_series: positive_int(Keyword.get(opts, :max_series), config.default_max_series),
      event_ttl_ms: positive_int(Keyword.get(opts, :event_ttl_ms), config.default_event_ttl_ms),
      max_seen_events:
        positive_int(Keyword.get(opts, :max_seen_events), config.default_max_seen_events),
      event_prune_interval_ms:
        positive_int(
          Keyword.get(opts, :event_prune_interval_ms),
          config.default_event_prune_interval_ms
        ),
      eviction_budget:
        positive_int(Keyword.get(opts, :eviction_budget), config.default_eviction_budget),
      last_event_prune_ms: System.monotonic_time(:millisecond),
      checkpoint_store: Keyword.get(opts, :checkpoint_store, ContextCheckpoint),
      checkpoint_opts: Keyword.get(opts, :checkpoint_opts, []),
      checkpoint_flush_interval_ms:
        Keyword.get(opts, :checkpoint_flush_interval_ms, checkpoint_flush_interval_ms()),
      checkpoint_pending_series: MapSet.new(),
      checkpoint_flush_ref: nil
    }
  end

  @spec teardown(map()) :: :ok
  def teardown(config) do
    ShardEvaluator.stop_workers(:persistent_term.get(config.workers_key, nil))
    :persistent_term.erase(config.resources_key)
    :persistent_term.erase(config.workers_key)
    :persistent_term.erase(config.shard_count_key)
    :persistent_term.erase(config.opts_key)

    delete_table(config.seen_table)
    delete_table(config.seen_events_table)
    delete_table(config.open_series_table)

    :ok
  end

  def resources(config), do: :persistent_term.get(config.resources_key)
  def workers(config), do: :persistent_term.get(config.workers_key)
  def opts(config), do: :persistent_term.get(config.opts_key, [])

  def shard_count(config) do
    :persistent_term.get(
      config.shard_count_key,
      Application.get_env(
        :serviceradar_core,
        :anomaly_detection_shard_count,
        config.default_shard_count
      )
    )
  end

  def positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  def positive_int(_value, fallback), do: fallback

  def checkpoint_flush_interval_ms do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Observability.AnomalyDetection, [])
    |> Keyword.get(:checkpoint_flush_interval_ms, 1_000)
  end

  defp reset_table(table_name) do
    delete_table(table_name)

    :ets.new(table_name, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  defp delete_table(table_name) do
    case :ets.whereis(table_name) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end
  end
end

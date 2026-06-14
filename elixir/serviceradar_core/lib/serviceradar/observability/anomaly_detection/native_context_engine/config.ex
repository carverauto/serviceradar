defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Config do
  @moduledoc false

  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine

  @default_shard_count System.schedulers_online()
  @default_window_size 300
  @default_min_samples 30
  @default_n_sigma 3.0
  @default_confirm_slots 5

  # The default is a total engine bound. It must be high enough that eviction is
  # a guardrail, not the routine path, for ~50k agents with many metric series.
  @default_max_series 6_000_000

  # Keep dedup tokens for at least the JetStream redelivery horizon. Capacity is
  # only a safety ceiling; TTL is the primary retention rule.
  @default_event_ttl_ms 3_600_000
  @default_max_seen_events 5_000_000
  @default_event_prune_interval_ms 60_000
  @default_eviction_budget 10_000
  @default_shard_eval_timeout_ms 30_000

  @resources_key {NativeContextEngine, :resources}
  @workers_key {NativeContextEngine, :workers}
  @shard_count_key {NativeContextEngine, :shard_count}
  @opts_key {NativeContextEngine, :opts}
  @seen_table NativeContextEngine.SeenSeries
  @seen_events_table NativeContextEngine.SeenEvents
  @open_series_table NativeContextEngine.OpenSeries

  @spec runtime() :: map()
  def runtime do
    %{
      resources_key: @resources_key,
      workers_key: @workers_key,
      shard_count_key: @shard_count_key,
      opts_key: @opts_key,
      seen_table: @seen_table,
      seen_events_table: @seen_events_table,
      open_series_table: @open_series_table,
      default_shard_count: @default_shard_count,
      default_max_series: @default_max_series,
      default_event_ttl_ms: @default_event_ttl_ms,
      default_max_seen_events: @default_max_seen_events,
      default_event_prune_interval_ms: @default_event_prune_interval_ms,
      default_eviction_budget: @default_eviction_budget
    }
  end

  def seen_table, do: @seen_table
  def seen_events_table, do: @seen_events_table
  def open_series_table, do: @open_series_table
  def workers_key, do: @workers_key

  @spec base_context() :: map()
  def base_context do
    %{
      baseline: [],
      window_tail: [],
      rolling_acc: nil,
      min_samples: @default_min_samples,
      window_size: @default_window_size,
      n_sigma: @default_n_sigma,
      confirm_slots: @default_confirm_slots,
      consecutive_anomalous: 0
    }
  end

  @spec context_overrides(keyword()) :: map()
  def context_overrides(opts) do
    opts
    |> Keyword.take([
      :rolling_enabled,
      :seasonal_enabled,
      :trend_enabled,
      :min_samples,
      :seasonal_min_samples,
      :trend_min_samples,
      :window_size,
      :n_sigma,
      :seasonal_n_sigma,
      :trend_n_sigma,
      :confirm_slots,
      :seasonal_sensitivity
    ])
    |> Map.new()
  end

  @spec shard_eval_timeout_ms(keyword()) :: pos_integer()
  def shard_eval_timeout_ms(opts) do
    opts
    |> Keyword.get(:shard_eval_timeout_ms, @default_shard_eval_timeout_ms)
    |> positive_int(@default_shard_eval_timeout_ms)
  end

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, fallback), do: fallback
end

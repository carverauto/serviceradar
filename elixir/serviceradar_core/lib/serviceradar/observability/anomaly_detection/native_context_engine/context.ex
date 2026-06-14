defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Context do
  @moduledoc false

  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Config
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Runtime

  @spec evaluation() :: map()
  def evaluation do
    opts = opts()

    %{
      shard_count: shard_count(),
      opts: opts,
      resources: resources(),
      workers: workers(),
      seen_events_table: Config.seen_events_table(),
      open_series_table: Config.open_series_table(),
      retention_tables: retention_tables(),
      preparation: preparation(opts),
      shard_eval_timeout_ms: Config.shard_eval_timeout_ms(opts)
    }
  end

  @spec preparation(keyword()) :: map()
  def preparation(opts \\ opts()) do
    %{
      seen_table: Config.seen_table(),
      seen_events_table: Config.seen_events_table(),
      checkpoint_context: checkpoint(opts),
      base_context: Config.base_context(),
      context_overrides: Config.context_overrides(opts)
    }
  end

  @spec checkpoint(keyword()) :: map()
  def checkpoint(opts \\ opts()) do
    %{
      resources: resources(),
      opts: opts,
      seen_events_table: Config.seen_events_table(),
      open_series_table: Config.open_series_table()
    }
  end

  @spec retention_tables() :: map()
  def retention_tables do
    %{
      seen: Config.seen_table(),
      seen_events: Config.seen_events_table(),
      open_series: Config.open_series_table()
    }
  end

  def resources, do: Runtime.resources(Config.runtime())
  def workers, do: Runtime.workers(Config.runtime())
  def opts, do: Runtime.opts(Config.runtime())
  def shard_count, do: Runtime.shard_count(Config.runtime())
end

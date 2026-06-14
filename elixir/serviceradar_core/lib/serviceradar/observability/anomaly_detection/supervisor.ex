defmodule ServiceRadar.Observability.AnomalyDetection.Supervisor do
  @moduledoc """
  Supervisor for the real-time anomaly detection consumer.
  """

  use Supervisor

  alias ServiceRadar.Observability.AnomalyDetection.Config
  alias ServiceRadar.Observability.AnomalyDetection.ContextEngine
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine
  alias ServiceRadar.Observability.AnomalyDetection.Pipeline
  alias ServiceRadar.Observability.AnomalyDetection.ShardedContextEngine

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Config.load()

    Logger.info("Starting anomaly analysis supervisor",
      enabled: config.enabled,
      context_engine: inspect(config.context_engine),
      streams: length(config.streams),
      enabled_subjects: Enum.join(config.enabled_subjects, ",")
    )

    Supervisor.init(
      engine_children(config) ++ [{Pipeline, config}],
      strategy: :one_for_one
    )
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{running: false}

      pid ->
        children = Supervisor.which_children(pid)

        %{
          running: true,
          pid: pid,
          children:
            Enum.map(children, fn {id, child_pid, type, _modules} ->
              %{
                id: id,
                pid: child_pid,
                type: type,
                alive: is_pid(child_pid) and Process.alive?(child_pid)
              }
            end)
        }
    end
  end

  # Thread the scale-engine bounds (#3818) into the engine child specs. These
  # were previously read from opts inside the engines but never wired here, so
  # they were dead knobs frozen at the engines' compile-time defaults. Both
  # scale engines accept these keys in their opts; ShardedContextEngine ignores
  # the seen-events knobs (it keeps per-series event sets), so passing them is
  # harmless. The ContextEngine/catch-all cases are intentionally unchanged.
  defp engine_children(%Config{context_engine: NativeContextEngine} = config) do
    [{NativeContextEngine, scale_engine_opts(config)}]
  end

  defp engine_children(%Config{context_engine: ShardedContextEngine} = config) do
    [{ShardedContextEngine, scale_engine_opts(config)}]
  end

  defp engine_children(%Config{context_engine: ContextEngine}), do: []
  defp engine_children(_config), do: []

  defp scale_engine_opts(%Config{} = config) do
    # Drop nil bounds so each scale engine falls back to its OWN default (the
    # bounds use different units per engine — see Config's @default_* note). An
    # operator override (ANOMALY_ANALYSIS_*) sets a non-nil value that is passed
    # through and interpreted in the selected engine's units.
    Enum.reject(
      [
        shard_count: config.shard_count,
        max_series: config.max_series,
        max_seen_events: config.max_seen_events,
        event_ttl_ms: config.event_ttl_ms,
        event_prune_interval_ms: config.event_prune_interval_ms
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end
end

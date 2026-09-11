defmodule ServiceRadar.Observability.ProductionSchedule do
  @moduledoc """
  Shared builder for the anomaly/observability Oban cron entries and worker
  config that every production deployment must schedule.

  Both `serviceradar_core/config/runtime.exs` and the deployed release's
  `serviceradar_core_elx/config/runtime.exs` build their Oban crontab from
  this module, so the two config trees cannot drift apart (drift here is how
  the seasonal/episode workers silently vanished from production). Functions
  take a `System.get_env/2`-shaped fetcher so the env gating stays testable
  without mutating the process environment.

  To add a production cron entry: add a `defp <name>_entries/1` clause that
  returns `[]` or `[{cron_expression, WorkerModule, opts}]` and list it in
  `cron_entries/1`.
  """

  alias ServiceRadar.Observability.AnomalyAddonConfigProjector
  alias ServiceRadar.Observability.AnomalyAlertLivenessWorker
  alias ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker
  alias ServiceRadar.Observability.AnomalyIngestSilenceWorker
  alias ServiceRadar.Observability.ResolveStaleAnomaliesWorker
  alias ServiceRadar.Observability.SeasonalBaselineFreshnessWorker
  alias ServiceRadar.Observability.SeasonalDisposition

  @type env_fetch :: (String.t(), String.t() | nil -> String.t() | nil)
  @type cron_entry ::
          {String.t(), module()} | {String.t(), module(), keyword()}

  @truthy ["1", "true", "yes", "on"]
  @falsy ["0", "false", "no", "off"]

  @doc """
  The anomaly/observability cron entries production must run, honoring the
  operator env gates and cron overrides.
  """
  @spec cron_entries(env_fetch()) :: [cron_entry()]
  def cron_entries(fetch \\ &System.get_env/2) do
    Enum.concat([
      seasonal_disposition_entries(fetch),
      seasonal_edge_baseline_entries(fetch),
      anomaly_edge_config_projection_entries(fetch),
      anomaly_episode_stale_close_entries(fetch),
      resolve_stale_anomalies_entries(fetch),
      anomaly_alert_liveness_entries(fetch),
      anomaly_ingest_silence_entries(fetch),
      seasonal_baseline_freshness_entries(fetch)
    ])
  end

  @doc """
  Runtime options for `ServiceRadar.Observability.SeasonalDisposition.Worker`
  (`config :serviceradar_core, SeasonalDisposition.Worker, ...`). Settings-UI
  overrides still win at execution time via `AnomalyConfigRuntime`.
  """
  @spec seasonal_disposition_worker_config(env_fetch()) :: keyword()
  def seasonal_disposition_worker_config(fetch \\ &System.get_env/2) do
    [
      enabled: seasonal_disposition_enabled?(fetch),
      emit_verdicts?: truthy?(fetch, "SERVICERADAR_SEASONAL_DISPOSITION_EMIT_VERDICTS", "true"),
      seasonal_n_sigma: float_env(fetch, "SERVICERADAR_SEASONAL_DISPOSITION_N_SIGMA", 3.0),
      min_bucket_samples:
        int_env(fetch, "SERVICERADAR_SEASONAL_DISPOSITION_MIN_BUCKET_SAMPLES", 4),
      # Two consecutive hourly buckets: a single bucket at z just over the 3.0
      # threshold is noise (demo median breach score 3.19), and one hour of
      # delay is cheap for a slow central tier.
      confirm_slots: int_env(fetch, "SERVICERADAR_SEASONAL_DISPOSITION_CONFIRM_SLOTS", 2)
    ]
  end

  @doc """
  Top-level `:serviceradar_core` keys the scheduled workers read at runtime.
  Only keys the operator explicitly set via env are returned, so the worker
  modules' own defaults stay authoritative when unset.
  """
  @spec app_env(env_fetch()) :: keyword()
  def app_env(fetch \\ &System.get_env/2) do
    Enum.reject(
      [
        stale_anomaly_resolve_hours:
          positive_int(fetch, "SERVICERADAR_STALE_ANOMALY_RESOLVE_HOURS"),
        anomaly_episode_stale_after_minutes:
          positive_int(fetch, "SERVICERADAR_ANOMALY_EPISODE_STALE_AFTER_MINUTES"),
        central_seasonal_episode_stale_after_minutes:
          positive_int(fetch, "SERVICERADAR_CENTRAL_SEASONAL_STALE_AFTER_MINUTES"),
        stale_anomaly_episode_freshness_hours:
          positive_int(fetch, "SERVICERADAR_STALE_ANOMALY_EPISODE_FRESHNESS_HOURS"),
        stale_anomaly_episode_liveness_check:
          boolean(fetch, "SERVICERADAR_STALE_ANOMALY_EPISODE_LIVENESS_CHECK"),
        anomaly_silence_hours: positive_int(fetch, "SERVICERADAR_ANOMALY_SILENCE_HOURS"),
        seasonal_baseline_freshness_hours:
          positive_int(fetch, "SERVICERADAR_SEASONAL_BASELINE_FRESHNESS_HOURS")
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  @doc """
  The `SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS` comma-separated env
  value parsed into the capacity forecasting worker's
  `:default_source_opt_ins` list. Both runtime config trees call this so the
  CSV parsing cannot drift; the worker validates the names against
  `CapacityForecasting.Source.opt_in_names/0` at run time.
  """
  @spec capacity_source_opt_ins(env_fetch()) :: [String.t()]
  def capacity_source_opt_ins(fetch \\ &System.get_env/2) do
    (fetch.("SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS", "") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp seasonal_disposition_entries(fetch) do
    if seasonal_disposition_enabled?(fetch) do
      [
        {fetch.("SERVICERADAR_SEASONAL_DISPOSITION_CRON", "47 * * * *"),
         SeasonalDisposition.Worker, args: %{"trigger" => "cron"}, queue: :maintenance}
      ]
    else
      []
    end
  end

  # Push the freshly built hour-of-week baselines onto the anomaly add-on
  # profile params a few minutes after the disposition pass refreshes the
  # profile rows.
  defp seasonal_edge_baseline_entries(fetch) do
    if seasonal_edge_baseline_enabled?(fetch) do
      [
        {fetch.("SERVICERADAR_SEASONAL_EDGE_BASELINE_CRON", "53 * * * *"),
         SeasonalDisposition.EdgeBaselineProducer,
         args: %{"trigger" => "cron"}, queue: :maintenance}
      ]
    else
      []
    end
  end

  defp anomaly_edge_config_projection_entries(fetch) do
    if truthy?(fetch, "SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION", "true") do
      [
        {fetch.("SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION_CRON", "57 * * * *"),
         AnomalyAddonConfigProjector, args: %{"trigger" => "cron"}, queue: :maintenance}
      ]
    else
      []
    end
  end

  defp anomaly_episode_stale_close_entries(_fetch) do
    [{"*/5 * * * *", AnomalyEpisodeStaleCloseWorker, queue: :maintenance}]
  end

  defp resolve_stale_anomalies_entries(_fetch) do
    [{"*/30 * * * *", ResolveStaleAnomaliesWorker, queue: :maintenance}]
  end

  # Liveness tripwires (design D7): scheduled alongside the pipeline they
  # watch so a deployment cannot run the anomaly pipeline without them.
  defp anomaly_alert_liveness_entries(fetch) do
    if truthy?(fetch, "SERVICERADAR_ANOMALY_LIVENESS_ENABLED", "true") do
      [
        {fetch.("SERVICERADAR_ANOMALY_LIVENESS_CRON", "23 */6 * * *"), AnomalyAlertLivenessWorker,
         queue: :maintenance}
      ]
    else
      []
    end
  end

  defp anomaly_ingest_silence_entries(fetch) do
    if truthy?(fetch, "SERVICERADAR_ANOMALY_SILENCE_TRIPWIRE_ENABLED", "true") do
      [
        {fetch.("SERVICERADAR_ANOMALY_SILENCE_TRIPWIRE_CRON", "7 * * * *"),
         AnomalyIngestSilenceWorker, queue: :maintenance}
      ]
    else
      []
    end
  end

  # The freshness tripwire inherits the producer's env gates: disabling the
  # edge-baseline cron silences the tripwire instead of tripping it forever.
  defp seasonal_baseline_freshness_entries(fetch) do
    if seasonal_edge_baseline_enabled?(fetch) and
         truthy?(fetch, "SERVICERADAR_SEASONAL_BASELINE_TRIPWIRE_ENABLED", "true") do
      [
        {fetch.("SERVICERADAR_SEASONAL_BASELINE_TRIPWIRE_CRON", "37 * * * *"),
         SeasonalBaselineFreshnessWorker, queue: :maintenance}
      ]
    else
      []
    end
  end

  defp seasonal_disposition_enabled?(fetch) do
    truthy?(fetch, "SERVICERADAR_SEASONAL_DISPOSITION_ENABLED", "true")
  end

  defp seasonal_edge_baseline_enabled?(fetch) do
    seasonal_disposition_enabled?(fetch) and
      truthy?(fetch, "SERVICERADAR_SEASONAL_EDGE_BASELINE_ENABLED", "true")
  end

  defp truthy?(fetch, name, default) do
    String.downcase(fetch.(name, default) || default) in @truthy
  end

  defp positive_int(fetch, name) do
    case fetch.(name, nil) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 ->
            int

          _ ->
            raise ArgumentError, "invalid positive integer for #{name}: #{inspect(value)}"
        end
    end
  end

  defp boolean(fetch, name) do
    case fetch.(name, nil) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case String.downcase(value) do
          truthy when truthy in @truthy -> true
          falsy when falsy in @falsy -> false
          _ -> raise ArgumentError, "invalid boolean for #{name}: #{inspect(value)}"
        end
    end
  end

  # `String.to_float/1` rejects integer-formatted values like "3" and
  # `String.to_integer/1` raises on any garbage — either would brick release
  # boot the moment runtime.exs evaluates this module. Parse tolerantly and
  # fail fast with the env var named so the operator can fix the value.
  defp float_env(fetch, name, default) do
    case fetch.(name, nil) do
      nil ->
        default

      "" ->
        default

      value ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> raise ArgumentError, "invalid float for #{name}: #{inspect(value)}"
        end
    end
  end

  defp int_env(fetch, name, default) do
    case fetch.(name, nil) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> raise ArgumentError, "invalid integer for #{name}: #{inspect(value)}"
        end
    end
  end
end

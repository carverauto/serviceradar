defmodule ServiceRadar.Observability.AnomalyIngestSilenceWorker do
  @moduledoc """
  Tripwire for anomaly ingest going dark while metric ingest stays alive
  (design D7).

  Zero anomaly-detection findings (OCSF `class_uid = 2004` with
  `metadata.service_radar.source_type = 'anomaly_detection'`) for
  `:anomaly_silence_hours` (default #{6}h) while `platform.timeseries_metrics`
  received rows in the last hour is *necessary* but not *sufficient* evidence
  of a dead pipeline: a healthy quiet fleet produces zero confirmed anomalies
  by design, and episodes-mode folds heartbeats into `platform.anomaly_episodes`
  instead of new 2004 rows. So the tripwire only records an unhealthy `:core`
  health event (`anomaly-ingest-silence`) via `TripwireHealth` when ALL of the
  following hold: metric ingest is alive, no 2004 anomaly-detection row landed
  in the window, no open anomaly episode was seen (`last_seen_at`) in the
  window, and no anomaly add-on reported a fresh `running` heartbeat in
  `platform.addon_statuses`. Silence while detectors are demonstrably running
  is healthy quiet; silence with no detector heartbeat means the pipeline died
  somewhere between the add-on and the event writer. When metric ingest is
  also silent the worker stays quiet — that outage is the metric pipeline's
  alarm to raise.

  Synthetic alert-liveness events cannot mask real silence: they carry no
  `service_radar.source_type`, so the predicate ignores them. Query failures
  fail open (log, skip the run) so a degraded database cannot add a false
  anomaly-pipeline alarm on top of itself.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Observability.TripwireHealth
  alias ServiceRadar.Repo

  require Logger

  @check_name "anomaly-ingest-silence"
  @default_silence_hours 6
  @metrics_alive_window_hours 1
  @addon_heartbeat_freshness_minutes 15

  @anomaly_rows_sql """
  SELECT EXISTS (
    SELECT 1
    FROM platform.ocsf_events
    WHERE time >= $1::timestamptz
      AND class_uid = 2004
      AND metadata #>> '{service_radar,source_type}' = 'anomaly_detection'
  )
  """

  @metrics_alive_sql """
  SELECT EXISTS (
    SELECT 1
    FROM platform.timeseries_metrics
    WHERE "timestamp" >= $1::timestamptz
  )
  """

  # Episodes-mode folds ongoing anomalies into episode updates rather than new
  # 2004 rows, so a recently seen open episode is proof of a live pipeline.
  @open_episode_sql """
  SELECT EXISTS (
    SELECT 1
    FROM platform.anomaly_episodes
    WHERE status = 'open'
      AND last_seen_at >= $1::timestamp(6)
  )
  """

  # A fresh `running` heartbeat from any anomaly add-on means the detectors
  # are demonstrably alive: zero findings then is healthy quiet, not silence.
  @addon_heartbeat_sql """
  SELECT EXISTS (
    SELECT 1
    FROM platform.addon_statuses
    WHERE addon_id = 'anomaly'
      AND state = 'running'
      AND last_health_at >= $1::timestamp(6)
  )
  """

  @impl Oban.Worker
  def perform(_job), do: run()

  @doc """
  Evaluate the tripwire once.

  Injectables for tests: `:repo` (module with `query/2`), `:health_recorder`
  (arity 3), and `:now`.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    repo = Keyword.get(opts, :repo, Repo)
    health = Keyword.get(opts, :health_recorder, &TripwireHealth.record/3)
    hours = silence_hours()

    metrics_cutoff = DateTime.add(now, -@metrics_alive_window_hours * 3600, :second)
    anomaly_cutoff = DateTime.add(now, -hours * 3600, :second)
    heartbeat_cutoff = DateTime.add(now, -@addon_heartbeat_freshness_minutes * 60, :second)

    case exists?(repo, @metrics_alive_sql, metrics_cutoff) do
      {:ok, false} ->
        # Metric ingest is dead too — a different alarm's job; no verdict.
        :ok

      {:ok, true} ->
        case anomaly_pipeline_alive?(repo, anomaly_cutoff, heartbeat_cutoff) do
          {:ok, alive?} -> record_verdict(alive?, hours, health)
          {:error, reason} -> skip_run(reason)
        end

      {:error, reason} ->
        skip_run(reason)
    end
  end

  # Any one sign of life clears the tripwire: a 2004 anomaly-detection row, a
  # recently seen open episode, or a fresh running add-on heartbeat. Only the
  # conjunction of all three silences is a dead pipeline.
  defp anomaly_pipeline_alive?(repo, anomaly_cutoff, heartbeat_cutoff) do
    with {:ok, false} <- exists?(repo, @anomaly_rows_sql, anomaly_cutoff),
         {:ok, false} <- exists?(repo, @open_episode_sql, DateTime.to_naive(anomaly_cutoff)),
         {:ok, false} <- exists?(repo, @addon_heartbeat_sql, DateTime.to_naive(heartbeat_cutoff)) do
      {:ok, false}
    else
      {:ok, true} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_verdict(true, _hours, health) do
    health.(@check_name, true, %{})
    :ok
  end

  defp record_verdict(false, hours, health) do
    Logger.error(
      "No anomaly-detection findings or live episodes for #{hours}h and no running " <>
        "anomaly add-on heartbeat while metric ingest is alive"
    )

    health.(@check_name, false, %{"silence_hours" => hours})
    :ok
  end

  defp skip_run(reason) do
    Logger.warning(
      "Anomaly ingest silence tripwire query failed; skipping this run: " <> inspect(reason)
    )

    :ok
  end

  defp exists?(repo, sql, cutoff) do
    case repo.query(sql, [cutoff]) do
      {:ok, %{rows: [[value]]}} when is_boolean(value) -> {:ok, value}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc "The anomaly-ingest silence window (hours) before the tripwire fires."
  @spec silence_hours() :: pos_integer()
  def silence_hours do
    case Application.get_env(:serviceradar_core, :anomaly_silence_hours) do
      hours when is_integer(hours) and hours > 0 -> hours
      _ -> @default_silence_hours
    end
  end
end

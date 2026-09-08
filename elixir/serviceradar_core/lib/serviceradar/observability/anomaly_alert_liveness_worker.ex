defmodule ServiceRadar.Observability.AnomalyAlertLivenessWorker do
  @moduledoc """
  Scheduled tripwire around the anomaly alert path (design D7).

  Runs `AnomalyAlertLivenessCheck` — synthetic open → persisted alert →
  synthetic clear → resolved → internal artifacts discarded, plus the seeded
  rule-contract assertion — and
  records the outcome as a `:core` health event (`anomaly-alert-liveness`)
  via `TripwireHealth`, so a silent rule-shape or engine regression becomes
  operator-visible between deploys. The mix task
  (`mix serviceradar.anomaly_alert_liveness`) remains the deploy-gate entry
  point.

  The scheduled run uses a deterministic series key (distinct from the mix
  task's per-run unique keys), so an interrupted run leaves at most one open
  synthetic alert and the next run — or the best-effort clear in the failure
  path, or the resolve-stale sweep — converges it. A failed check records the
  unhealthy event and returns `:ok`: the health event is the signal and the
  next cron run is the retry.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Observability.AnomalyAlertLivenessCheck
  alias ServiceRadar.Observability.TripwireHealth

  require Logger

  @check_name "anomaly-alert-liveness"
  @series_key "synthetic:anomaly-alert-liveness:tripwire"

  @impl Oban.Worker
  def perform(_job), do: run()

  @doc """
  Execute the liveness check and record its outcome as a health event.

  Injectables for tests: `:check` (arity 1, the liveness check), `:cleanup`
  (arity 1, best-effort clear for the synthetic series), `:health_recorder`
  (arity 3), and `:series_key`.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    check = Keyword.get(opts, :check, &AnomalyAlertLivenessCheck.run/1)
    cleanup = Keyword.get(opts, :cleanup, &AnomalyAlertLivenessCheck.emit_clear/1)
    health = Keyword.get(opts, :health_recorder, &TripwireHealth.record/3)
    series_key = Keyword.get(opts, :series_key, @series_key)

    case run_check(check, series_key) do
      {:ok, result} ->
        health.(@check_name, true, %{
          "series_key" => result.series_key
        })

        :ok

      {:error, reason} ->
        Logger.error("Anomaly alert liveness check failed", reason: inspect(reason))
        best_effort_cleanup(cleanup, series_key)
        health.(@check_name, false, %{"reason" => inspect(reason)})
        :ok
    end
  end

  defp run_check(check, series_key) do
    check.(series_key: series_key)
  rescue
    error -> {:error, error}
  end

  # A crashed run can strand an open synthetic alert; an unmatched clear is a
  # no-op, so always try. The resolve-stale sweep is the final backstop.
  defp best_effort_cleanup(cleanup, series_key) do
    cleanup.(series_key)
    :ok
  rescue
    error ->
      Logger.warning("Anomaly alert liveness cleanup failed", reason: inspect(error))
      :ok
  end
end

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

  The scheduled run only probes while alert evaluation is `:active`. In
  `:prepared` or `:draining` mode admission refuses the synthetic events, so the
  probe could only fail, and core already reports that evaluation is off. The
  run is skipped with a debug log and records no health event, so a deployment
  that has not activated evaluation does not read as a broken anomaly path. The
  mix task calls the check directly and still fails in those modes.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Observability.AnomalyAlertLivenessCheck
  alias ServiceRadar.Observability.StatefulAlertEngine.Rollout
  alias ServiceRadar.Observability.TripwireHealth

  require Logger

  @check_name "anomaly-alert-liveness"
  @series_key "synthetic:anomaly-alert-liveness:tripwire"
  @transient_pg_codes [
    :lock_not_available,
    :query_canceled,
    :deadlock_detected,
    :serialization_failure,
    :too_many_connections,
    :admin_shutdown,
    :cannot_connect_now
  ]

  @impl Oban.Worker
  def perform(_job), do: run()

  @doc """
  Execute the liveness check and record its outcome as a health event, or skip
  it when alert evaluation is not `:active`.

  Injectables for tests: `:check` (arity 1, the liveness check), `:cleanup`
  (arity 1, best-effort clear for the synthetic series), `:health_recorder`
  (arity 3), and `:series_key`.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    case Rollout.mode() do
      :active ->
        run_active(opts)

      mode ->
        Logger.debug("Anomaly alert liveness check skipped: alert evaluation is not active",
          alert_evaluation_mode: mode
        )

        :ok
    end
  end

  defp run_active(opts) do
    check = Keyword.get(opts, :check, &AnomalyAlertLivenessCheck.run/1)
    cleanup = Keyword.get(opts, :cleanup, &AnomalyAlertLivenessCheck.emit_clear/1)
    health = Keyword.get(opts, :health_recorder, &TripwireHealth.record/3)
    series_key = Keyword.get(opts, :series_key, @series_key)

    case run_check(check, series_key) do
      {:ok, result} ->
        record_healthy(health, result)

      {:error, reason} ->
        retry_or_record_unhealthy(check, cleanup, health, series_key, reason)
    end
  end

  defp retry_or_record_unhealthy(check, cleanup, health, series_key, reason) do
    if transient_failure?(reason) do
      Logger.warning("Anomaly alert liveness check hit transient failure; retrying once",
        reason: inspect(reason)
      )

      best_effort_cleanup(cleanup, series_key)

      case run_check(check, series_key) do
        {:ok, result} ->
          record_healthy(health, result)

        {:error, retry_reason} ->
          record_unhealthy(cleanup, health, series_key, retry_reason)
      end
    else
      record_unhealthy(cleanup, health, series_key, reason)
    end
  end

  defp record_healthy(health, result) do
    health.(@check_name, true, %{
      "series_key" => result.series_key
    })

    :ok
  end

  defp record_unhealthy(cleanup, health, series_key, reason) do
    Logger.error("Anomaly alert liveness check failed", reason: inspect(reason))
    best_effort_cleanup(cleanup, series_key)
    health.(@check_name, false, %{"reason" => inspect(reason)})
    :ok
  end

  defp transient_failure?(:anomaly_alert_liveness_timeout), do: true
  defp transient_failure?(:alert_evaluation_not_activated), do: true
  defp transient_failure?(:alert_evaluation_draining), do: true
  defp transient_failure?(:alert_evaluation_capability_unavailable), do: true
  defp transient_failure?(:alert_evaluation_peer_not_ready), do: true
  defp transient_failure?({:overloaded, _}), do: true

  defp transient_failure?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in @transient_pg_codes

  defp transient_failure?(%DBConnection.ConnectionError{}), do: true
  defp transient_failure?({:store_unavailable, reason}), do: transient_failure?(reason)
  defp transient_failure?({:rule_load_failed, _}), do: true
  defp transient_failure?({:alert_lookup_failed, _}), do: true
  defp transient_failure?({:synthetic_artifact_cleanup_failed, _, _}), do: true
  defp transient_failure?(_reason), do: false

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

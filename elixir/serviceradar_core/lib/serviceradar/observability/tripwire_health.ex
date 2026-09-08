defmodule ServiceRadar.Observability.TripwireHealth do
  @moduledoc """
  Records anomaly-pipeline tripwire outcomes as operational health events.

  The liveness tripwires (`AnomalyAlertLivenessWorker`,
  `AnomalyIngestSilenceWorker`, `SeasonalBaselineFreshnessWorker`) surface
  through the existing infrastructure health mechanism —
  `HealthTracker.record_health_check/3` with `entity_type: :core` and a
  per-check entity id — so outcomes land on the health timeline, broadcast
  over `HealthPubSub`, and publish a `health.state_change` OCSF log that
  alert rules can match. The tracker dedupes unchanged states, so a
  persistently failing check records one transition, not one row per run.

  Recording is best-effort: a health-write failure logs a warning and returns
  `:ok`, so a broken health surface can never crash the tripwire that is
  trying to report through it.
  """

  alias ServiceRadar.Infrastructure.HealthTracker

  require Logger

  @spec record(String.t(), boolean(), map()) :: :ok
  def record(check_name, healthy?, metadata \\ %{}) when is_binary(check_name) do
    case HealthTracker.record_health_check(:core, check_name,
           healthy: healthy?,
           metadata: metadata
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_record_failure(check_name, healthy?, reason)
    end
  rescue
    error -> log_record_failure(check_name, healthy?, error)
  end

  defp log_record_failure(check_name, healthy?, reason) do
    Logger.warning("Failed to record tripwire health event",
      check: check_name,
      healthy: healthy?,
      reason: inspect(reason)
    )

    :ok
  end
end

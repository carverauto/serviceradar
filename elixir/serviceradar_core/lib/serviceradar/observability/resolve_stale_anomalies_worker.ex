defmodule ServiceRadar.Observability.ResolveStaleAnomaliesWorker do
  @moduledoc """
  Periodically auto-resolves stale edge-spike anomaly alerts.

  The edge anomaly add-on opens an alert (via the `causal_prediction_health_finding`
  stateful rule) when a series breaches, and a later `anomaly_clear` record resolves
  it. But if the monitored series goes silent — an ephemeral pod destroyed, a host
  decommissioned, or the series evicted at the add-on's per-host memory cap — no
  `anomaly_clear` ever arrives, so the alert sits open until manual cleanup.

  This worker resolves any such alert that has had no matching record for
  `:stale_anomaly_resolve_hours` (default #{6}h), routing through
  `StatefulAlertEngine.resolve_stale_anomalies/3` so the engine's in-memory snapshot
  and the Postgres `alert_id` stay consistent (a later re-anomaly opens a fresh
  alert rather than being suppressed by a stale snapshot).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias ServiceRadar.Observability.StatefulAlertEngine

  # The rule the edge anomaly add-on's `anomaly_open` records drive (rule_seeder).
  @rule_name "causal_prediction_health_finding"
  @default_stale_hours 6

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    hours = stale_hours()
    cutoff = DateTime.add(now, -hours * 3600, :second)

    case StatefulAlertEngine.resolve_stale_anomalies(@rule_name, cutoff, now) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info(
          "Auto-resolved #{count} stale edge-spike anomaly alert(s) " <>
            "(no matching record for #{hours}h)"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The silence window (hours) after which an open edge-spike alert auto-resolves."
  @spec stale_hours() :: pos_integer()
  def stale_hours do
    case Application.get_env(:serviceradar_core, :stale_anomaly_resolve_hours) do
      hours when is_integer(hours) and hours > 0 -> hours
      _ -> @default_stale_hours
    end
  end
end

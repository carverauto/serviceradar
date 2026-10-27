defmodule ServiceRadar.Observability.PluginResultAttemptPruneWorker do
  @moduledoc """
  Daily retention for `platform.plugin_result_ingestion_attempts`.

  Deletes active, non-quarantined attempt rows (`state = 'active'`) whose
  `last_attempt_at` is older than `PluginResultQuarantine.active_retention_days/0`
  (default 7 days), and quarantined rows (`state = 'quarantined'`) whose
  `quarantined_at` (falling back to `last_attempt_at`) is older than
  `PluginResultQuarantine.quarantine_retention_days/0` (default 30 days).

  Deletes run in primary-key batches via `PluginResultQuarantine.prune/1` and
  report pruned row counts on the `:retained_plugin_result` ingestion lane
  (`result_ingestion_events_attempt_pruned`).

  Scheduled by `ServiceRadar.Observability.ProductionSchedule.cron_entries/1`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  alias ServiceRadar.Observability.PluginResultQuarantine

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case PluginResultQuarantine.prune() do
      {:ok, %{deleted: deleted, batches: batches}} ->
        if deleted > 0 do
          Logger.info("Pruned plugin result ingestion attempts",
            deleted: deleted,
            batches: batches,
            active_retention_days: PluginResultQuarantine.active_retention_days(),
            quarantine_retention_days: PluginResultQuarantine.quarantine_retention_days()
          )
        end

        :ok

      {:error, _reason} = error ->
        error
    end
  end
end

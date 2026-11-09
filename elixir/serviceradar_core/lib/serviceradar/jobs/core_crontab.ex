defmodule ServiceRadar.Jobs.CoreCrontab do
  @moduledoc """
  Shared builder for the core Oban crontab.

  Both `serviceradar_core/config/runtime.exs` and the shipped release's
  `serviceradar_core_elx/config/runtime.exs` build their `Oban.Plugins.Cron`
  crontab from this module so the two config trees cannot drift apart.
  """

  alias ServiceRadar.Camera.RelaySessionReaperWorker
  alias ServiceRadar.ColdTier.Exporter, as: ColdTierExporter
  alias ServiceRadar.ColdTier.Pruner, as: ColdTierPruner
  alias ServiceRadar.CompositeChecks.TickWorker
  alias ServiceRadar.Credentials.BrokerRetentionWorker
  alias ServiceRadar.Edge.EdgeLedgerRetentionWorker
  alias ServiceRadar.Edge.ManagedCertificateReconcileWorker
  alias ServiceRadar.Edge.RemoteAccessRecordingReaperWorker
  alias ServiceRadar.Edge.RemoteAccessVersionRetentionWorker
  alias ServiceRadar.EventWriter.ExposureSnapshotMaintenanceWorker
  alias ServiceRadar.EventWriter.ExposureTerminalCompactionWorker
  alias ServiceRadar.Identity.SAMLAssertionCleanupWorker
  alias ServiceRadar.Inventory.Availability.ExpiryWorker
  alias ServiceRadar.Inventory.Availability.PinSilenceWorker
  alias ServiceRadar.Inventory.Availability.ResolverWorker
  alias ServiceRadar.Inventory.ExposureDeviceRefreshWorker
  alias ServiceRadar.Inventory.ExposureDimensionRefreshWorker
  alias ServiceRadar.Inventory.ExposurePublicationPrepareWorker
  alias ServiceRadar.Inventory.ExposureReconciliationWorker
  alias ServiceRadar.Jobs.AlertsRetentionWorker
  alias ServiceRadar.Jobs.PruneStaleAgentsWorker
  alias ServiceRadar.Jobs.ReapStalePeriodicJobsWorker
  alias ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker
  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker
  alias ServiceRadar.Jobs.RootSpanRatioWorker
  alias ServiceRadar.Jobs.SecurityEventsRetentionWorker
  alias ServiceRadar.Notifications.DispatchSchedule
  alias ServiceRadar.ObjectStore.RetentionWorker, as: ObjectStoreRetentionWorker
  alias ServiceRadar.Observability.ApiEventsRetentionWorker
  alias ServiceRadar.Observability.CapacityForecasting.Worker, as: CapacityForecastingWorker
  alias ServiceRadar.Observability.DataRetentionWorker
  alias ServiceRadar.Observability.PluginServiceStateReconcileWorker
  alias ServiceRadar.Observability.ProductionSchedule
  alias ServiceRadar.Observability.StatefulAlertEngine.RecoveryWorker
  alias ServiceRadar.Observability.StatefulEvaluationLedgerPruneWorker
  alias ServiceRadar.Security.AuditVersionRetentionWorker
  alias ServiceRadar.SweepJobs.ExecutionReaperWorker
  alias ServiceRadar.SweepJobs.LeasePassWorker

  @type env_fetch :: (String.t(), String.t() | nil -> String.t() | nil)
  @type cron_entry ::
          {String.t(), module()} | {String.t(), module(), keyword()}

  @truthy ["1", "true", "yes", "on"]

  @doc """
  Builds the complete Oban crontab for core releases, honoring operator
  environment overrides and feature gates.
  """
  @spec cron_entries(env_fetch()) :: [cron_entry()]
  def cron_entries(fetch \\ &System.get_env/2) when is_function(fetch, 2) do
    [
      {env_or_default(fetch, "TRACE_SUMMARIES_REFRESH_CRON", "*/2 * * * *"),
       RefreshTraceSummariesWorker, queue: :maintenance},
      {"*/5 * * * *", RootSpanRatioWorker, queue: :maintenance},
      {"*/2 * * * *", ReapStalePeriodicJobsWorker, queue: :maintenance},
      {"17 * * * *", PruneStaleAgentsWorker, queue: :maintenance},
      {"*/2 * * * *", RefreshLogsSeverityStatsWorker, queue: :maintenance},
      {"* * * * *", ExposureDeviceRefreshWorker, queue: :maintenance},
      {"* * * * *", ExposureSnapshotMaintenanceWorker, queue: :maintenance},
      {"17 5 * * *", ExposureTerminalCompactionWorker, queue: :maintenance},
      {"17 * * * *", ExposurePublicationPrepareWorker, queue: :maintenance},
      {"7 4 * * *", ExposureDimensionRefreshWorker, queue: :maintenance},
      {"37 4 * * *", ExposureReconciliationWorker, queue: :maintenance},
      {env_or_default(fetch, "SERVICERADAR_OBSERVABILITY_RETENTION_CRON", "17 3 * * *"),
       DataRetentionWorker, queue: :maintenance},
      {"47 * * * *", ColdTierExporter, queue: :maintenance},
      {"23 4 * * *", ColdTierPruner, queue: :maintenance},
      {env_or_default(fetch, "ALERT_RETENTION_CRON", "15 * * * *"), AlertsRetentionWorker,
       queue: :maintenance},
      {"* * * * *", RecoveryWorker, queue: :alert_recovery},
      {"37 3 * * *", StatefulEvaluationLedgerPruneWorker, queue: :maintenance},
      {env_or_default(fetch, "SERVICERADAR_CREDENTIAL_BROKER_RETENTION_CRON", "43 3 * * *"),
       BrokerRetentionWorker, queue: :maintenance},
      {"23 3 * * *", SecurityEventsRetentionWorker, queue: :maintenance},
      {"51 3 * * *", ApiEventsRetentionWorker, queue: :maintenance},
      {"53 3 * * *", AuditVersionRetentionWorker, queue: :maintenance},
      {"29 * * * *", SAMLAssertionCleanupWorker, queue: :maintenance},
      {"*/10 * * * *", RemoteAccessRecordingReaperWorker, queue: :maintenance},
      {"31 3 * * *", RemoteAccessVersionRetentionWorker, queue: :maintenance},
      {"41 * * * *", EdgeLedgerRetentionWorker, queue: :maintenance},
      {"*/2 * * * *", RelaySessionReaperWorker, queue: :maintenance},
      {"*/5 * * * *", ExecutionReaperWorker, queue: :maintenance},
      {"*/5 * * * *", PluginServiceStateReconcileWorker, queue: :maintenance},
      {"* * * * *", ResolverWorker, queue: :maintenance},
      {"* * * * *", ExpiryWorker, queue: :maintenance},
      {"* * * * *", PinSilenceWorker, queue: :maintenance},
      {"* * * * *", ManagedCertificateReconcileWorker, queue: :maintenance},
      {"* * * * *", TickWorker, queue: :monitoring},
      {"*/5 * * * *", LeasePassWorker, queue: :maintenance}
    ] ++
      object_store_retention_entries(fetch) ++
      capacity_forecasting_entries(fetch) ++
      ProductionSchedule.cron_entries(fetch) ++
      DispatchSchedule.cron_entries(fetch)
  end

  defp object_store_retention_entries(fetch) do
    if truthy?(fetch, "OBJECT_STORE_RETENTION_ENABLED", "true") do
      [
        {env_or_default(fetch, "OBJECT_STORE_RETENTION_CRON", "0 3 * * *"),
         ObjectStoreRetentionWorker, args: %{"enabled" => true}, queue: :maintenance}
      ]
    else
      []
    end
  end

  defp capacity_forecasting_entries(fetch) do
    if truthy?(fetch, "SERVICERADAR_CAPACITY_FORECASTING_ENABLED", "true") do
      [
        {env_or_default(fetch, "SERVICERADAR_CAPACITY_FORECASTING_CRON", "41 * * * *"),
         CapacityForecastingWorker, args: %{"trigger" => "cron"}, queue: :maintenance}
      ]
    else
      []
    end
  end

  defp truthy?(fetch, name, default) do
    String.downcase(env_or_default(fetch, name, default)) in @truthy
  end

  defp env_or_default(fetch, name, default) do
    case fetch.(name, default) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end
end

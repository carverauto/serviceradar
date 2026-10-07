defmodule ServiceRadar.Observability do
  @moduledoc """
  The Observability domain manages logs, metrics, and traces.

  This domain is responsible for:
  - Log ingestion and querying (OCSF-aligned schema)
  - Time-series metrics storage
  - Trace/span data for distributed tracing
  - OpenTelemetry trace summaries

  ## Resources

  - `ServiceRadar.Observability.Log` - Log entries (OCSF-aligned)
  - `ServiceRadar.Observability.ApiEvent` - Centralized AshEvents audit log for
    API-first mutable resources (see `add-ash-events-audit-log` design doc)
  - `ServiceRadar.Observability.TimeseriesMetric` - Generic time-series metrics
    (including device sysmon, stored as `sysmon.*` metric types)
  - `ServiceRadar.Observability.OtelTraceSummary` - OpenTelemetry trace summaries
  - `ServiceRadar.Observability.OtelServiceCatalogEntry` - OTel services seen per signal

  ## TimescaleDB Integration

  Metrics tables use TimescaleDB hypertables for efficient time-series storage.
  The timestamp column is the primary dimension for partitioning.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain,
      AshAdmin.Domain
    ]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Observability.Log
    resource ServiceRadar.Observability.ApiEvent
    resource ServiceRadar.Observability.ZenRule
    resource ServiceRadar.Observability.ZenRuleTemplate
    resource ServiceRadar.Observability.EventRule
    resource ServiceRadar.Observability.LogPromotionRule
    resource ServiceRadar.Observability.LogPromotionRuleTemplate
    resource ServiceRadar.Observability.StatefulAlertRule
    resource ServiceRadar.Observability.StatefulAlertRuleTemplate
    resource ServiceRadar.Observability.StatefulAlertRuleState
    resource ServiceRadar.Observability.AlertEvaluationLane
    resource ServiceRadar.Observability.AlertEvaluationWork
    resource ServiceRadar.Observability.AlertEvaluationReceipt
    resource ServiceRadar.Observability.StatefulEvaluationLedger
    resource ServiceRadar.Observability.SeasonalDisposition.ChronologicalState
    resource ServiceRadar.Observability.StatefulAlertRuleHistory
    resource ServiceRadar.Observability.IpGeoEnrichmentCache
    resource ServiceRadar.Observability.IpRdnsCache
    resource ServiceRadar.Observability.IpIpinfoCache
    resource ServiceRadar.Observability.ThreatIntelIndicator
    resource ServiceRadar.Observability.ThreatIntelSourceObject
    resource ServiceRadar.Observability.ThreatIntelSyncStatus
    resource ServiceRadar.Observability.TrivyReport
    resource ServiceRadar.Observability.TrivyFinding
    resource ServiceRadar.Observability.OTXRetrohuntRun
    resource ServiceRadar.Observability.OTXRetrohuntFinding
    resource ServiceRadar.Observability.IpThreatIntelCache
    resource ServiceRadar.Observability.NetflowPortScanFlag
    resource ServiceRadar.Observability.NetflowPortAnomalyFlag
    resource ServiceRadar.Observability.NetflowSettings
    resource ServiceRadar.Observability.BmpSettings
    resource ServiceRadar.Observability.MtrSettings
    resource ServiceRadar.Observability.WarehouseRetentionSetting
    resource ServiceRadar.Observability.NetflowLocalCidr
    resource ServiceRadar.Observability.NetflowAppClassificationRule
    resource ServiceRadar.Observability.NetflowExporterCache
    resource ServiceRadar.Observability.NetflowInterfaceCache
    resource ServiceRadar.Observability.NetflowProviderDatasetSnapshot
    resource ServiceRadar.Observability.NetflowProviderCidr
    resource ServiceRadar.Observability.NetflowOuiDatasetSnapshot
    resource ServiceRadar.Observability.NetflowOuiPrefix
    resource ServiceRadar.Observability.AnomalyDetectionConfig
    resource ServiceRadar.Observability.AnomalyEpisode
    resource ServiceRadar.Observability.CapacityForecastConfig
    # Metrics resources - all map to TimescaleDB hypertables with migrate?: false
    # matching Go schema exactly
    resource ServiceRadar.Observability.TimeseriesMetric
    resource ServiceRadar.Observability.ServiceStatus
    resource ServiceRadar.Observability.ServiceState
    resource ServiceRadar.Observability.TimeseriesMetricHourly
    resource ServiceRadar.Observability.TimeseriesMetricInterfaceHourly
    resource ServiceRadar.Observability.TimeseriesMetricDiskHourly
    resource ServiceRadar.Observability.CapacityForecast
    # MTR resources - map to TimescaleDB hypertables with migrate?: false
    resource ServiceRadar.Observability.MtrTrace
    resource ServiceRadar.Observability.MtrHop
    resource ServiceRadar.Observability.MtrPolicy
    resource ServiceRadar.Observability.MtrDispatchWindow
    # OTel resources - these map to existing TimescaleDB hypertables/views
    # with migrate?: false so Ash doesn't try to manage the schema
    resource ServiceRadar.Observability.OtelMetric
    resource ServiceRadar.Observability.OtelMetricPoint
    resource ServiceRadar.Observability.OtelTrace
    resource ServiceRadar.Observability.OtelTraceSummary
    # Control-plane catalog of OTel services; schema owned by this resource.
    resource ServiceRadar.Observability.OtelServiceCatalogEntry
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

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
  - `ServiceRadar.Observability.TimeseriesMetric` - Generic time-series metrics
  - `ServiceRadar.Observability.CpuMetric` - CPU utilization metrics
  - `ServiceRadar.Observability.MemoryMetric` - Memory usage metrics
  - `ServiceRadar.Observability.DiskMetric` - Disk usage metrics
  - `ServiceRadar.Observability.OtelTraceSummary` - OpenTelemetry trace summaries

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
    resource ServiceRadar.Observability.LogPromotionRule
    # Metrics resources - all map to TimescaleDB hypertables with migrate?: false
    # matching Go schema exactly
    resource ServiceRadar.Observability.TimeseriesMetric
    resource ServiceRadar.Observability.CpuMetric
    resource ServiceRadar.Observability.MemoryMetric
    resource ServiceRadar.Observability.DiskMetric
    resource ServiceRadar.Observability.ProcessMetric
    # OTel resources - these map to existing TimescaleDB hypertables/views
    # with migrate?: false so Ash doesn't try to manage the schema
    resource ServiceRadar.Observability.OtelMetric
    resource ServiceRadar.Observability.OtelTrace
    resource ServiceRadar.Observability.OtelTraceSummary
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

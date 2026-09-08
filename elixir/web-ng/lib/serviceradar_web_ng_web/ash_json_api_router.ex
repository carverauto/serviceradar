defmodule ServiceRadarWebNGWeb.AshJsonApiRouter do
  @moduledoc """
  Router for Ash JSON:API endpoints.

  Mounts all Ash domain JSON:API routes at /api/v2.

  ## Available Endpoints

  ### Inventory Domain
  - GET /api/v2/devices - List devices
  - GET /api/v2/devices/:uid - Get device by UID

  ### Infrastructure Domain
  - GET /api/v2/gateways - List gateways
  - GET /api/v2/gateways/:id - Get gateway by ID
  - GET /api/v2/gateways/active - List active gateways
  - GET /api/v2/agents - List agents
  - GET /api/v2/agents/:uid - Get agent by UID
  - GET /api/v2/agents/by-gateway/:gateway_id - List agents by gateway

  ### Monitoring Domain
  - GET /api/v2/service-checks - List service checks
  - GET /api/v2/service-checks/:id - Get service check by ID
  - GET /api/v2/service-checks/enabled - List enabled checks
  - GET /api/v2/service-checks/failing - List failing checks
  - POST /api/v2/service-checks - Create service check
  - PATCH /api/v2/service-checks/:id - Update service check
  - GET /api/v2/alerts - List alerts
  - GET /api/v2/alerts/:id - Get alert by ID
  - GET /api/v2/alerts/active - List active alerts
  - GET /api/v2/alerts/pending - List pending alerts
  - POST /api/v2/alerts - Trigger new alert
  - PATCH /api/v2/alerts/:id/acknowledge - Acknowledge alert
  - PATCH /api/v2/alerts/:id/resolve - Resolve alert

  ### Observability Domain
  - GET /api/v2/stateful-alert-rules - List alert rules
  - GET /api/v2/stateful-alert-rules/:id - Get alert rule by ID
  - GET /api/v2/stateful-alert-rules/active - List active alert rules
  - POST /api/v2/stateful-alert-rules - Create alert rule
  - PATCH /api/v2/stateful-alert-rules/:id - Update alert rule
  - DELETE /api/v2/stateful-alert-rules/:id - Delete alert rule

  The following 19 resources also carry pre-existing, read-only `json_api`
  blocks and become reachable now that `ServiceRadar.Observability` is
  mounted (each is gated by `system_bypass()` + `read_viewer_plus()`, i.e.
  requires an authenticated actor with at least the `:viewer` role — a nil
  actor reads nothing from any of them):
  - GET /api/v2/logs - List logs
  - GET /api/v2/service_status - List service status records
  - GET /api/v2/capacity_forecasts - List capacity forecasts
  - GET /api/v2/cpu_cluster_metrics - List CPU cluster metrics
  - GET /api/v2/otel_metrics - List OTel metrics
  - GET /api/v2/otel_metric_points - List OTel metric points
  - GET /api/v2/otel_traces - List OTel traces
  - GET /api/v2/otel_trace_summaries - List OTel trace summaries
  - GET /api/v2/cpu_metrics - List raw CPU metrics
  - GET /api/v2/memory_metrics - List raw memory metrics
  - GET /api/v2/disk_metrics - List raw disk metrics
  - GET /api/v2/process_metrics - List raw process metrics
  - GET /api/v2/timeseries_metrics - List raw timeseries metrics
  - GET /api/v2/cpu_metrics_hourly - List hourly CPU metric rollups
  - GET /api/v2/memory_metrics_hourly - List hourly memory metric rollups
  - GET /api/v2/disk_metrics_hourly - List hourly disk metric rollups
  - GET /api/v2/process_metrics_hourly - List hourly process metric rollups
  - GET /api/v2/timeseries_metrics_hourly - List hourly timeseries metric rollups
  - GET /api/v2/timeseries_metrics_interface_hourly - List hourly per-interface timeseries metric rollups

  Node probe actions and notification routes are defined by the resources'
  JSON:API DSL. Consult the generated OpenAPI document below for their paths,
  request schemas, and supported operations.

  ## Authentication

  Access is authorized by each resource's Ash policies. The actor is extracted
  from the connection (session cookie or bearer token) and passed to Ash for
  policy enforcement; a nil actor reads nothing.

  ## OpenAPI spec

  The OpenAPI document is NOT served by this router. It is served — behind
  authentication — by `ServiceRadarWebNGWeb.Api.OpenApiV2Controller` at
  `/api/v2/open_api`, so the interactive SwaggerUI console and the spec itself
  are gated to logged-in users.
  """

  # `open_api_title`/`open_api_version` are pure spec metadata for `spec/0` — they
  # do NOT serve a route (only the `open_api:` option, deliberately absent here to
  # keep the endpoint gated, would). They must match `Api.OpenApiV2Controller` so
  # the committed artifact at `priv/static/openapi.json` (rendered from `spec/0` by
  # `mix serviceradar.openapi.dump` and consumed by the developer portal) stays in
  # sync with what `/api/v2/open_api` serves.
  use AshJsonApi.Router,
    domains: [
      ServiceRadar.Inventory,
      ServiceRadar.Infrastructure,
      ServiceRadar.Monitoring,
      ServiceRadar.Notifications,
      ServiceRadar.Observability
    ],
    open_api_title: "ServiceRadar API",
    open_api_version: "2.0.0"
end

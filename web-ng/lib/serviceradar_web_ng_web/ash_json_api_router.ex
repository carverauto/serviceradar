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

  ## Authentication

  All endpoints require authentication. The actor is extracted from the
  connection and passed to Ash for policy enforcement.
  """

  use AshJsonApi.Router,
    domains: [
      ServiceRadar.Inventory,
      ServiceRadar.Infrastructure,
      ServiceRadar.Monitoring
    ],
    open_api: "/open_api",
    open_api_title: "ServiceRadar API",
    open_api_version: "2.0.0"
end

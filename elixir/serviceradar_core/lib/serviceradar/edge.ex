defmodule ServiceRadar.Edge do
  @moduledoc """
  The Edge domain manages edge onboarding packages, events, and NATS credentials.

  This domain is responsible for:
  - Edge onboarding package creation and delivery
  - Package lifecycle management (state machine)
  - Onboarding event tracking
  - Download token management
  - NATS credential issuance and lifecycle for collectors
  - Collector package management (flowgger, trapd, netflow, otel)
  - Edge site management (NATS leaf deployments)

  ## Resources

  - `ServiceRadar.Edge.OnboardingPackage` - Edge deployment packages
  - `ServiceRadar.Edge.OnboardingEvent` - Package lifecycle events
  - `ServiceRadar.Edge.TenantCA` - Per-tenant certificate authorities
  - `ServiceRadar.Edge.NatsCredential` - NATS credentials for collectors
  - `ServiceRadar.Edge.CollectorPackage` - Collector-specific deployment packages
  - `ServiceRadar.Edge.EdgeSite` - Edge deployment locations
  - `ServiceRadar.Edge.NatsLeafServer` - NATS leaf server configurations

  ## Package State Machine

  Onboarding packages follow a defined lifecycle:
  - `created` -> `downloaded` -> `installed` -> `expired`
  - `created` -> `revoked` (manual action)

  State transitions are enforced by AshStateMachine and integrated
  with AshOban for expiration jobs.
  """

  use Ash.Domain,
    extensions: [
      # AshJsonApi.Domain,
      AshAdmin.Domain
    ]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Edge.OnboardingPackage
    resource ServiceRadar.Edge.OnboardingEvent
    resource ServiceRadar.Edge.TenantCA
    resource ServiceRadar.Edge.NatsCredential
    resource ServiceRadar.Edge.CollectorPackage
    resource ServiceRadar.Edge.EdgeSite
    resource ServiceRadar.Edge.NatsLeafServer
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

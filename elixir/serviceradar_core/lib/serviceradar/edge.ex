defmodule ServiceRadar.Edge do
  @moduledoc """
  The Edge domain manages edge onboarding packages and events.

  This domain is responsible for:
  - Edge onboarding package creation and delivery
  - Package lifecycle management (state machine)
  - Onboarding event tracking
  - Download token management

  ## Resources

  - `ServiceRadar.Edge.OnboardingPackage` - Edge deployment packages
  - `ServiceRadar.Edge.OnboardingEvent` - Package lifecycle events

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
    show? true
  end

  authorization do
    require_actor? false
    authorize :by_default
  end

  resources do
    resource ServiceRadar.Edge.OnboardingPackage
    resource ServiceRadar.Edge.OnboardingEvent
  end
end

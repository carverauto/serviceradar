defmodule ServiceRadar.DuskProfiles do
  @moduledoc """
  Domain for Dusk blockchain node monitoring profile management.

  This domain manages dusk configurations via DuskProfile resources.

  ## Dusk Profiles

  Profiles define how to monitor Dusk blockchain nodes:
  - Node WebSocket address for monitoring
  - Connection timeout settings
  - SRQL `target_query` for device targeting (e.g., "in:devices tags.role:dusk-node")

  ## Profile Resolution (via SrqlTargetResolver)

  When an agent requests its dusk configuration, the profile is resolved:
  1. SRQL targeting: Profiles with `target_query` evaluated by priority (highest first)
  2. Default profile for the deployment (fallback)
  3. No profile = dusk monitoring disabled

  ## Integration with Agents

  Dusk monitoring is embedded directly in the agent (no separate checker binary).
  Configuration is delivered via the GetConfig RPC and applied at runtime.
  If no profile is found or configured, dusk monitoring is disabled.
  """

  use Ash.Domain, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.DuskProfiles.DuskProfile
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

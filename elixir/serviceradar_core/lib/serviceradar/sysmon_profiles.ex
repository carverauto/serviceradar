defmodule ServiceRadar.SysmonProfiles do
  @moduledoc """
  Domain for system monitoring profile management.

  This domain manages sysmon configurations via SysmonProfile resources.

  ## Sysmon Profiles

  Profiles define what system metrics to collect and how frequently:
  - CPU, memory, disk, network, and process metrics
  - Configurable sample intervals
  - Alert thresholds for each metric type
  - SRQL `target_query` for device targeting (e.g., "in:devices tags.role:database")

  ## Profile Resolution (via SrqlTargetResolver)

  When an agent requests its sysmon configuration, the profile is resolved:
  1. SRQL targeting: Profiles with `target_query` evaluated by priority (highest first)
  2. Default profile for the deployment (fallback)

  ## Integration with Agents

  Sysmon is embedded directly in the agent (no separate checker binary).
  Configuration is delivered via the GetConfig RPC and applied at runtime.
  """

  use Ash.Domain, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.SysmonProfiles.SysmonProfile
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

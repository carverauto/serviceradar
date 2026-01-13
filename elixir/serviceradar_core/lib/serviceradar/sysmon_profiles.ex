defmodule ServiceRadar.SysmonProfiles do
  @moduledoc """
  Domain for system monitoring profile management.

  This domain manages sysmon configurations including:
  - SysmonProfile: Reusable system monitoring profiles (admin-managed templates)
  - SysmonProfileAssignment: Assignment of profiles to devices or tags

  ## Sysmon Profiles

  Profiles define what system metrics to collect and how frequently:
  - CPU, memory, disk, network, and process metrics
  - Configurable sample intervals
  - Alert thresholds for each metric type

  ## Profile Resolution

  When an agent requests its sysmon configuration, the profile is resolved in order:
  1. Device-specific assignment (highest priority)
  2. Tag-based assignment (priority-ordered)
  3. Default profile for the tenant

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
    resource ServiceRadar.SysmonProfiles.SysmonProfileAssignment
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

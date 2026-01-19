defmodule ServiceRadar.SweepJobs do
  @moduledoc """
  Domain for network sweep job management.

  This domain manages sweep configurations including:
  - SweepProfile: Reusable scanner profiles (admin-managed templates)
  - SweepGroup: User-configured sweep groups with custom schedules and device targeting
  - SweepGroupExecution: Execution tracking per group
  - SweepHostResult: Per-host results from sweep executions

  ## Sweep Groups

  Sweep groups are the primary organizational unit. Each group has:
  - Its own schedule (interval or cron)
  - Device targeting criteria (DSL-based)
  - Optional profile inheritance for scan settings
  - Assignment to partition and optionally specific agent

  ## Device Targeting

  Groups use SRQL stored in `target_query` to target devices, for example:

      "in:devices discovery_sources:armis ip:10.0.0.0/8"
  """

  use Ash.Domain, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.SweepJobs.SweepProfile
    resource ServiceRadar.SweepJobs.SweepGroup
    resource ServiceRadar.SweepJobs.SweepGroupExecution
    resource ServiceRadar.SweepJobs.SweepHostResult
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

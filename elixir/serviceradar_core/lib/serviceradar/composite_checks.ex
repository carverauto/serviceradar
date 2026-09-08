defmodule ServiceRadar.CompositeChecks do
  @moduledoc """
  Composite service checks: operator-authored verdicts derived from signals that
  other subsystems already produce.

  A composite check scopes a device population with SRQL, declares named typed
  inputs (per-agent reachability, device metadata facts), and maps combinations
  of those inputs onto operator-defined verdicts through an ordered decision
  table. Composite checks never probe — they read `device_agent_availability`
  and device metadata and derive an answer.
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.CompositeChecks.CompositeCheck
    resource ServiceRadar.CompositeChecks.CompositeCheckInput
    resource ServiceRadar.CompositeChecks.CompositeCheckRule
    resource ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
    resource ServiceRadar.CompositeChecks.ValidationRun
    resource ServiceRadar.CompositeChecks.ValidationRunDevice
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundScheduler do
  @moduledoc """
  Ensures recurring Armis northbound scheduling reconciliation stays seeded when
  Oban is available.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [
      ServiceRadar.Integrations.ArmisNorthboundScheduleWorker,
      ServiceRadar.Integrations.ArmisNorthboundConflictAuditWorker
    ],
    label: "Armis northbound scheduler",
    tick: :schedule,
    named_start?: true,
    include_worker?: true
end

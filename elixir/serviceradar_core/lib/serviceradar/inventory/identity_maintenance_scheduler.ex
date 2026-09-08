defmodule ServiceRadar.Inventory.IdentityMaintenanceScheduler do
  @moduledoc """
  Ensures identity maintenance jobs stay scheduled when Oban is available:

    * `ServiceRadar.Inventory.AgentLinkRepairWorker` — periodic
      agent-to-device link repair
    * `ServiceRadar.Inventory.DeviceIdentifierGcWorker` — daily identifier
      TTL garbage collection
    * `ServiceRadar.Jobs.ScheduleHealthWorker` — `ng_job_schedules`
      staleness alerting
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [
      ServiceRadar.Inventory.AgentLinkRepairWorker,
      ServiceRadar.Inventory.DeviceIdentifierGcWorker,
      ServiceRadar.Jobs.ScheduleHealthWorker
    ],
    label: "Identity maintenance scheduling"
end

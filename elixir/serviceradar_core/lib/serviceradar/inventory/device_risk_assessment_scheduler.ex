defmodule ServiceRadar.Inventory.DeviceRiskAssessmentScheduler do
  @moduledoc """
  Ensures device risk assessment stays scheduled independently of matching.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [
      ServiceRadar.Inventory.DeviceRiskAssessmentWorker
    ],
    label: "Device risk assessment scheduling",
    tick: :schedule,
    named_start?: true
end

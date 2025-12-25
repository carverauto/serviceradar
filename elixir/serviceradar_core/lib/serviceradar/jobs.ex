defmodule ServiceRadar.Jobs do
  @moduledoc """
  The Jobs domain manages background job scheduling configuration.

  This domain is responsible for:
  - Job schedule management (cron expressions, enabling/disabling)
  - Schedule configuration storage
  - Schedule updates and validation

  ## Resources

  - `ServiceRadar.Jobs.JobSchedule` - Background job schedule configuration

  ## Integration with Oban

  Job schedules are stored in the database and read by the application
  on startup to configure Oban's cron scheduler. Updates to schedules
  are applied dynamically without requiring a restart.
  """

  use Ash.Domain,
    extensions: [
      AshAdmin.Domain
    ],
    validate_config_inclusion?: false

  admin do
    show? true
  end

  authorization do
    require_actor? false
    authorize :by_default
  end

  resources do
    resource ServiceRadar.Jobs.JobSchedule
  end
end

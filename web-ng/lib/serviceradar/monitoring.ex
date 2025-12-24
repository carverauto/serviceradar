defmodule ServiceRadar.Monitoring do
  @moduledoc """
  The Monitoring domain manages service checks, alerts, and events.

  This domain is responsible for:
  - Service check scheduling and execution
  - Alert lifecycle management (state machine)
  - Event recording and querying
  - Health status tracking

  ## Resources

  - `ServiceRadar.Monitoring.ServiceCheck` - Scheduled service checks
  - `ServiceRadar.Monitoring.Alert` - Alerts with state machine lifecycle
  - `ServiceRadar.Monitoring.Event` - System and device events

  ## Alert State Machine

  Alerts follow a defined lifecycle:
  - `pending` -> `acknowledged` -> `resolved`
  - `pending` -> `escalated` (via timeout)

  State transitions are enforced by AshStateMachine and can trigger
  AshOban jobs for notifications and escalation.
  """

  use Ash.Domain,
    extensions: [
      # AshJsonApi.Domain,
      # AshAdmin.Domain
    ]

  authorization do
    require_actor? true
    authorize :by_default
  end

  resources do
    resource ServiceRadar.Monitoring.ServiceCheck
    resource ServiceRadar.Monitoring.Alert
    resource ServiceRadar.Monitoring.Event
  end
end

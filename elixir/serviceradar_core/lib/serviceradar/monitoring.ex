defmodule ServiceRadar.Monitoring do
  @moduledoc """
  The Monitoring domain manages service targets, checks, alerts, and events.

  This domain is responsible for:
  - Service check scheduling and execution
  - Service-oriented monitoring bindings and materialized check instances
  - Alert lifecycle management (state machine)
  - Event recording and querying
  - Health status tracking

  ## Resources

  - `ServiceRadar.Monitoring.MonitoredService` - First-class service targets
  - `ServiceRadar.Monitoring.ServiceGroup` - Operator-defined service target sets
  - `ServiceRadar.Monitoring.MonitoringBinding` - Desired check descriptor bindings
  - `ServiceRadar.Monitoring.CheckInstance` - Materialized executable checks
  - `ServiceRadar.Monitoring.LatestCheckState` - Current check state cache
  - `ServiceRadar.Monitoring.ServiceLevelIndicator` - SLI definitions
  - `ServiceRadar.Monitoring.ServiceLevelObjective` - SLO definitions
  - `ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluation` - SLO compliance and budget state
  - `ServiceRadar.Monitoring.MonitoredServiceImportBatch` - Bulk import lifecycle records
  - `ServiceRadar.Monitoring.PollingSchedule` - Polling schedule coordination
  - `ServiceRadar.Monitoring.PollJob` - Individual poll job executions (state machine)
  - `ServiceRadar.Monitoring.ServiceCheck` - Scheduled service checks
  - `ServiceRadar.Monitoring.Alert` - Alerts with state machine lifecycle
  - `ServiceRadar.Monitoring.OcsfEvent` - OCSF event log activity entries

  ## Alert State Machine

  Alerts follow a defined lifecycle:
  - `pending` -> `acknowledged` -> `resolved`
  - `pending` -> `escalated` (via timeout)

  State transitions are enforced by AshStateMachine and can trigger
  AshOban jobs for notifications and escalation.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain,
      AshAdmin.Domain,
      AshPaperTrail.Domain
    ]

  admin do
    show?(true)
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Monitoring.MonitoredService
    resource ServiceRadar.Monitoring.ServiceGroup
    resource ServiceRadar.Monitoring.ServiceGroupMembership
    resource ServiceRadar.Monitoring.MonitoringBinding
    resource ServiceRadar.Monitoring.CheckInstance
    resource ServiceRadar.Monitoring.LatestCheckState
    resource ServiceRadar.Monitoring.ServiceLevelIndicator
    resource ServiceRadar.Monitoring.ServiceLevelObjective
    resource ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluation
    resource ServiceRadar.Monitoring.MonitoredServiceImportBatch
    resource ServiceRadar.Monitoring.PollingSchedule
    resource ServiceRadar.Monitoring.PollJob
    resource ServiceRadar.Monitoring.ServiceCheck
    resource ServiceRadar.Monitoring.Alert
    resource ServiceRadar.Monitoring.OcsfEvent
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

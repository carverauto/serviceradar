defmodule ServiceRadar.Infrastructure do
  @moduledoc """
  The Infrastructure domain manages pollers, agents, and network partitions.

  This domain is responsible for:
  - Poller management and health tracking
  - Agent registration and lifecycle
  - Checker configuration
  - Network partition management for overlapping IP spaces
  - Health event history for all entities

  ## Resources

  - `ServiceRadar.Infrastructure.Poller` - Polling nodes
  - `ServiceRadar.Infrastructure.Agent` - Go agents on monitored hosts
  - `ServiceRadar.Infrastructure.Checker` - Service check types
  - `ServiceRadar.Infrastructure.Partition` - Network partitions
  - `ServiceRadar.Infrastructure.HealthEvent` - Health state change history

  ## Distributed Architecture

  Pollers register with Horde.Registry on startup and receive job assignments
  via ERTS distribution. Agents connect to pollers via gRPC and are tracked
  in the AgentRegistry.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain,
      AshAdmin.Domain
    ]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Infrastructure.Poller
    resource ServiceRadar.Infrastructure.Agent
    resource ServiceRadar.Infrastructure.Checker
    resource ServiceRadar.Infrastructure.Partition
    resource ServiceRadar.Infrastructure.HealthEvent
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

defmodule ServiceRadar.Infrastructure do
  @moduledoc """
  The Infrastructure domain manages gateways, agents, network partitions, and health tracking.

  This domain is responsible for:
  - Gateway management and health tracking
  - Agent registration and lifecycle
  - Checker configuration
  - Network partition management for overlapping IP spaces
  - Health event history for all entities
  ## Resources

  - `ServiceRadar.Infrastructure.Gateway` - Gateway nodes (job orchestrators)
  - `ServiceRadar.Infrastructure.Agent` - Go agents on monitored hosts
  - `ServiceRadar.Infrastructure.Checker` - Service check types
  - `ServiceRadar.Infrastructure.Partition` - Network partitions
  - `ServiceRadar.Infrastructure.HealthEvent` - Health state change history
  ## Distributed Architecture

  Gateways register with Horde.Registry on startup and receive job assignments
  via ERTS distribution. Agents connect to gateways via gRPC and are tracked
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
    resource ServiceRadar.Infrastructure.Gateway
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

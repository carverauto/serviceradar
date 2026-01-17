defmodule ServiceRadar.AgentConfig do
  @moduledoc """
  The AgentConfig domain manages deployment-scoped configurations distributed to agents.

  This domain provides a reusable pattern for generating, versioning, and distributing
  configurations to agents via the agent-gateway. It supports multiple config types
  (sweep, poller, checker) through pluggable compilers.

  ## Resources

  - `ServiceRadar.AgentConfig.ConfigTemplate` - Reusable configuration templates
  - `ServiceRadar.AgentConfig.ConfigInstance` - Compiled configs for specific agents
  - `ServiceRadar.AgentConfig.ConfigVersion` - Version history for audit

  ## Compilers

  Config compilers implement the `ServiceRadar.AgentConfig.Compiler` behaviour to
  transform Ash resources into agent-consumable JSON format.
  """

  use Ash.Domain,
    extensions: [
      AshAdmin.Domain
    ]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.AgentConfig.ConfigTemplate
    resource ServiceRadar.AgentConfig.ConfigInstance
    resource ServiceRadar.AgentConfig.ConfigVersion
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

defmodule ServiceRadar.Automation.Callbacks do
  @moduledoc """
  Attenuated, action-scoped callback grants for automation executions.

  This domain owns only the durable security contract. Callback HTTP handling,
  AWX credential delivery, and lifecycle orchestration remain separate so no
  transport worker can acquire authority merely by accessing these resources.
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.Automation.Callbacks.Grant
    resource ServiceRadar.Automation.Callbacks.Use
    resource ServiceRadar.Automation.Callbacks.AuditEvent
    resource ServiceRadar.Automation.Callbacks.LaunchEnvelope
  end

  authorization do
    require_actor? true
    authorize :by_default
  end
end

defmodule ServiceRadar.Automation.Northbound do
  @moduledoc """
  Provider-neutral northbound action domain.

  This domain owns the shared action model used by device/interface launch
  surfaces and future event handlers. Concrete integrations such as Ansible or
  Wasm plugins plug into this model as action providers.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  admin do
    show?(true)
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Automation.Northbound.ActionProvider
    resource ServiceRadar.Automation.Northbound.ActionDescriptor
    resource ServiceRadar.Automation.Northbound.ActionInvocation
    resource ServiceRadar.Automation.Northbound.ActionInvocationTarget
    resource ServiceRadar.Automation.Northbound.ActionEventHandler
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

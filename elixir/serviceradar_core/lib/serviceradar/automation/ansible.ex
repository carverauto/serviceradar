defmodule ServiceRadar.Automation.Ansible do
  @moduledoc """
  Ansible automation domain — AWX/AAP controllers, playbook catalogs, runs,
  schedules, and run telemetry.

  Resources in this domain are persisted in the `platform` schema. The actual
  AWX REST traffic flows through the `awx` WASM plugin on a ServiceRadar agent
  (see openspec change `add-ansible-integration`); this domain only owns the
  Ash data model and the orchestration that drives the agent.
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
    resource ServiceRadar.Automation.Ansible.Controller
    resource ServiceRadar.Automation.Ansible.PlaybookRepository
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

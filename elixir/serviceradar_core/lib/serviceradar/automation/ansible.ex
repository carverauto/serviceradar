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
    resource ServiceRadar.Automation.Ansible.ProvisioningRequest
    resource ServiceRadar.Automation.Ansible.Playbook
    resource ServiceRadar.Automation.Ansible.PlaybookRun
    resource ServiceRadar.Automation.Ansible.PlaybookRunTarget
    resource ServiceRadar.Automation.Ansible.PlaybookPlay
    resource ServiceRadar.Automation.Ansible.PlaybookTask
    resource ServiceRadar.Automation.Ansible.PlaybookTaskResult
    resource ServiceRadar.Automation.Ansible.PlaybookContent
    resource ServiceRadar.Automation.Ansible.PlaybookSchedule
    resource ServiceRadar.Automation.Ansible.AwxHostMembership
    resource ServiceRadar.Automation.Ansible.AwxTemplateBinding
    resource ServiceRadar.Automation.Ansible.AutomationAwxLaunchPreflightEvidence
    resource ServiceRadar.Automation.Ansible.AutomationOperation
    resource ServiceRadar.Automation.Ansible.AutomationExecutionDelegation
    resource ServiceRadar.Automation.Ansible.AutomationExecution
    resource ServiceRadar.Automation.Ansible.AutomationExecutionTarget
    resource ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt
    resource ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt
    resource ServiceRadar.Automation.Ansible.AutomationMutationPhase
    resource ServiceRadar.Automation.Ansible.AutomationTargetHold
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end

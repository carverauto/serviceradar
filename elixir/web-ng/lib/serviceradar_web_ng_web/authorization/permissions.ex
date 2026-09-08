defmodule ServiceRadarWebNGWeb.Authorization.Permissions do
  @moduledoc false

  use Permit.Permissions, actions_module: ServiceRadarWebNGWeb.Authorization.Actions

  alias ServiceRadar.Automation.Ansible.AutomationOperation, as: AnsibleAutomationOperation
  alias ServiceRadar.Automation.Ansible.Controller, as: AnsibleController
  alias ServiceRadar.Automation.Ansible.Playbook, as: AnsiblePlaybook
  alias ServiceRadar.Automation.Ansible.PlaybookRepository, as: AnsibleRepository
  alias ServiceRadar.Automation.Ansible.PlaybookRun, as: AnsibleRun
  alias ServiceRadar.Automation.Ansible.PlaybookSchedule, as: AnsibleSchedule
  alias ServiceRadar.Automation.Northbound.ActionDescriptor, as: NorthboundActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionEventHandler, as: NorthboundActionEventHandler
  alias ServiceRadar.Automation.Northbound.ActionInvocation, as: NorthboundActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionProvider, as: NorthboundActionProvider
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.RBAC, as: RBACCore
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User

  @impl true
  def can(%User{} = user) do
    user
    |> RBACCore.permissions_for_user()
    |> Enum.reduce(permit(), &grant_permission/2)
  end

  def can(_), do: permit()

  defp grant_permission(permission, permissions) do
    case permission do
      "settings.auth.manage" ->
        permissions
        |> all(User)
        |> all(AuthSettings)
        |> all(AuthorizationSettings)

      "settings.rbac.manage" ->
        all(permissions, RoleProfile)

      "ansible.controllers.manage" ->
        all(permissions, AnsibleController)

      "ansible.repositories.manage" ->
        permissions
        |> all(AnsibleRepository)
        |> read(AnsibleController)

      "ansible.catalog.view" ->
        permissions
        |> read(AnsiblePlaybook)
        |> read(AnsibleController)
        |> read(AnsibleRepository)

      "ansible.runs.view" ->
        permissions
        |> read(AnsibleAutomationOperation)
        |> read(AnsibleRun)
        |> read(AnsiblePlaybook)
        |> read(AnsibleController)

      "ansible.runs.launch" ->
        permissions
        |> create(AnsibleAutomationOperation)
        |> create(AnsibleRun)

      "ansible.runs.cancel" ->
        update(permissions, AnsibleRun)

      "ansible.schedules.view" ->
        read(permissions, AnsibleSchedule)

      "ansible.schedules.manage" ->
        all(permissions, AnsibleSchedule)

      "northbound.actions.view" ->
        permissions
        |> read(NorthboundActionProvider)
        |> read(NorthboundActionDescriptor)
        |> read(NorthboundActionInvocation)
        |> read(NorthboundActionEventHandler)

      "northbound.actions.manage" ->
        permissions
        |> all(NorthboundActionProvider)
        |> all(NorthboundActionDescriptor)

      "northbound.actions.launch" ->
        create(permissions, NorthboundActionInvocation)

      "northbound.actions.cancel" ->
        update(permissions, NorthboundActionInvocation)

      "northbound.event_handlers.manage" ->
        all(permissions, NorthboundActionEventHandler)

      _ ->
        permissions
    end
  end
end

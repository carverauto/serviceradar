defmodule ServiceRadarWebNG.Authorization.PermissionsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNGWeb.Authorization

  test "admin can manage auth and user resources" do
    auth = Authorization.can(%User{role: :admin})

    assert Authorization.read?(auth, User)
    assert Authorization.update?(auth, User)

    assert Authorization.read?(auth, AuthorizationSettings)
    assert Authorization.update?(auth, AuthorizationSettings)

    assert Authorization.read?(auth, AuthSettings)
    assert Authorization.update?(auth, AuthSettings)
  end

  test "launch permission creates canonical operations without breaking retained run authorization" do
    user = %User{id: Ash.UUID.generate(), role: :viewer}

    Process.put(
      {:rbac_permissions, user.id},
      MapSet.new(["ansible.runs.launch"])
    )

    auth = Authorization.can(user)

    assert Authorization.create?(auth, AutomationOperation)
    assert Authorization.create?(auth, PlaybookRun)
    refute Authorization.read?(auth, AutomationOperation)

    RBAC.clear_process_cache()
  end

  test "repository managers can enter settings without receiving controller mutation rights" do
    user = %User{id: Ash.UUID.generate(), role: :viewer}

    Process.put(
      {:rbac_permissions, user.id},
      MapSet.new(["ansible.repositories.manage"])
    )

    auth = Authorization.can(user)

    assert Authorization.read?(auth, Controller)
    assert Authorization.create?(auth, PlaybookRepository)
    assert Authorization.update?(auth, PlaybookRepository)
    refute Authorization.create?(auth, Controller)
    refute Authorization.update?(auth, Controller)

    RBAC.clear_process_cache()
  end

  test "non-admin has no access" do
    auth = Authorization.can(%User{role: :viewer})

    refute Authorization.read?(auth, User)
    refute Authorization.read?(auth, AuthorizationSettings)
    refute Authorization.read?(auth, AuthSettings)
  end

  test "operator cannot manage authorization settings" do
    auth = Authorization.can(%User{role: :operator})

    refute Authorization.read?(auth, AuthorizationSettings)
    refute Authorization.update?(auth, AuthorizationSettings)
    refute Authorization.read?(auth, AuthSettings)
  end
end

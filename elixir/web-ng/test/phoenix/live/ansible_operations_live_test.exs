defmodule ServiceRadarWebNGWeb.AnsibleOperationsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.AnsibleAutomation.History, as: AutomationHistory
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()
    permissions = ServiceRadar.Identity.RBAC.permissions_for_user(user)
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user, permissions: permissions)}
  end

  test "operation history index and detail use the canonical route without exposing authority", %{
    conn: conn,
    scope: scope
  } do
    operation_id = Ash.UUIDv7.generate()
    persisted_operation_id = Ecto.UUID.dump!(operation_id)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    Repo.insert_all(
      "ansible_automation_operations",
      [
        %{
          id: persisted_operation_id,
          tenant_id: "default",
          action: "ansible.playbook.run",
          state: "dispatch_ambiguous",
          mutating: true,
          check_mode: false,
          initiator_principal_type: "human",
          initiator_principal_id: "user:history-test",
          authorization_version: "rbac-v1",
          authority_ceiling: %{"secret" => "authority-secret-must-not-render"},
          approval_snapshot: %{"secret" => "approval-secret-must-not-render"},
          request_source: "ansible_launch_live",
          declared_inputs: %{},
          input_classifications: %{},
          input_digest: String.duplicate("a", 64),
          target_digest: String.duplicate("b", 64),
          callback_actions: [],
          run_budget: %{},
          diagnostics: %{"reason_code" => "dispatch_ambiguous"},
          metadata: %{"callback_reference" => "callback-secret-must-not-render"},
          started_at: now,
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: "platform"
    )

    assert {:ok, [%{id: ^operation_id}]} = AutomationHistory.list_operations(scope)

    {:ok, index, _html} = live(conn, ~p"/ansible/operations")

    assert has_element?(index, "#ops-topbar")
    assert has_element?(index, ".sr-ops-sidebar[aria-label='Primary navigation']")
    assert has_element?(index, ".sr-ops-page-title", "Ansible operations")
    assert has_element?(index, "#select-ansible-launch-devices[href='/devices']", "Select Devices")
    refute has_element?(index, "a[href='/ansible/launch']")

    assert has_element?(
             index,
             "#secure-operation-history a[href='/ansible/operations/#{operation_id}']",
             "View evidence"
           )

    refute has_element?(index, "a[href='/ansible/runs']")
    refute has_element?(index, "#secure-ansible-operations", "Legacy")

    {:ok, detail, _html} = live(conn, ~p"/ansible/operations/#{operation_id}")

    assert has_element?(detail, "#ops-topbar")
    assert has_element?(detail, ".sr-ops-sidebar[aria-label='Primary navigation']")
    assert has_element?(detail, ".sr-ops-page-title", "Ansible operation #{short_id(operation_id)}")
    assert has_element?(detail, "#secure-ansible-operation-detail")
    assert has_element?(detail, "[data-testid=automation-state-alert]", "dispatch outcome is ambiguous")
    assert has_element?(detail, "#secure-operation-no-executions")
    refute has_element?(detail, "a[href='/ansible/runs']")
    refute has_element?(detail, "#secure-ansible-operation-detail", "Legacy")

    refute has_element?(
             detail,
             "#secure-ansible-operation-detail",
             "authority-secret-must-not-render"
           )

    refute has_element?(
             detail,
             "#secure-ansible-operation-detail",
             "approval-secret-must-not-render"
           )

    refute has_element?(
             detail,
             "#secure-ansible-operation-detail",
             "callback-secret-must-not-render"
           )
  end

  test "retired legacy run routes return not found", %{conn: conn} do
    assert get(conn, "/ansible/runs").status == 404
    assert get(conn, "/ansible/runs/retired-run").status == 404
  end

  test "view-only users are not offered the launch workflow" do
    viewer = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(Phoenix.ConnTest.build_conn(), viewer)

    {:ok, index, _html} = live(conn, ~p"/ansible/operations")

    refute has_element?(index, "#select-ansible-launch-devices")
  end

  defp short_id(id), do: String.slice(id, 0, 8) <> "…"
end

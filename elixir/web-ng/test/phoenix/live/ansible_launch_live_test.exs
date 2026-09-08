defmodule ServiceRadarWebNGWeb.AnsibleLaunchLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ash.Seed
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNGWeb.AnsibleLive.LaunchLive

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope:
        Scope.for_user(user,
          permissions: RBAC.permissions_for_user(user)
        )
    }
  end

  test "loads selected devices only after the LiveView connects", %{conn: conn, scope: scope} do
    uid = "ansible-launch-device-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "camera-01",
        ip: "10.0.110.117",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    disconnected_socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: scope}
    }

    assert {:ok, mounted_socket} =
             LaunchLive.mount(%{"devices" => uid}, %{}, disconnected_socket)

    assert mounted_socket.assigns.requested_uids == [uid]
    assert mounted_socket.assigns.devices == []
    assert mounted_socket.assigns.playbooks == []

    static_document =
      conn
      |> get(~p"/ansible/launch?devices=#{uid}")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert static_document
           |> LazyHTML.query("#ansible-launch-target-count")
           |> LazyHTML.text() =~ "1 selected · 0 visible"

    refute LazyHTML.text(static_document) =~ "camera-01"

    {:ok, view, html} = live(conn, ~p"/ansible/launch?devices=#{uid}")

    assert has_element?(view, "#ops-topbar")
    assert has_element?(view, ".sr-ops-sidebar[aria-label='Primary navigation']")
    assert has_element?(view, ".sr-ops-page-title", "Launch Ansible playbook")
    assert html =~ "camera-01"
    assert html =~ "Canonical UID"
    assert html =~ "Reviewed launch contract"
    assert html =~ "Operation history"
    assert html =~ ~s(id="secure-ansible-launch-form")
    assert html =~ ~s(id="secure-ansible-launch-submit")
    refute html =~ "ServiceRadar secured"
    refute html =~ "raw JSON"
    refute html =~ "extra_vars"
    refute html =~ ~s(type="password")

    assert is_binary(render_change(view, "validate", %{"playbook_id" => ""}))
    assert render_submit(view, "launch", %{}) =~ "Pick a playbook before launching."
  end

  test "a launch-only role can resolve a real reviewed playbook and exact target", %{conn: conn} do
    {device_uid, playbook} = seed_secure_launch_fixture()

    user =
      %{role: :viewer}
      |> AccountsFixtures.user_fixture()
      |> grant_permissions(["ansible.runs.launch"])

    conn = log_in_user(conn, user)

    {:ok, view, html} = live(conn, ~p"/ansible/launch?devices=#{device_uid}")

    assert html =~ playbook.name
    assert has_element?(view, "#secure-ansible-playbook option[value='#{playbook.id}']")

    html = render_change(view, "validate", %{"playbook_id" => playbook.id})

    assert html =~ "Reviewed binding and exact target memberships are ready."

    assert has_element?(
             view,
             "#secure-ansible-launch-readiness.alert-success",
             "Binding approved"
           )

    assert has_element?(view, "#secure-ansible-launch-submit:not([disabled])")
  end

  defp seed_secure_launch_fixture do
    suffix = System.unique_integer([:positive])
    device_uid = "ansible-launch-only-device-#{suffix}"
    inventory_id = 42_000 + rem(suffix, 10_000)
    job_template_id = 52_000 + rem(suffix, 10_000)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: device_uid,
        type_id: 0,
        hostname: "launch-only-device-#{suffix}",
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    controller =
      Seed.seed!(Controller, %{
        name: "launch-only-controller-#{suffix}",
        base_url: "https://awx.test.invalid",
        agent_id: "launch-only-agent-#{suffix}",
        credential_secret_id: Ash.UUID.generate()
      })

    playbook =
      Seed.seed!(Playbook, %{
        source_type: :awx,
        name: "Reviewed launch-only playbook #{suffix}",
        controller_id: controller.id,
        awx_job_template_id: job_template_id,
        parse_status: :ok
      })

    Seed.seed!(AwxTemplateBinding, %{
      controller_id: controller.id,
      job_template_id: job_template_id,
      binding_version: 1,
      current: true,
      approval_state: :approved,
      approval_id: Ash.UUID.generate(),
      approval_expires_at: DateTime.add(now, 3_600, :second),
      inventory_policy: :allow_list,
      allowed_inventory_ids: [inventory_id],
      project_id: 1,
      scm_revision: String.duplicate("a", 40),
      content_sha256: String.duplicate("b", 64),
      execution_environment_id: 1,
      credentials: [%{"id" => 1, "kind" => "ssh"}],
      machine_credential_id: 1,
      run_mode_supported: true,
      ask_inventory_on_launch: true,
      ask_limit_on_launch: true,
      ask_job_type_on_launch: true,
      dispatch_markers_retained: true,
      inventory_groups_verified: true,
      inventory_group_names: ["launch-only"],
      input_schema: %{},
      input_classifications: %{},
      awx_created_by_id: 1,
      reviewed_by_principal_type: :human,
      reviewed_by_principal_id: "user:reviewer",
      reviewed_at: now
    })

    Seed.seed!(AwxHostMembership, %{
      controller_id: controller.id,
      inventory_id: inventory_id,
      awx_host_id: 62_000 + rem(suffix, 10_000),
      canonical_device_uid: device_uid,
      source_generation: 1,
      host_name: "launch-only-device-#{suffix}",
      enabled: true,
      current: true,
      last_seen_at: now,
      link_disposition: :approved,
      source_fingerprint: String.duplicate("c", 64)
    })

    {device_uid, playbook}
  end

  defp grant_permissions(user, permissions) do
    actor = AshTestHelpers.system_actor()

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Ansible launch LiveView #{System.unique_integer([:positive])}",
          description: "Test profile for launch-only LiveView authorization",
          permissions: permissions
        },
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    updated =
      user
      |> Ash.Changeset.for_update(
        :update_role_profile,
        %{role_profile_id: profile.id},
        actor: actor
      )
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(updated.id, MapSet.new(permissions))

    updated
  end
end

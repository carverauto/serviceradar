defmodule ServiceRadarWebNGWeb.Settings.AnsibleReviewLiveTest do
  @moduledoc """
  Membership and template-binding review tabs of `/settings/ansible`.

  The domain services (`AwxMembershipApproval`, `AwxBindingReview`) own the
  evidence comparison and the human-principal check and are tested in core.
  These tests own the page's side of the contract: what it submits, that it
  never submits a review the operator was not shown, and that every mutation
  event re-checks `ansible.controllers.manage`. The domain module is replaced
  through the same `:ansible_automation` seam the API controller uses; all
  identifiers are invented.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.AccountsFixtures

  @state_key :ansible_review_live_test_state
  @device_uid "sr:11111111-2222-4333-8444-555555555555"
  @proposed_id "0190c0de-0000-7000-8000-000000000001"
  @unlinked_id "0190c0de-0000-7000-8000-000000000002"
  @approved_id "0190c0de-0000-7000-8000-000000000003"
  @binding_id "0190c0de-0000-7000-8000-0000000000b4"
  @fingerprint_a "sha256:" <> String.duplicate("a", 64)
  @fingerprint_c "sha256:" <> String.duplicate("c", 64)
  @evidence_digest String.duplicate("b", 64)
  @content_sha String.duplicate("d", 64)
  @review_digest_1 String.duplicate("1", 64)
  @review_digest_2 String.duplicate("2", 64)

  defmodule Automation do
    @moduledoc false
    # Records what the page submits and replays scripted domain results.

    def list_membership_inventories(_scope, _controller_id), do: {:ok, [%{inventory_id: 7, needs_review: 1}]}

    def list_memberships(_scope, %{"inventory_id" => 7}), do: {:ok, get(:memberships)}

    def approve_membership(scope, id, params) do
      notify({:approve, scope.user.id, id, params})
      pop(:approve_results)
    end

    def list_binding_templates(_scope, _controller_id) do
      {:ok,
       [
         %{
           playbook_id: "0190c0de-0000-7000-8000-0000000000a1",
           name: "Patch hosts",
           job_template_id: 42,
           project_id: 11,
           inventory_id: 7
         }
       ]}
    end

    def list_bindings(_scope, %{"job_template_id" => 42}), do: {:ok, get(:bindings)}

    def prepare_binding(scope, request) do
      notify({:prepare, scope.user.id, request})
      pop(:prepare_results)
    end

    def create_binding(scope, request) do
      notify({:create, scope.user.id, request})
      pop(:create_results)
    end

    def revoke_binding(scope, id, params) do
      notify({:revoke, scope.user.id, id, params})
      {:ok, %{binding_version: 3, job_template_id: 42}}
    end

    def put(key, value), do: Agent.update(agent(), &Map.put(&1, key, value))

    defp get(key), do: Agent.get(agent(), &Map.fetch!(&1, key))

    defp pop(key) do
      Agent.get_and_update(agent(), fn state ->
        [next | rest] = Map.fetch!(state, key)
        {next, Map.put(state, key, rest)}
      end)
    end

    defp notify(message), do: send(Application.fetch_env!(:serviceradar_web_ng, :ansible_review_live_test_pid), message)
    defp agent, do: Application.fetch_env!(:serviceradar_web_ng, :ansible_review_live_test_state)
  end

  setup :log_in_admin

  setup %{user: user} do
    previous = Application.get_env(:serviceradar_web_ng, :ansible_automation)
    agent = start_supervised!({Agent, fn -> %{} end})

    Application.put_env(:serviceradar_web_ng, :ansible_automation, Automation)
    Application.put_env(:serviceradar_web_ng, @state_key, agent)
    Application.put_env(:serviceradar_web_ng, :ansible_review_live_test_pid, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :ansible_automation, previous),
        else: Application.delete_env(:serviceradar_web_ng, :ansible_automation)

      Application.delete_env(:serviceradar_web_ng, @state_key)
      Application.delete_env(:serviceradar_web_ng, :ansible_review_live_test_pid)
    end)

    controller = controller_fixture!()
    Automation.put(:memberships, [proposed(controller.id), unlinked(controller.id)])
    Automation.put(:bindings, [current_binding(controller.id)])

    %{controller: controller, user: user}
  end

  @tag :web_ng_shared_fixture_db
  test "approval submits the shown tuple and a changed proposal is re-shown, not approved", %{
    conn: conn,
    controller: controller,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/ansible?tab=memberships")

    assert has_element?(view, "#ansible-membership-filter-needs_review", "Needs review (1)")
    assert has_element?(view, "#ansible-membership-reason-#{@unlinked_id}", "cannot be forced")
    refute has_element?(view, "#ansible-membership-review-#{@unlinked_id}")

    view |> element("#ansible-membership-review-#{@proposed_id}") |> render_click()

    # Inventory sync re-observes the host while the operator is reading.
    changed = %{proposed(controller.id) | source_generation: "8", source_fingerprint: @fingerprint_c}
    Automation.put(:memberships, [changed, unlinked(controller.id)])

    Automation.put(:approve_results, [
      {:error, :membership_evidence_changed},
      {:ok, %{changed | link_disposition: :approved}}
    ])

    view |> element("#ansible-membership-approve") |> render_click()

    assert_receive {:approve, user_id, @proposed_id, shown}
    assert user_id == user.id

    assert shown == %{
             "controller_id" => controller.id,
             "inventory_id" => 7,
             "awx_host_id" => 101,
             "canonical_device_uid" => @device_uid,
             "source_generation" => "7",
             "source_fingerprint" => @fingerprint_a,
             "link_evidence_digest" => @evidence_digest
           }

    assert has_element?(view, "#flash-error", "changed after you reviewed it")
    assert has_element?(view, "#ansible-membership-review", String.duplicate("c", 64))
    refute_receive {:approve, _, _, _}

    view |> element("#ansible-membership-approve") |> render_click()

    assert_receive {:approve, _user_id, @proposed_id, %{"source_generation" => "8"} = reviewed}
    assert reviewed["source_fingerprint"] == @fingerprint_c
    assert has_element?(view, "#flash-info", "Approved host01.example.com")
    refute has_element?(view, "#ansible-membership-review")
  end

  @tag :web_ng_shared_fixture_db
  test "create submits the prepared digest and a changed review is prepared again, not created", %{
    conn: conn,
    controller: controller,
    user: user
  } do
    Automation.put(:memberships, [approved(controller.id)])

    Automation.put(:prepare_results, [
      {:ok, %{review: review(), review_digest: @review_digest_1}},
      {:ok, %{review: review(), review_digest: @review_digest_2}},
      {:ok, %{review: review(), review_digest: @review_digest_1}}
    ])

    Automation.put(:create_results, [
      {:error, :binding_review_changed},
      {:ok, %{current_binding(controller.id) | binding_version: 4}}
    ])

    {:ok, view, _html} = live(conn, ~p"/settings/ansible?tab=bindings")

    render_click(view, "create_binding", %{})
    refute_receive {:create, _, _}

    view |> element("#ansible-binding-new") |> render_click()
    assert has_element?(view, "#ansible-binding-choice-#{@approved_id}")

    view
    |> form("#ansible-binding-form",
      binding: %{
        credential_ids: "5, 6",
        machine_credential_id: "5",
        execution_environment_id: "3",
        membership_ids: [@approved_id],
        content_sha256: @content_sha,
        review_ticket: "CHG-0001"
      }
    )
    |> render_submit()

    render_async(view)

    expected_request = %{
      "controller_id" => controller.id,
      "template_id" => 42,
      "project_id" => 11,
      "inventory_id" => 7,
      "credential_ids" => [5, 6],
      "machine_credential_id" => 5,
      "execution_environment_id" => 3,
      "membership_ids" => [@approved_id],
      "content_sha256" => @content_sha,
      "review_ticket" => "CHG-0001",
      "approval_ttl_seconds" => 3600
    }

    assert_receive {:prepare, user_id, ^expected_request}
    assert user_id == user.id
    assert has_element?(view, "#ansible-binding-review-digest", @review_digest_1)
    refute_receive {:create, _, _}

    view |> element("#ansible-binding-create") |> render_click()
    render_async(view)
    render_async(view)

    assert_receive {:create, _user_id, first_create}
    assert first_create == Map.put(expected_request, "expected_review_digest", @review_digest_1)
    assert_receive {:prepare, _user_id, ^expected_request}
    assert has_element?(view, "#ansible-binding-review-changed")
    assert has_element?(view, "#ansible-binding-review-digest", @review_digest_2)
    refute has_element?(view, "#flash-info", "Created binding")
    refute_receive {:create, _, _}

    view |> element("#ansible-binding-create") |> render_click()
    render_async(view)

    assert_receive {:create, _user_id, second_create}
    assert second_create["expected_review_digest"] == @review_digest_2
    assert has_element?(view, "#flash-info", "Created binding version 4")
    refute has_element?(view, "#ansible-binding-review")
    refute has_element?(view, "#ansible-binding-creating")

    view |> element("#ansible-binding-new") |> render_click()

    view
    |> form("#ansible-binding-form",
      binding: %{
        credential_ids: "5, 6",
        machine_credential_id: "5",
        execution_environment_id: "3",
        membership_ids: [@approved_id],
        content_sha256: @content_sha,
        review_ticket: "CHG-0001"
      }
    )
    |> render_submit()

    render_async(view)

    assert_receive {:prepare, _user_id, ^expected_request}
    assert has_element?(view, "#ansible-binding-review-digest", @review_digest_1)
  end

  @tag :web_ng_shared_fixture_db
  test "revocation requires the exact binding ID to be typed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/ansible?tab=bindings")

    view |> element("#ansible-binding-revoke-#{@binding_id}") |> render_click()

    view
    |> form("#ansible-binding-revoke-form", revoke: %{confirmation_id: "v3"})
    |> render_submit()

    refute_receive {:revoke, _, _, _}
    assert has_element?(view, "#ansible-binding-revoke-modal", "Type the exact binding ID")

    view
    |> form("#ansible-binding-revoke-form", revoke: %{confirmation_id: @binding_id})
    |> render_submit()

    assert_receive {:revoke, _user_id, @binding_id, %{}}
    assert has_element?(view, "#flash-info", "Revoked binding version 3")
  end

  @tag :web_ng_shared_fixture_db
  test "a manager who loses ansible.controllers.manage cannot approve, create or revoke by event", %{
    conn: conn,
    controller: controller,
    user: user
  } do
    Automation.put(:prepare_results, [{:ok, %{review: review(), review_digest: @review_digest_1}}])

    {:ok, memberships_view, _html} = live(conn, ~p"/settings/ansible?tab=memberships")
    memberships_view |> element("#ansible-membership-review-#{@proposed_id}") |> render_click()

    Automation.put(:memberships, [approved(controller.id)])
    {:ok, bindings_view, _html} = live(conn, ~p"/settings/ansible?tab=bindings")
    bindings_view |> element("#ansible-binding-new") |> render_click()

    bindings_view
    |> form("#ansible-binding-form",
      binding: %{
        credential_ids: "5",
        machine_credential_id: "5",
        execution_environment_id: "3",
        membership_ids: [@approved_id],
        content_sha256: @content_sha,
        review_ticket: "CHG-0002"
      }
    )
    |> render_submit()

    render_async(bindings_view)
    assert_receive {:prepare, _user_id, _request}
    bindings_view |> element("#ansible-binding-revoke-#{@binding_id}") |> render_click()

    # Every control is open and armed; now the account loses the permission.
    restrict_permissions(user, ["ansible.repositories.manage", "ansible.runs.view", "ansible.catalog.view"])

    assert render_click(memberships_view, "approve_membership", %{}) =~
             "Your Ansible settings permissions changed"

    assert render_click(bindings_view, "create_binding", %{}) =~
             "Your Ansible settings permissions changed"

    assert render_click(bindings_view, "confirm_revoke_binding", %{
             "revoke" => %{"id" => @binding_id, "confirmation_id" => @binding_id}
           }) =~ "Your Ansible settings permissions changed"

    render_async(bindings_view)
    refute_receive {:approve, _, _, _}
    refute_receive {:create, _, _}
    refute_receive {:revoke, _, _, _}
  end

  defp log_in_admin(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, user), user: user}
  end

  defp proposed(controller_id) do
    membership(controller_id, @proposed_id, 101, "host01.example.com", :proposed, @device_uid, 1)
  end

  defp unlinked(controller_id) do
    membership(controller_id, @unlinked_id, 102, "host02.example.com", :unlinked, nil, 0)
  end

  defp approved(controller_id) do
    membership(controller_id, @approved_id, 103, "host03.example.com", :approved, @device_uid, 1)
  end

  defp membership(controller_id, id, awx_host_id, host_name, disposition, device_uid, matches) do
    %{
      id: id,
      controller_id: controller_id,
      inventory_id: 7,
      awx_host_id: awx_host_id,
      canonical_device_uid: device_uid,
      host_name: host_name,
      ansible_host: "192.0.2.#{awx_host_id - 90}",
      enabled: true,
      current: true,
      link_disposition: disposition,
      source_generation: "7",
      source_fingerprint: @fingerprint_a,
      link_evidence_digest: @evidence_digest,
      link_evidence: %{
        "kind" => "stored_awx_source_tuple",
        "controller_id" => controller_id,
        "inventory_id" => 7,
        "awx_host_id" => awx_host_id,
        "matching_device_uids" => List.wrap(device_uid),
        "match_count" => matches
      },
      last_seen_at: ~U[2026-01-01 00:00:00.000000Z]
    }
  end

  defp current_binding(controller_id) do
    %{
      id: @binding_id,
      controller_id: controller_id,
      job_template_id: 42,
      binding_version: 3,
      current: true,
      approval_state: :approved,
      approval_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1),
      inventory_policy: :fixed,
      allowed_inventory_ids: [7],
      project_id: 11,
      scm_revision: String.duplicate("e", 40),
      content_sha256: @content_sha,
      execution_environment_id: 3,
      run_mode_supported: true,
      check_mode_supported: true,
      reviewed_at: ~U[2026-01-01 00:00:00.000000Z],
      reviewed_launch_snapshot_digest: String.duplicate("f", 64)
    }
  end

  defp review do
    %{
      "attributes" => %{
        "job_template_id" => 42,
        "inventory_policy" => "fixed",
        "allowed_inventory_ids" => [7],
        "project_id" => 11,
        "scm_revision" => String.duplicate("e", 40),
        "credentials" => [%{"id" => 5, "kind" => "ssh"}],
        "machine_credential_id" => 5,
        "execution_environment_id" => 3,
        "run_mode_supported" => true,
        "check_mode_supported" => false,
        "inventory_group_names" => ["group01"],
        "input_schema" => %{},
        "content_sha256" => @content_sha,
        "review_metadata" => %{"review_ticket" => "CHG-0001"}
      },
      "approval_ttl_seconds" => 3_600
    }
  end

  defp controller_fixture! do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "AWX review sync token #{System.unique_integer([:positive])}",
          provider: "awx",
          credential_kind: :api_token,
          public_fingerprint: "sha256:test",
          secret_payload: "synthetic-awx-token",
          metadata: %{"auth_method" => "bearer_token", "credential_purpose" => "sync"}
        },
        actor: system_actor()
      )
      |> Ash.create(actor: system_actor())

    {:ok, controller} =
      Controller.create_controller(
        %{
          name: "Review AWX #{System.unique_integer([:positive])}",
          agent_id: "agent-review-01",
          base_url: "https://awx.example.com",
          credential_secret_id: secret.id,
          sync_credential_secret_id: secret.id
        },
        actor: system_actor()
      )

    controller
  end

  defp restrict_permissions(user, permissions) do
    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Ansible review LiveView #{System.unique_integer([:positive])}",
          description: "Test profile without Ansible controller management",
          permissions: permissions
        },
        actor: system_actor(),
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    updated =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: system_actor())
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(updated.id, MapSet.new(permissions))
    updated
  end
end

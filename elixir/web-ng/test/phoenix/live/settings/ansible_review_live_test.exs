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
  @second_id "0190c0de-0000-7000-8000-000000000004"
  @second_device_uid "sr:66666666-7777-4888-9999-000000000000"
  @quarantined_id "0190c0de-0000-7000-8000-000000000005"
  @legacy_id "0190c0de-0000-7000-8000-000000000006"
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

    def release_membership(scope, id, params) do
      notify({:release, scope.user.id, id, params})
      pop(:release_results)
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
    assert has_element?(view, "#ansible-membership-inventory option", "Inventory 7 (1 need review)")
    assert has_element?(view, "#ansible-membership-reason-#{@unlinked_id}", "cannot be forced")
    refute has_element?(view, "#ansible-membership-review-#{@unlinked_id}")

    view |> element("#ansible-membership-review-#{@proposed_id}") |> render_click()
    assert has_element?(view, "dialog#ansible-membership-review", @evidence_digest)

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

    assert shown == shown_tuple(controller.id, 101, @device_uid)

    assert has_element?(view, "#ansible-membership-review-error", "changed after you reviewed it")
    assert has_element?(view, "#ansible-membership-review", String.duplicate("c", 64))
    refute_receive {:approve, _, _, _}

    Automation.put(:memberships, [%{changed | link_disposition: :approved}, unlinked(controller.id)])
    view |> element("#ansible-membership-approve") |> render_click()

    assert_receive {:approve, _user_id, @proposed_id, %{"source_generation" => "8"} = reviewed}
    assert reviewed["source_fingerprint"] == @fingerprint_c
    assert has_element?(view, "#flash-info", "Approved host01.example.com")
    refute has_element?(view, "#ansible-membership-review")

    # The picker count follows the reloaded list, as the filter counts do.
    assert has_element?(view, "#ansible-membership-filter-needs_review", "Needs review (0)")
    refute has_element?(view, "#ansible-membership-inventory option", "need review")
  end

  @tag :web_ng_shared_fixture_db
  test "bulk approval submits each shown tuple and re-presents only the rows that changed", %{
    conn: conn,
    controller: controller,
    user: user
  } do
    Automation.put(:memberships, [proposed(controller.id), second(controller.id), unlinked(controller.id)])
    {:ok, view, _html} = live(conn, ~p"/settings/ansible?tab=memberships")

    refute has_element?(view, "#ansible-membership-select-#{@unlinked_id}")
    view |> element("#ansible-membership-select-#{@proposed_id}") |> render_click()
    assert has_element?(view, "#ansible-membership-bulk-open", "Approve selected (1)")
    view |> element("#ansible-membership-select-all") |> render_click()
    assert has_element?(view, "#ansible-membership-bulk-open", "Approve selected (2)")

    view |> element("#ansible-membership-bulk-open") |> render_click()
    assert has_element?(view, "#ansible-membership-bulk-item-#{@proposed_id}", @evidence_digest)
    assert has_element?(view, "#ansible-membership-bulk-item-#{@second_id}", @fingerprint_a)
    refute_receive {:approve, _, _, _}

    # Inventory sync re-observes the second host before the operator confirms.
    changed = %{second(controller.id) | source_generation: "8", source_fingerprint: @fingerprint_c}

    Automation.put(:memberships, [
      %{proposed(controller.id) | link_disposition: :approved},
      changed,
      unlinked(controller.id)
    ])

    Automation.put(:approve_results, [
      {:ok, %{proposed(controller.id) | link_disposition: :approved}},
      {:error, :membership_evidence_changed},
      {:ok, %{changed | link_disposition: :approved}}
    ])

    view |> element("#ansible-membership-bulk-approve") |> render_click()
    render_async(view)

    assert_receive {:approve, user_id, @proposed_id, first}
    assert user_id == user.id
    assert first == shown_tuple(controller.id, 101, @device_uid)
    assert_receive {:approve, _user_id, @second_id, second_shown}
    assert second_shown == shown_tuple(controller.id, 104, @second_device_uid)
    refute_receive {:approve, _, _, _}

    assert has_element?(view, "#ansible-membership-bulk-outcome-#{@proposed_id}", "approved")
    assert has_element?(view, "#ansible-membership-bulk-outcome-#{@second_id}", "evidence changed")
    assert has_element?(view, "#ansible-membership-bulk-changed")
    assert has_element?(view, "#ansible-membership-bulk-item-#{@second_id}", @fingerprint_c)
    refute has_element?(view, "#ansible-membership-bulk-item-#{@proposed_id}")
    assert has_element?(view, "#ansible-membership-bulk-open", "Approve selected (1)")

    view |> element("#ansible-membership-bulk-approve") |> render_click()
    render_async(view)

    assert_receive {:approve, _user_id, @second_id, %{"source_generation" => "8"} = reviewed}
    assert reviewed["source_fingerprint"] == @fingerprint_c
    assert has_element?(view, "#flash-info", "Approved 1 of 1 memberships")
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
    select_template(view, controller)

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
  test "revocation requires the exact binding ID to be typed", %{conn: conn, controller: controller} do
    {:ok, view, _html} = live(conn, ~p"/settings/ansible?tab=bindings")
    select_template(view, controller)

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
  test "the binding form prefills nothing arbitrary and its memberships follow the typed inventory", %{
    conn: conn,
    controller: controller
  } do
    Automation.put(:memberships, [approved(controller.id)])
    {:ok, view, _html} = live(conn, ~p"/settings/ansible?tab=bindings")

    assert has_element?(view, "#ansible-binding-choose-template")
    refute has_element?(view, "#ansible-binding-versions")

    view |> element("#ansible-binding-new") |> render_click()
    assert has_element?(view, "#ansible-binding-template_id[value='']")
    assert has_element?(view, "#ansible-binding-inventory_id[value='']")
    assert has_element?(view, "#ansible-binding-choice-notice", "No inventory chosen yet")
    assert has_element?(view, "#ansible-binding-inventory-options option[value='7']")

    view |> form("#ansible-binding-form", binding: %{inventory_id: "7"}) |> render_change()

    assert has_element?(view, "#ansible-binding-choice-#{@approved_id}")
    refute has_element?(view, "#ansible-binding-choice-notice")
  end

  @tag :web_ng_shared_fixture_db
  test "release shows the recorded reason, submits the shown tuple, and never approves or resubmits", %{
    conn: conn,
    controller: controller,
    user: user
  } do
    Automation.put(:memberships, [
      proposed(controller.id),
      unlinked(controller.id),
      quarantined(controller.id),
      legacy_quarantined(controller.id)
    ])

    {:ok, view, _html} = live(conn, ~p"/settings/ansible?tab=memberships")

    # Quarantined and unlinked rows are counted apart, never as one bucket.
    assert has_element?(view, "#ansible-membership-filter-quarantined", "Quarantined (2)")
    assert has_element?(view, "#ansible-membership-filter-unlinked", "Unlinked (1)")
    refute has_element?(view, "#ansible-membership-filter-not_linkable")

    assert has_element?(
             view,
             "#ansible-membership-quarantine-#{@quarantined_id}",
             "started matching a different device"
           )

    assert has_element?(view, "#ansible-membership-quarantine-#{@legacy_id}", "Cause unknown")
    assert has_element?(view, "#ansible-membership-quarantine-#{@legacy_id}", "Quarantined at: unknown")
    refute has_element?(view, "#ansible-membership-review-#{@quarantined_id}")
    refute has_element?(view, "#ansible-membership-release-#{@proposed_id}")
    refute has_element?(view, "#ansible-membership-release-#{@unlinked_id}")

    view |> element("#ansible-membership-release-#{@quarantined_id}") |> render_click()
    assert has_element?(view, "dialog#ansible-membership-release", @evidence_digest)
    assert has_element?(view, "#ansible-membership-release-reason", "started matching a different device")

    Automation.put(:release_results, [
      {:error, {:membership_link_ambiguous, [@device_uid, @second_device_uid]}},
      {:error, :membership_evidence_changed},
      {:ok, released(controller.id)}
    ])

    view |> element("#ansible-membership-release-confirm") |> render_click()

    assert_receive {:release, user_id, @quarantined_id, shown}
    assert user_id == user.id
    assert shown == controller.id |> shown_tuple(105, @device_uid) |> Map.delete("canonical_device_uid")
    assert has_element?(view, "#ansible-membership-release-ambiguous", @second_device_uid)
    assert has_element?(view, "#ansible-membership-release-error", "stays quarantined")

    # Inventory sync re-observes the host while the operator is reading.
    changed = %{quarantined(controller.id) | source_generation: "8", source_fingerprint: @fingerprint_c}
    Automation.put(:memberships, [proposed(controller.id), unlinked(controller.id), changed])

    view |> element("#ansible-membership-release-confirm") |> render_click()
    assert_receive {:release, _user_id, @quarantined_id, %{"source_generation" => "7"}}
    assert has_element?(view, "#ansible-membership-release-error", "changed after you opened it")
    assert has_element?(view, "dialog#ansible-membership-release", String.duplicate("c", 64))
    refute_receive {:release, _, _, _}

    Automation.put(:memberships, [proposed(controller.id), unlinked(controller.id), released(controller.id)])
    view |> element("#ansible-membership-release-confirm") |> render_click()

    assert_receive {:release, _user_id, @quarantined_id, %{"source_generation" => "8"} = confirmed}
    assert confirmed["source_fingerprint"] == @fingerprint_c
    assert has_element?(view, "#flash-info", "now proposed")
    refute has_element?(view, "#ansible-membership-release")
    assert has_element?(view, "#ansible-membership-review-#{@quarantined_id}")
    refute_receive {:approve, _, _, _}
  end

  @tag :web_ng_shared_fixture_db
  test "a manager who loses ansible.controllers.manage cannot approve, bulk approve, create or revoke by event", %{
    conn: conn,
    controller: controller,
    user: user
  } do
    Automation.put(:prepare_results, [{:ok, %{review: review(), review_digest: @review_digest_1}}])

    {:ok, memberships_view, _html} = live(conn, ~p"/settings/ansible?tab=memberships")
    memberships_view |> element("#ansible-membership-review-#{@proposed_id}") |> render_click()

    Automation.put(:memberships, [proposed(controller.id), unlinked(controller.id), quarantined(controller.id)])
    {:ok, release_view, _html} = live(conn, ~p"/settings/ansible?tab=memberships")
    release_view |> element("#ansible-membership-release-#{@quarantined_id}") |> render_click()
    Automation.put(:memberships, [proposed(controller.id), unlinked(controller.id)])

    {:ok, bulk_view, _html} = live(conn, ~p"/settings/ansible?tab=memberships")
    bulk_view |> element("#ansible-membership-select-all") |> render_click()
    bulk_view |> element("#ansible-membership-bulk-open") |> render_click()
    assert has_element?(bulk_view, "#ansible-membership-bulk-approve")

    Automation.put(:memberships, [approved(controller.id)])
    {:ok, bindings_view, _html} = live(conn, ~p"/settings/ansible?tab=bindings")
    select_template(bindings_view, controller)
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

    assert render_click(bulk_view, "approve_selected_memberships", %{}) =~
             "Your Ansible settings permissions changed"

    assert render_click(release_view, "release_membership", %{}) =~
             "Your Ansible settings permissions changed"

    assert render_click(bindings_view, "create_binding", %{}) =~
             "Your Ansible settings permissions changed"

    assert render_click(bindings_view, "confirm_revoke_binding", %{
             "revoke" => %{"id" => @binding_id, "confirmation_id" => @binding_id}
           }) =~ "Your Ansible settings permissions changed"

    render_async(bindings_view)
    render_async(bulk_view)
    refute_receive {:approve, _, _, _}
    refute_receive {:release, _, _, _}
    refute_receive {:create, _, _}
    refute_receive {:revoke, _, _, _}
  end

  defp log_in_admin(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, user), user: user}
  end

  # The documented approval body for a row as the fixtures below display it.
  defp shown_tuple(controller_id, awx_host_id, device_uid) do
    %{
      "controller_id" => controller_id,
      "inventory_id" => 7,
      "awx_host_id" => awx_host_id,
      "canonical_device_uid" => device_uid,
      "source_generation" => "7",
      "source_fingerprint" => @fingerprint_a,
      "link_evidence_digest" => @evidence_digest
    }
  end

  defp select_template(view, controller) do
    view
    |> form("#ansible-binding-scope-form", %{controller_id: controller.id, template_id: "42"})
    |> render_change()

    assert has_element?(view, "#ansible-binding-versions")
  end

  defp proposed(controller_id) do
    membership(controller_id, @proposed_id, 101, "host01.example.com", :proposed, @device_uid, 1)
  end

  defp second(controller_id) do
    membership(controller_id, @second_id, 104, "host04.example.com", :proposed, @second_device_uid, 1)
  end

  defp unlinked(controller_id) do
    membership(controller_id, @unlinked_id, 102, "host02.example.com", :unlinked, nil, 0)
  end

  defp quarantined(controller_id) do
    controller_id
    |> membership(@quarantined_id, 105, "host05.example.com", :quarantined, nil, 1)
    |> Map.merge(%{
      quarantine_reason: :approved_device_changed,
      quarantined_at: ~U[2026-01-02 03:04:05.000000Z]
    })
    |> put_in([:link_evidence, "matching_device_uids"], [@device_uid])
  end

  defp legacy_quarantined(controller_id) do
    controller_id
    |> membership(@legacy_id, 106, "host06.example.com", :quarantined, nil, 0)
    |> Map.merge(%{quarantine_reason: :predates_reason_recording, quarantined_at: nil})
  end

  # The released row as the domain returns it: a proposal awaiting normal review.
  defp released(controller_id) do
    %{
      quarantined(controller_id)
      | link_disposition: :proposed,
        canonical_device_uid: @device_uid,
        quarantine_reason: nil,
        quarantined_at: nil,
        source_generation: "8",
        source_fingerprint: @fingerprint_c
    }
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

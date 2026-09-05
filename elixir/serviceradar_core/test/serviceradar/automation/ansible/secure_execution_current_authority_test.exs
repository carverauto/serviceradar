defmodule ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthorityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority
  alias ServiceRadar.Automation.Ansible.Targeting

  @now ~U[2026-07-13 13:00:00.000000Z]
  @user_id "018f3f56-1111-7222-8333-123456789ab1"
  @profile_id "018f3f56-1111-7222-8333-123456789ab2"
  @operation_id "018f3f56-1111-7222-8333-123456789ab3"
  @execution_id "018f3f56-1111-7222-8333-123456789ab4"
  @controller_id "018f3f56-1111-7222-8333-123456789ab5"
  @binding_id "018f3f56-1111-7222-8333-123456789ab6"
  @membership_id "018f3f56-1111-7222-8333-123456789ab7"
  @approval_id "018f3f56-1111-7222-8333-123456789ab8"
  @source_fingerprint "sha256:" <> String.duplicate("d", 64)

  defmodule Source do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority.Source

    @impl true
    def load_principal(_type, _principal_id, _owner_id), do: result(:principal)

    @impl true
    def load_memberships(_membership_ids), do: result(:memberships)

    @impl true
    def load_current_binding(_controller_id, _job_template_id), do: result(:binding)

    @impl true
    def active_holds(_device_uids), do: result(:holds)

    defp result(key),
      do: {:ok, :secure_execution_authority_fixture |> Process.get() |> Map.fetch!(key)}
  end

  setup do
    fixture = fixture()
    Process.put(:secure_execution_authority_fixture, fixture)
    %{fixture: fixture}
  end

  test "reconstructs the exact initiating user's current dispatch authority", %{fixture: fixture} do
    assert :ok = authorize(fixture)
  end

  test "rechecks a legacy singular-profile operation through launch", %{fixture: fixture} do
    owner = fixture.principal.owner
    [profile_version] = fixture.principal.authority.profile_versions

    legacy_authorization_version =
      Targeting.snapshot_digest(%{
        "actor_id" => owner.id,
        "actor_status" => "active",
        "actor_role" => "operator",
        "actor_updated_at" => DateTime.to_iso8601(owner.updated_at),
        "profile_id" => profile_version.id,
        "profile_updated_at" => DateTime.to_iso8601(profile_version.updated_at),
        "fresh_permissions" => ["ansible.runs.launch"]
      })

    legacy_record =
      put_in(
        fixture.resources.operation.authorization_version,
        legacy_authorization_version
      )

    assert :ok = authorize(legacy_record)
  end

  test "reauthorizes every known-child phase from the immutable initiating authority", %{
    fixture: fixture
  } do
    phases = [
      {:fetch_job, :accepted_job_proof, :dispatching, :dispatching},
      {:fetch_job, :scope_poll, :dispatching, :launching},
      {:fetch_host_summaries, :host_scope_proof, :dispatching, :launching},
      {:fetch_job, :terminal_poll, :running, :running},
      {:fetch_host_summaries, :terminal_confirmation, :running, :running}
    ]

    # Snapshot freshness constrains initial dispatch, not a long-running job;
    # continuation still requires the exact current, unexpired approval.
    issued_at = @now |> DateTime.add(-1_800, :second) |> DateTime.to_iso8601()
    fixture = put_in(fixture.resources.operation.approval_snapshot["issued_at"], issued_at)

    for {stage, purpose, operation_state, execution_state} <- phases do
      current =
        fixture
        |> put_in([:resources, :operation, :state], operation_state)
        |> put_in([:resources, :execution, :state], execution_state)

      assert :ok = authorize_attempt(current, %{stage: stage, purpose: purpose})
    end
  end

  test "continuations fail closed on phase drift and current permission contraction", %{
    fixture: fixture
  } do
    running =
      fixture
      |> put_in([:resources, :operation, :state], :running)
      |> put_in([:resources, :execution, :state], :running)

    attempt = %{stage: :fetch_job, purpose: :terminal_poll}

    assert {:error, :run_not_active} =
             running
             |> put_in([:resources, :operation, :state], :dispatching)
             |> authorize_attempt(attempt)

    assert {:error, :current_permission_denied} =
             running
             |> put_in([:principal, :authority, :permissions], MapSet.new())
             |> authorize_attempt(attempt)
  end

  test "denies launch after current permission contraction", %{fixture: fixture} do
    contracted = put_in(fixture.principal.authority.permissions, MapSet.new())
    assert {:error, :current_permission_denied} = authorize(contracted)
  end

  test "profile-version ordering is stable and either contributing profile invalidates launch", %{
    fixture: fixture
  } do
    first = hd(fixture.principal.authority.profile_versions)

    second = %{
      id: "018f3f56-1111-7222-8333-123456789ac1",
      updated_at: ~U[2026-07-13 12:06:00.000000Z]
    }

    issued = with_authority_versions(fixture, [first, second])

    assert :ok =
             issued
             |> put_in([:principal, :authority, :profile_versions], [second, first])
             |> authorize()

    assert {:error, :principal_changed} =
             issued
             |> put_in(
               [:principal, :authority, :profile_versions, Access.at(0), :updated_at],
               DateTime.add(first.updated_at, 1)
             )
             |> authorize()

    assert {:error, :principal_changed} =
             issued
             |> put_in(
               [:principal, :authority, :profile_versions, Access.at(1), :updated_at],
               DateTime.add(second.updated_at, 1)
             )
             |> authorize()
  end

  test "denies launch after actor, approval, membership, or hold contraction", %{
    fixture: fixture
  } do
    assert {:error, :principal_disabled} =
             fixture
             |> put_in([:principal, :owner, :status], :disabled)
             |> authorize()

    assert {:error, :approval_changed} =
             fixture
             |> put_in([:binding, :approval_state], :revoked)
             |> authorize()

    assert {:error, :target_no_longer_authorized} =
             fixture
             |> put_in([:memberships, Access.at(0), :current], false)
             |> authorize()

    assert {:error, :target_policy_changed} =
             fixture
             |> Map.put(:holds, [%{id: "hold-1"}])
             |> authorize()
  end

  test "denies launch when immutable binding or target evidence drifts", %{fixture: fixture} do
    assert {:error, :awx_binding_changed} =
             fixture
             |> put_in([:binding, :scm_revision], String.duplicate("f", 40))
             |> authorize()

    assert {:error, :target_no_longer_authorized} =
             fixture
             |> put_in([:memberships, Access.at(0), :source_generation], 8)
             |> authorize()
  end

  test "denies launch when the membership source fingerprint drifts", %{fixture: fixture} do
    assert {:error, :target_no_longer_authorized} =
             fixture
             |> put_in(
               [:memberships, Access.at(0), :source_fingerprint],
               "sha256:" <> String.duplicate("e", 64)
             )
             |> authorize()
  end

  defp authorize(fixture) do
    Process.put(:secure_execution_authority_fixture, fixture)

    SecureExecutionCurrentAuthority.authorize_launch(fixture.resources, @now, source: Source)
  end

  defp authorize_attempt(fixture, attempt) do
    Process.put(:secure_execution_authority_fixture, fixture)

    SecureExecutionCurrentAuthority.authorize_attempt(
      attempt,
      fixture.resources,
      @now,
      source: Source
    )
  end

  defp with_authority_versions(fixture, profile_versions) do
    owner = fixture.principal.owner

    authorization_version =
      Targeting.snapshot_digest(%{
        "actor_id" => owner.id,
        "actor_status" => "active",
        "actor_role" => "operator",
        "actor_updated_at" => DateTime.to_iso8601(owner.updated_at),
        "profile_versions" =>
          profile_versions
          |> Enum.map(&{&1.id, DateTime.to_iso8601(&1.updated_at)})
          |> Enum.sort(),
        "fresh_permissions" => ["ansible.runs.launch"]
      })

    fixture
    |> put_in([:principal, :authority, :profile_versions], profile_versions)
    |> put_in([:resources, :operation, :authorization_version], authorization_version)
  end

  defp fixture do
    actor_updated_at = ~U[2026-07-13 12:00:00.000000Z]
    profile_updated_at = ~U[2026-07-13 12:05:00.000000Z]
    permissions = ["ansible.runs.launch"]

    owner = %{
      id: @user_id,
      status: :active,
      role: :operator,
      tenant_id: "platform",
      updated_at: actor_updated_at
    }

    authority = %{
      permissions: MapSet.new(permissions),
      profile_versions: [%{id: @profile_id, updated_at: profile_updated_at}]
    }

    authorization_version =
      Targeting.snapshot_digest(%{
        "actor_id" => @user_id,
        "actor_status" => "active",
        "actor_role" => "operator",
        "actor_updated_at" => DateTime.to_iso8601(actor_updated_at),
        "profile_versions" => [{@profile_id, DateTime.to_iso8601(profile_updated_at)}],
        "fresh_permissions" => permissions
      })

    approval_expires_at = DateTime.add(@now, 3_600, :second)
    reviewed_at = DateTime.add(@now, -3_600, :second)
    review_metadata = %{"review_ticket" => "SEC-42"}

    approval_snapshot = %{
      "binding_id" => @binding_id,
      "binding_version" => 3,
      "approval_id" => @approval_id,
      "approval_expires_at" => DateTime.to_iso8601(approval_expires_at),
      "reviewed_by_principal_type" => :human,
      "reviewed_by_principal_id" => @user_id,
      "reviewed_at" => DateTime.to_iso8601(reviewed_at),
      "review_metadata" => review_metadata,
      "issued_at" => DateTime.to_iso8601(@now)
    }

    binding = %{
      id: @binding_id,
      binding_version: 3,
      current: true,
      approval_state: :approved,
      approval_id: @approval_id,
      approval_expires_at: approval_expires_at,
      reviewed_by_principal_type: :human,
      reviewed_by_principal_id: @user_id,
      reviewed_at: reviewed_at,
      review_metadata: review_metadata,
      controller_id: @controller_id,
      job_template_id: 42,
      allowed_inventory_ids: [34],
      project_update_on_launch: false,
      ask_limit_on_launch: true,
      dispatch_markers_retained: true,
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      content_sha256: String.duplicate("b", 64),
      execution_environment_id: 4,
      credentials: [%{"id" => 5, "kind" => "ssh"}],
      machine_credential_id: 5,
      run_mode_supported: true,
      check_mode_supported: false,
      callback_actions: []
    }

    target = %{
      membership_id: @membership_id,
      controller_id: @controller_id,
      inventory_id: 34,
      awx_host_id: 7,
      canonical_device_uid: "sr:device-7",
      host_name: "farm01-node01",
      ansible_host: "192.168.2.22",
      membership_generation: 7,
      source_fingerprint: @source_fingerprint
    }

    digest_target = %{
      controller_id: @controller_id,
      inventory_id: 34,
      awx_host_id: 7,
      device_uid: "sr:device-7",
      awx_host_name: "farm01-node01",
      ansible_host: "192.168.2.22"
    }

    target = Map.put(target, :snapshot_digest, Targeting.snapshot_digest(target))
    target_digest = Targeting.target_digest([digest_target])
    snapshot_digest = String.duplicate("c", 64)

    operation = %{
      id: @operation_id,
      tenant_id: "platform",
      action: "ansible.playbook.run",
      state: :dispatching,
      initiator_principal_type: :human,
      initiator_principal_id: @user_id,
      service_principal_owner_id: nil,
      authorization_version: authorization_version,
      authority_ceiling: %{
        "permissions" => permissions,
        "target_membership_ids" => [@membership_id]
      },
      approval_snapshot: approval_snapshot,
      target_digest: target_digest,
      callback_actions: [],
      metadata: %{"snapshot_digest" => snapshot_digest}
    }

    execution = %{
      id: @execution_id,
      operation_id: @operation_id,
      controller_id: @controller_id,
      state: :dispatching,
      inventory_id: 34,
      job_template_id: 42,
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      content_sha256: String.duplicate("b", 64),
      execution_environment_id: 4,
      machine_credential_id: 5,
      credential_snapshot: %{
        "credentials" => [%{"id" => 5, "kind" => "ssh"}],
        "credential_ids" => [5]
      },
      check_mode: false,
      host_limit: "farm01-node01",
      snapshot_digest: snapshot_digest,
      metadata: %{"target_digest" => target_digest}
    }

    membership = %{
      id: @membership_id,
      current: true,
      enabled: true,
      link_disposition: :approved,
      controller_id: @controller_id,
      inventory_id: 34,
      awx_host_id: 7,
      canonical_device_uid: "sr:device-7",
      host_name: "farm01-node01",
      ansible_host: "192.168.2.22",
      source_generation: 7,
      source_fingerprint: @source_fingerprint
    }

    %{
      resources: %{
        operation: operation,
        execution: execution,
        controller: %{id: @controller_id},
        targets: [target]
      },
      principal: %{principal: owner, owner: owner, authority: authority},
      memberships: [membership],
      binding: binding,
      holds: []
    }
  end
end

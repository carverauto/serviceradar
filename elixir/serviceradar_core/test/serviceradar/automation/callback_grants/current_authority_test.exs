defmodule ServiceRadar.Automation.CallbackGrants.CurrentAuthorityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.Targeting
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.CallbackGrants.CurrentAuthority

  @action "remote_access.ssh_ca.bundle.read"
  @permissions ["ansible.runs.launch", "devices.remote_access.ssh.ca_bundle.read"]
  @now ~U[2026-07-12 22:00:00.000000Z]
  @source_fingerprint "sha256:" <> String.duplicate("d", 64)

  defmodule Source do
    @moduledoc false
    @behaviour ServiceRadar.Automation.CallbackGrants.CurrentAuthoritySource

    def load_principal(_type, _id, _owner_id), do: result(:principal)
    def load_operation(_id), do: result(:operation)
    def load_execution(_id), do: result(:execution)
    def load_execution_targets(_id), do: result(:execution_targets)
    def load_memberships(_ids), do: result(:memberships)
    def load_current_binding(_controller_id, _template_id), do: result(:binding)
    def active_holds(_device_uids), do: result(:holds)
    def callback_credential_contract, do: result(:callback_contract)

    defp result(key), do: {:ok, :current_authority_fixture |> Process.get() |> Map.fetch!(key)}
  end

  defmodule PolicyProvider do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.CallbackResponsePolicyProvider

    @impl true
    def snapshot(context) do
      fixture = Process.get(:current_authority_fixture)
      configured = Map.fetch!(fixture, :response_policy_targets)
      expected = Map.fetch!(context, :targets)

      if target_scopes(configured) == target_scopes(expected) do
        {:ok, %{"targets" => configured}}
      else
        {:error, :callback_response_target_scope_mismatch}
      end
    end

    defp target_scopes(targets) do
      targets
      |> Enum.map(fn target ->
        identity = target["target_identity"] || target[:target_identity]

        {
          identity["controller_id"] || identity[:controller_id],
          identity["inventory_id"] || identity[:inventory_id],
          identity["awx_host_id"] || identity[:awx_host_id],
          identity["canonical_device_uid"] || identity[:canonical_device_uid],
          target["inventory_hostname"] || target[:inventory_hostname],
          target["inventory_address"] || target[:inventory_address]
        }
      end)
      |> Enum.sort()
    end
  end

  setup do
    fixture = fixture()
    Process.put(:current_authority_fixture, fixture)
    %{fixture: fixture}
  end

  test "reconstructs only the initiating user's fresh exact authority", %{fixture: fixture} do
    assert {:ok, authority} = authorize(fixture)
    assert authority.principal_type == :human
    assert authority.principal_id == fixture.principal.owner.id
    assert authority.permissions == @permissions
    assert authority.job_id == fixture.execution.awx_job_id
    assert authority.run_state == :running
    assert authority.job_state == :running
  end

  test "rechecks a legacy singular-profile grant and operation together", %{fixture: fixture} do
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
        "fresh_permissions" => @permissions
      })

    legacy_records =
      fixture
      |> put_in([:grant, :authorization_version], legacy_authorization_version)
      |> put_in([:operation, :authorization_version], legacy_authorization_version)

    assert {:ok, _authority} = authorize(:activate, legacy_records)
  end

  test "activation fails closed while the accepted execution is only launching", %{
    fixture: fixture
  } do
    launching =
      fixture
      |> put_in([:execution, :state], :launching)
      |> put_in([:execution, :scope_verified_at], nil)

    assert {:error, :job_not_active} = authorize(:activate, launching)

    missing_durable_marker = put_in(fixture.execution.scope_verified_at, nil)
    assert {:error, :job_not_active} = authorize(:activate, missing_durable_marker)
  end

  test "activation accepts the exact durably scope-verified execution", %{fixture: fixture} do
    assert {:ok, authority} = authorize(:activate, fixture)
    assert authority.job_id == 9_001
    assert authority.job_state == :running
  end

  test "use preserves fresh verification after the execution advances to running", %{
    fixture: fixture
  } do
    running = put_in(fixture.execution.state, :running)
    assert {:ok, authority} = authorize(:use, running)
    assert authority.job_state == :running
  end

  test "activation rejects stale or mismatched persisted scope evidence", %{fixture: fixture} do
    stale =
      put_in(
        fixture.execution.accepted_job_snapshot["scope_verification"]["snapshot_digest"],
        String.duplicate("f", 64)
      )

    assert {:error, :awx_binding_changed} = authorize(:activate, stale)

    mismatched =
      put_in(
        fixture.execution.accepted_job_snapshot["scope_verification"]["observed_host_ids"],
        [101]
      )

    assert {:error, :target_no_longer_authorized} = authorize(:activate, mismatched)

    incomplete_snapshot =
      update_in(fixture.execution.accepted_job_snapshot, &Map.delete(&1, "credentials"))

    assert {:error, :awx_binding_changed} = authorize(:activate, incomplete_snapshot)
  end

  test "activation rejects a proposed job binding that differs from the persisted job", %{
    fixture: fixture
  } do
    mismatched = put_in(fixture.grant.job_binding["job_id"], 9_002)
    assert {:error, :job_binding_changed} = authorize(:activate, mismatched)

    mismatched_full_binding =
      put_in(fixture.grant.job_binding["controller_id"], "another-controller")

    assert {:error, :job_binding_changed} = authorize(:activate, mismatched_full_binding)
  end

  test "activation rechecks current authority contraction", %{fixture: fixture} do
    contracted =
      put_in(fixture.principal.authority.permissions, MapSet.new(["ansible.runs.launch"]))

    assert {:error, :current_permission_denied} = authorize(:activate, contracted)
  end

  test "profile-version ordering is stable and either contributing profile invalidates recheck",
       %{
         fixture: fixture
       } do
    first = hd(fixture.principal.authority.profile_versions)

    second = %{
      id: "0190a4c2-1000-7000-8000-00000000000b",
      updated_at: ~U[2026-07-12 20:03:00.000000Z]
    }

    issued = with_authority_versions(fixture, [first, second])

    reordered = put_in(issued.principal.authority.profile_versions, [second, first])
    assert {:ok, _authority} = authorize(:activate, reordered)

    first_changed =
      put_in(
        issued,
        [:principal, :authority, :profile_versions, Access.at(0), :updated_at],
        DateTime.add(first.updated_at, 1)
      )

    assert {:error, :principal_changed} = authorize(:activate, first_changed)

    second_changed =
      put_in(
        issued,
        [:principal, :authority, :profile_versions, Access.at(1), :updated_at],
        DateTime.add(second.updated_at, 1)
      )

    assert {:error, :principal_changed} = authorize(:activate, second_changed)
  end

  test "pre-launch reconstruction rejects a disabled initiating principal", %{
    fixture: fixture
  } do
    disabled = put_in(fixture.principal.owner.status, :disabled)
    assert {:error, :principal_disabled} = authorize(:bind_job, disabled)
  end

  test "pre-launch reconstruction requires every callback permission", %{fixture: fixture} do
    for missing <- @permissions do
      remaining = @permissions -- [missing]
      contracted = put_in(fixture.principal.authority.permissions, MapSet.new(remaining))
      assert {:error, :current_permission_denied} = authorize(:bind_job, contracted)
    end
  end

  test "pre-launch reconstruction rejects target and reviewed-binding drift", %{
    fixture: fixture
  } do
    [membership] = fixture.memberships

    target_drift =
      %{fixture | memberships: [%{membership | source_generation: "generation-8"}]}

    assert {:error, :target_no_longer_authorized} = authorize(:bind_job, target_drift)

    binding_drift = put_in(fixture.binding.callback_credential_organization_id, 3)
    assert {:error, :awx_binding_changed} = authorize(:bind_job, binding_drift)

    prompt_drift = put_in(fixture.binding.ask_credential_on_launch, false)
    assert {:error, :awx_binding_changed} = authorize(:bind_job, prompt_drift)
  end

  test "fails closed after permission contraction", %{fixture: fixture} do
    contracted =
      put_in(fixture.principal.authority.permissions, MapSet.new(["ansible.runs.launch"]))

    assert {:error, :current_permission_denied} = authorize(contracted)
  end

  test "fails closed across tenant drift", %{fixture: fixture} do
    drifted = put_in(fixture.operation.tenant_id, "another-tenant")
    assert {:error, :tenant_changed} = authorize(drifted)
  end

  test "fails closed when exact target membership generation drifts", %{fixture: fixture} do
    [membership] = fixture.memberships
    drifted = %{fixture | memberships: [%{membership | source_generation: "generation-8"}]}
    assert {:error, :target_no_longer_authorized} = authorize(drifted)
  end

  test "fails closed when exact target membership source fingerprint drifts", %{fixture: fixture} do
    [membership] = fixture.memberships

    drifted = %{
      fixture
      | memberships: [
          %{membership | source_fingerprint: "sha256:" <> String.duplicate("e", 64)}
        ]
    }

    assert {:error, :target_no_longer_authorized} = authorize(drifted)
  end

  test "fails closed when the accepted AWX child no longer proves the target set", %{
    fixture: fixture
  } do
    drifted =
      put_in(
        fixture.execution.accepted_job_snapshot["scope_verification"]["observed_host_ids"],
        [101]
      )

    assert {:error, :target_no_longer_authorized} = authorize(drifted)
  end

  test "fails closed on reviewed callback organization or injector drift", %{fixture: fixture} do
    organization_drift = put_in(fixture.binding.callback_credential_organization_id, 3)
    assert {:error, :awx_binding_changed} = authorize(organization_drift)

    injector_drift =
      put_in(fixture.binding.callback_credential_injector_digest, String.duplicate("9", 64))

    assert {:error, :awx_binding_changed} = authorize(injector_drift)
  end

  test "validates the complete immutable approval snapshot against the current binding", %{
    fixture: fixture
  } do
    missing_reviewer = put_in(fixture.binding.reviewed_by_principal_id, nil)
    assert {:error, :approval_changed} = authorize(missing_reviewer)

    stale =
      fixture
      |> put_in(
        [:grant, :approval_snapshot, "issued_at"],
        DateTime.to_iso8601(DateTime.add(@now, -301))
      )
      |> redigest(:approval_snapshot, :approval_digest)

    assert {:error, :approval_changed} = authorize(stale)

    unexpected =
      fixture
      |> put_in([:grant, :approval_snapshot, "unexpected"], true)
      |> redigest(:approval_snapshot, :approval_digest)

    assert {:error, :approval_changed} = authorize(unexpected)
  end

  test "validates the versioned callback policy snapshot against current approval facts", %{
    fixture: fixture
  } do
    changed =
      fixture
      |> put_in([:grant, :policy_snapshot, "approval_state"], "revoked")
      |> redigest(:policy_snapshot, :policy_digest)

    assert {:error, :target_policy_changed} = authorize(changed)

    unversioned =
      fixture
      |> update_in([:grant, :policy_snapshot], &Map.delete(&1, "schema"))
      |> redigest(:policy_snapshot, :policy_digest)

    assert {:error, :target_policy_changed} = authorize(unversioned)
  end

  test "fails closed when the server-owned CA or principal policy changes", %{
    fixture: fixture
  } do
    changed =
      update_in(fixture.response_policy_targets, fn [target] ->
        [put_in(target["accounts"], [%{"name" => "operator", "principals" => [principal()]}])]
      end)

    assert {:error, :target_policy_changed} =
             authorize(%{fixture | response_policy_targets: changed})
  end

  test "fails closed while a target policy hold is active", %{fixture: fixture} do
    assert {:error, :target_policy_changed} = authorize(%{fixture | holds: [%{id: "hold-1"}]})
  end

  test "reconstructs an owned service principal without borrowing system authority", %{
    fixture: fixture
  } do
    service_fixture = service_principal_fixture(fixture)

    assert {:ok, authority} = authorize(service_fixture)
    assert authority.principal_type == :service_principal
    assert authority.principal_owner_id == fixture.principal.owner.id
    assert authority.permissions == @permissions

    contracted = put_in(service_fixture.principal.principal.scopes, ["read"])
    assert {:error, :current_permission_denied} = authorize(contracted)
  end

  defp authorize(fixture) do
    authorize(:use, fixture)
  end

  defp authorize(stage, fixture) do
    Process.put(:current_authority_fixture, fixture)

    CurrentAuthority.current_authority(stage, fixture.grant,
      source: Source,
      response_policy_provider: PolicyProvider,
      now: @now
    )
  end

  defp service_principal_fixture(fixture) do
    owner = fixture.principal.owner
    authority = fixture.principal.authority

    client = %{
      id: "0190a4c2-1000-7000-8000-00000000000a",
      user_id: owner.id,
      scopes: ["write"],
      enabled: true,
      revoked_at: nil,
      expires_at: DateTime.add(@now, 3_600),
      updated_at: ~U[2026-07-12 20:02:00.000000Z]
    }

    authorization_version =
      Targeting.snapshot_digest(%{
        "schema" => "serviceradar.service_principal_authorization.v1",
        "service_principal_id" => client.id,
        "service_principal_owner_id" => owner.id,
        "service_principal_updated_at" => DateTime.to_iso8601(client.updated_at),
        "service_principal_scopes" => ["write"],
        "owner_status" => "active",
        "owner_role" => "operator",
        "owner_updated_at" => DateTime.to_iso8601(owner.updated_at),
        "profile_versions" =>
          Enum.map(authority.profile_versions, fn version ->
            {version.id, DateTime.to_iso8601(version.updated_at)}
          end),
        "fresh_permissions" => @permissions
      })

    fixture
    |> put_in([:principal], %{principal: client, owner: owner, authority: authority})
    |> put_in([:grant, :principal_type], :service_principal)
    |> put_in([:grant, :principal_id], client.id)
    |> put_in([:grant, :principal_owner_id], owner.id)
    |> put_in([:grant, :authorization_version], authorization_version)
    |> put_in([:operation, :initiator_principal_type], :service_principal)
    |> put_in([:operation, :initiator_principal_id], client.id)
    |> put_in([:operation, :service_principal_owner_id], owner.id)
    |> put_in([:operation, :authorization_version], authorization_version)
  end

  defp with_authority_versions(fixture, profile_versions) do
    authorization_version =
      Targeting.snapshot_digest(%{
        "actor_id" => fixture.principal.owner.id,
        "actor_status" => "active",
        "actor_role" => "operator",
        "actor_updated_at" => DateTime.to_iso8601(fixture.principal.owner.updated_at),
        "profile_versions" =>
          profile_versions
          |> Enum.map(&{&1.id, DateTime.to_iso8601(&1.updated_at)})
          |> Enum.sort(),
        "fresh_permissions" => @permissions
      })

    fixture
    |> put_in([:principal, :authority, :profile_versions], profile_versions)
    |> put_in([:grant, :authorization_version], authorization_version)
    |> put_in([:operation, :authorization_version], authorization_version)
  end

  defp redigest(fixture, snapshot_key, digest_key) do
    {:ok, digest} = CanonicalJSON.digest(get_in(fixture, [:grant, snapshot_key]))
    put_in(fixture, [:grant, digest_key], digest)
  end

  defp fixture do
    ids = %{
      user: "0190a4c2-1000-7000-8000-000000000001",
      profile: "0190a4c2-1000-7000-8000-000000000002",
      operation: "0190a4c2-1000-7000-8000-000000000003",
      execution: "0190a4c2-1000-7000-8000-000000000004",
      controller: "0190a4c2-1000-7000-8000-000000000005",
      binding: "0190a4c2-1000-7000-8000-000000000006",
      membership: "0190a4c2-1000-7000-8000-000000000007",
      approval: "0190a4c2-1000-7000-8000-000000000008"
    }

    owner = %{
      id: ids.user,
      status: :active,
      role: :operator,
      updated_at: ~U[2026-07-12 20:00:00.000000Z]
    }

    authority = %{
      permissions: MapSet.new(@permissions),
      profile_versions: [%{id: ids.profile, updated_at: ~U[2026-07-12 20:01:00.000000Z]}]
    }

    authorization_version =
      Targeting.snapshot_digest(%{
        "actor_id" => owner.id,
        "actor_status" => "active",
        "actor_role" => "operator",
        "actor_updated_at" => DateTime.to_iso8601(owner.updated_at),
        "profile_versions" =>
          Enum.map(authority.profile_versions, fn version ->
            {version.id, DateTime.to_iso8601(version.updated_at)}
          end),
        "fresh_permissions" => @permissions
      })

    membership = %{
      id: ids.membership,
      controller_id: ids.controller,
      inventory_id: 34,
      awx_host_id: 100,
      canonical_device_uid: "device:linux-01",
      host_name: "linux-01",
      ansible_host: "192.168.2.22",
      source_generation: "generation-7",
      source_fingerprint: @source_fingerprint,
      current: true,
      enabled: true,
      link_disposition: :approved
    }

    target = %{
      membership_id: membership.id,
      controller_id: membership.controller_id,
      inventory_id: membership.inventory_id,
      awx_host_id: membership.awx_host_id,
      canonical_device_uid: membership.canonical_device_uid,
      device_uid: membership.canonical_device_uid,
      host_name: membership.host_name,
      awx_host_name: membership.host_name,
      ansible_host: membership.ansible_host,
      membership_generation: membership.source_generation,
      source_fingerprint: membership.source_fingerprint
    }

    target_snapshot =
      Map.take(target, [
        :membership_id,
        :canonical_device_uid,
        :controller_id,
        :inventory_id,
        :awx_host_id,
        :membership_generation,
        :source_fingerprint,
        :host_name,
        :ansible_host
      ])

    target_digest = Targeting.target_digest([target])
    snapshot_digest = String.duplicate("e", 64)
    injector_digest = String.duplicate("c", 64)

    scope = %{
      "controller_id" => ids.controller,
      "inventory_id" => 34,
      "job_template_id" => 42,
      "project_id" => 3,
      "scm_revision" => String.duplicate("a", 40),
      "content_sha256" => String.duplicate("b", 64),
      "execution_environment_id" => 4,
      "machine_credential_id" => 5,
      "credential_ids" => [5],
      "ask_credential_on_launch" => true,
      "callback_credential_type_id" => 6,
      "callback_credential_organization_id" => 2,
      "callback_credential_injector_digest" => injector_digest,
      "host_limit" => "linux-01",
      "target_count" => 1,
      "target_digest" => target_digest,
      "snapshot_digest" => snapshot_digest,
      "targets" => [
        %{
          "membership_id" => membership.id,
          "controller_id" => membership.controller_id,
          "inventory_id" => membership.inventory_id,
          "awx_host_id" => membership.awx_host_id,
          "canonical_device_uid" => membership.canonical_device_uid,
          "host_name" => membership.host_name,
          "ansible_host" => membership.ansible_host,
          "membership_generation" => membership.source_generation,
          "source_fingerprint" => membership.source_fingerprint
        }
      ],
      "binding_id" => ids.binding,
      "awx_created_by_id" => 11
    }

    binding = %{
      id: ids.binding,
      binding_version: 7,
      controller_id: ids.controller,
      job_template_id: 42,
      allowed_inventory_ids: [34],
      current: true,
      approval_state: :approved,
      approval_id: ids.approval,
      approval_expires_at: DateTime.add(@now, 3_600),
      reviewed_by_principal_type: :human,
      reviewed_by_principal_id: ids.user,
      reviewed_at: DateTime.add(@now, -3_600),
      callback_actions: [@action],
      ask_credential_on_launch: true,
      callback_credential_type_id: 6,
      callback_credential_organization_id: 2,
      callback_credential_injector_digest: injector_digest,
      callback_credential_slot: "ssh_ca_callback",
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      content_sha256: String.duplicate("b", 64),
      execution_environment_id: 4,
      machine_credential_id: 5,
      credentials: [%{"id" => 5, "kind" => "ssh"}],
      awx_created_by_id: 11,
      review_metadata: %{
        "policy_version" => "ssh-policy-v3",
        "ticket" => "SEC-1234"
      }
    }

    execution = %{
      id: ids.execution,
      operation_id: ids.operation,
      controller_id: ids.controller,
      inventory_id: 34,
      job_template_id: 42,
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      content_sha256: String.duplicate("b", 64),
      execution_environment_id: 4,
      machine_credential_id: 5,
      credential_snapshot: %{
        "credential_ids" => [5],
        "dynamic_callback_slot" => "ssh_ca_callback"
      },
      host_limit: "linux-01",
      snapshot_digest: snapshot_digest,
      dispatch_id: "dispatch-1",
      awx_job_id: 9_001,
      state: :scope_verified,
      scope_verified_at: DateTime.add(@now, -30),
      metadata: %{"awx_created_by_id" => 11, "target_digest" => target_digest},
      accepted_job_snapshot: %{
        "controller_id" => ids.controller,
        "awx_job_id" => 9_001,
        "job_template_id" => 42,
        "inventory_id" => 34,
        "host_limit" => "linux-01",
        "project_id" => 3,
        "scm_revision" => String.duplicate("a", 40),
        "execution_environment_id" => 4,
        "awx_created_by_id" => 11,
        "serviceradar_dispatch_id" => "dispatch-1",
        "serviceradar_snapshot_digest" => snapshot_digest,
        "credentials" => [
          %{"id" => 5, "kind" => "ssh"},
          %{"id" => 91, "kind" => "cloud"}
        ],
        "credential_ids" => [5, 91],
        "ephemeral_credential_id" => 91,
        "job_type" => "run",
        "scope_verification" => %{
          "schema" => "serviceradar.awx_scope_verification.v1",
          "execution_id" => ids.execution,
          "controller_id" => ids.controller,
          "awx_job_id" => 9_001,
          "inventory_id" => 34,
          "expected_host_ids" => [100],
          "observed_host_ids" => [100],
          "snapshot_digest" => snapshot_digest
        }
      }
    }

    {:ok, scope_digest} = CanonicalJSON.digest(scope)

    approval_snapshot = %{
      "binding_id" => binding.id,
      "binding_version" => binding.binding_version,
      "approval_id" => binding.approval_id,
      "approval_expires_at" => DateTime.to_iso8601(binding.approval_expires_at),
      "reviewed_by_principal_type" => "human",
      "reviewed_by_principal_id" => binding.reviewed_by_principal_id,
      "reviewed_at" => DateTime.to_iso8601(binding.reviewed_at),
      "review_metadata" => binding.review_metadata,
      "issued_at" => DateTime.to_iso8601(@now)
    }

    policy_snapshot = %{
      "schema" => "serviceradar.automation_callback_policy/v1",
      "action" => @action,
      "binding_id" => binding.id,
      "binding_version" => binding.binding_version,
      "version" => "ssh-policy-v3",
      "approval_id" => binding.approval_id,
      "approval_state" => "approved",
      "approval_expires_at" => DateTime.to_iso8601(binding.approval_expires_at)
    }

    response_policy_targets = [
      %{
        "inventory_hostname" => membership.host_name,
        "inventory_address" => membership.ansible_host,
        "target_identity" => %{
          "controller_id" => membership.controller_id,
          "inventory_id" => membership.inventory_id,
          "awx_host_id" => membership.awx_host_id,
          "canonical_device_uid" => membership.canonical_device_uid
        },
        "ca_keys" => [
          %{
            "id" => "ca-main",
            "public_key" => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK7Q",
            "fingerprint" => "SHA256:test"
          }
        ],
        "accounts" => [%{"name" => "mfreeman", "principals" => [principal()]}],
        "transaction" => %{}
      }
    ]

    {:ok, response_policy_digest} =
      CanonicalJSON.digest(%{"targets" => response_policy_targets})

    policy_snapshot =
      Map.put(policy_snapshot, "response_policy_digest", response_policy_digest)

    {:ok, approval_digest} = CanonicalJSON.digest(approval_snapshot)

    {:ok, policy_digest} = CanonicalJSON.digest(policy_snapshot)

    grant = %{
      id: "0190a4c2-1000-7000-8000-000000000009",
      state: :active,
      tenant_id: "platform",
      parent_run_id: ids.operation,
      execution_id: ids.execution,
      principal_type: :human,
      principal_id: ids.user,
      principal_owner_id: nil,
      authorization_version: authorization_version,
      action: @action,
      action_version: "1.0.0",
      issued_at: @now,
      awx_scope_snapshot: scope,
      scope_digest: scope_digest,
      approval_digest: approval_digest,
      policy_digest: policy_digest,
      approval_snapshot: approval_snapshot,
      policy_snapshot: policy_snapshot,
      job_binding:
        scope
        |> Map.put("credential_ids", [5, 91])
        |> Map.put("job_id", 9_001),
      ephemeral_credential_id: 91,
      binding_verified: true
    }

    %{
      grant: grant,
      principal: %{principal: owner, owner: owner, authority: authority},
      operation: %{
        id: ids.operation,
        tenant_id: "platform",
        initiator_principal_type: :human,
        initiator_principal_id: ids.user,
        service_principal_owner_id: nil,
        authorization_version: authorization_version,
        state: :running,
        callback_actions: [@action],
        authority_ceiling: %{
          "permissions" => @permissions,
          "target_membership_ids" => [membership.id]
        }
      },
      execution: execution,
      execution_targets: [
        %{
          execution_id: ids.execution,
          membership_id: membership.id,
          controller_id: ids.controller,
          inventory_id: 34,
          awx_host_id: 100,
          canonical_device_uid: "device:linux-01",
          membership_generation: "generation-7",
          source_fingerprint: @source_fingerprint,
          host_name: "linux-01",
          ansible_host: "192.168.2.22",
          snapshot_digest: Targeting.snapshot_digest(target_snapshot)
        }
      ],
      memberships: [membership],
      binding: binding,
      holds: [],
      callback_contract: %{
        credential_type_id: 6,
        organization_id: 2,
        injector_digest: injector_digest
      },
      response_policy_targets: response_policy_targets
    }
  end

  defp principal, do: "srp_v1_0123456789abcdefghijklmnop"
end

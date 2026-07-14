defmodule ServiceRadar.Automation.CallbackGrants.AshStoreTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Automation.CallbackGrants.AshStore
  alias ServiceRadar.Automation.CallbackGrants.Audit
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.Callbacks.Grant
  alias ServiceRadar.Automation.Callbacks.Use

  @migration Path.expand(
               "../../../../priv/repo/migrations/20260712181000_add_automation_callback_grants_foundation.exs",
               __DIR__
             )
  @external_resource @migration

  test "maps the pure lifecycle grant to the explicit private Ash contract" do
    grant = pure_grant()
    assert {:ok, attrs} = AshStore.grant_create_attrs(grant)

    assert attrs.grant_id == grant.id
    assert attrs.operation_id == grant.parent_run_id
    assert attrs.execution_id == grant.execution_id
    assert attrs.controller_id == grant.awx_scope_snapshot.controller_id
    assert attrs.template_binding_id == grant.awx_scope_snapshot.binding_id
    assert attrs.target_membership_ids == [membership_id()]
    assert attrs.token_verifier == grant.verifier_digest
    assert attrs.token_pepper_version == grant.verifier_key_id
    assert attrs.idempotency_key_verifier == grant.idempotency_verifier_digest
    assert attrs.idempotency_pepper_version == grant.idempotency_verifier_key_id
    assert attrs.dispatch_agent_id == "agent-gateway-demo"
    assert attrs.dispatch_partition_id == "farm01"
    assert attrs.launch_envelope_ref == "vault-envelope:callback-grant-1"
    assert attrs.policy_snapshot == grant.policy_snapshot
    assert attrs.target_snapshot["scope_digest"] == grant.scope_digest

    assert attrs.target_snapshot["response"]["manifest_sha256"] ==
             grant.response_snapshot.manifest_sha256

    {:ok, expected_ca_digest} =
      grant.response_snapshot.targets |> hd() |> Map.fetch!(:ca_keys) |> CanonicalJSON.digest()

    assert attrs.ca_key_set_digest == expected_ca_digest
    refute Map.has_key?(attrs, :bearer)
    refute Map.has_key?(attrs, :idempotency_key)
  end

  test "fails closed when any AWX target lacks an exact membership id" do
    grant =
      update_in(pure_grant(), [:awx_scope_snapshot, :targets], fn [target] ->
        [Map.delete(target, :membership_id)]
      end)

    assert {:error, :target_membership_id_required} = AshStore.grant_create_attrs(grant)
  end

  test "pending persistence binds only the reviewed credential type, not an instance" do
    assert {:ok, attrs} = AshStore.grant_create_attrs(pure_grant())
    scope = attrs.target_snapshot["awx_scope"]

    assert scope["callback_credential_type_id"] == 6
    assert scope["callback_credential_organization_id"] == 2
    assert scope["callback_credential_injector_digest"] == String.duplicate("c", 64)
    refute Map.has_key?(scope, "callback_credential_id")
    refute Map.has_key?(attrs, :awx_ephemeral_credential_id)
  end

  test "reconstructs the immutable lifecycle shape and exact job binding" do
    pure = pure_grant()
    {:ok, attrs} = AshStore.grant_create_attrs(pure)
    credential_id = 31

    resource =
      struct!(Grant, %{
        id: grant_id(),
        state: :active,
        operation_id: attrs.operation_id,
        execution_id: attrs.execution_id,
        tenant_id: attrs.tenant_id,
        controller_id: attrs.controller_id,
        template_binding_id: attrs.template_binding_id,
        inventory_id: attrs.inventory_id,
        job_template_id: attrs.job_template_id,
        project_id: attrs.project_id,
        awx_job_id: 9_001,
        scm_revision: attrs.scm_revision,
        content_sha256: attrs.content_sha256,
        action: attrs.action,
        action_version: attrs.action_version,
        audience: attrs.audience,
        initiator_principal_type: attrs.initiator_principal_type,
        initiator_principal_id: attrs.initiator_principal_id,
        authorization_version: attrs.authorization_version,
        authority_ceiling: attrs.authority_ceiling,
        approval_snapshot: attrs.approval_snapshot,
        target_snapshot: attrs.target_snapshot,
        policy_snapshot: attrs.policy_snapshot,
        policy_version: attrs.policy_version,
        policy_digest: attrs.policy_digest,
        token_verifier: attrs.token_verifier,
        token_pepper_version: attrs.token_pepper_version,
        idempotency_key_verifier: attrs.idempotency_key_verifier,
        idempotency_pepper_version: attrs.idempotency_pepper_version,
        budget_limit: 1,
        budget_used: 0,
        dispatch_agent_id: attrs.dispatch_agent_id,
        dispatch_partition_id: attrs.dispatch_partition_id,
        launch_envelope_ref: attrs.launch_envelope_ref,
        awx_ephemeral_credential_id: credential_id,
        credential_cleanup_state: :pending,
        orphan_risk_state: :none,
        issued_at: attrs.issued_at,
        expires_at: attrs.expires_at
      })

    lifecycle = AshStore.to_lifecycle(resource)
    assert lifecycle.binding_verified
    assert lifecycle.job_binding["job_id"] == 9_001
    assert Enum.sort(lifecycle.job_binding["credential_ids"]) == [5, credential_id]
    assert lifecycle.policy_snapshot == pure.policy_snapshot
    assert lifecycle.verifier_digest == pure.verifier_digest
    assert lifecycle.verifier_key_id == pure.verifier_key_id
    assert lifecycle.idempotency_verifier_digest == pure.idempotency_verifier_digest
    assert lifecycle.idempotency_verifier_key_id == pure.idempotency_verifier_key_id
  end

  test "response bytes are private, sensitive, bounded, and committed atomically" do
    response_bytes = Info.attribute(Use, :response_bytes)
    refute response_bytes.public?
    assert response_bytes.sensitive?

    commit = Info.action(Use, :commit_response)
    assert commit.require_atomic?
    assert :response_bytes in commit.accept

    migration = File.read!(@migration)
    assert migration =~ "add(:response_bytes, :binary)"
    assert migration =~ "octet_length(response_bytes) <= 262144"

    assert migration =~
             "state = 'committed' AND budget_sequence > 0 AND response_bytes IS NOT NULL"
  end

  test "post-revocation cleanup can advance orphan risk without restoring authority" do
    cleanup = Info.action(Grant, :record_credential_cleanup)
    assert cleanup.require_atomic?
    assert :orphan_risk_state in cleanup.accept

    revoke = Info.action(Grant, :record_revoked)
    assert revoke.require_atomic?
    assert :orphan_risk_state in revoke.accept
  end

  test "authorization and cleanup views remove all verifier, envelope, and response material" do
    safe =
      Audit.safe_grant(%{
        id: grant_id(),
        verifier_digest: <<1::256>>,
        verifier_key_id: "pepper-v1",
        token_verifier: <<2::256>>,
        token_pepper_version: "pepper-v1",
        idempotency_key_verifier: <<3::256>>,
        idempotency_pepper_version: "pepper-v1",
        idempotency_verifier_digest: <<4::256>>,
        idempotency_verifier_key_id: "pepper-v1",
        launch_envelope_ref: "secret-envelope-reference",
        response_bytes: ~s({"sensitive":"target-policy"}),
        response_reference: "object-store:response-1",
        response_ref: "object-store:response-2",
        committed_response_bytes: "bytes",
        committed_response_reference: "object-store:response-3",
        body: "bytes",
        response_snapshot: %{"targets" => [%{"accounts" => ["internal"]}]},
        policy_snapshot: %{"internal" => true},
        scope_digest: String.duplicate("a", 64)
      })

    assert safe == %{id: grant_id(), scope_digest: String.duplicate("a", 64)}
  end

  defp pure_grant do
    now = ~U[2026-07-12 18:00:00Z]

    target_identity = %{
      controller_id: controller_id(),
      inventory_id: 34,
      awx_host_id: 7,
      canonical_device_uid: "sr:device-7"
    }

    ca_keys = [
      %{
        id: "serviceradar-user-ca-2026",
        public_key:
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZm test",
        fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      }
    ]

    scope = %{
      controller_id: controller_id(),
      inventory_id: 34,
      job_template_id: 42,
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      content_sha256: String.duplicate("b", 64),
      execution_environment_id: 4,
      machine_credential_id: 5,
      credential_ids: [5],
      ask_credential_on_launch: true,
      callback_credential_type_id: 6,
      callback_credential_organization_id: 2,
      callback_credential_injector_digest: String.duplicate("c", 64),
      host_limit: "farm01-pve01",
      target_count: 1,
      target_digest: String.duplicate("d", 64),
      snapshot_digest: String.duplicate("e", 64),
      targets: [
        Map.merge(target_identity, %{
          membership_id: membership_id(),
          host_name: "farm01-pve01",
          ansible_host: "192.168.2.22"
        })
      ],
      binding_id: binding_id(),
      awx_created_by_id: 11
    }

    response = %{
      manifest_sha256: String.duplicate("f", 64),
      phase: "stage",
      operation: "enroll",
      state: "present",
      targets: [
        %{
          inventory_hostname: "farm01-pve01",
          inventory_address: "192.168.2.22",
          target_identity: target_identity,
          ca_keys: ca_keys,
          accounts: [
            %{name: "mfreeman", principals: ["srp_v1_AAAAAAAAAAAAAAAAAAAA"]}
          ],
          transaction: %{
            id: "txn-enroll-1",
            stage_job_id: 8_999,
            generation: "generation-1",
            machine_credential_ref: "awx-credential-ref:linux-demo"
          }
        }
      ]
    }

    approval = %{id: "approval-1", approved: true}
    policy = %{version: "ssh-policy-v3", approved: true}
    {:ok, scope_digest} = CanonicalJSON.digest(scope)
    {:ok, approval_digest} = CanonicalJSON.digest(approval)
    {:ok, policy_digest} = CanonicalJSON.digest(policy)

    %{
      id: grant_id(),
      state: :pending,
      tenant_id: "platform",
      parent_run_id: operation_id(),
      execution_id: execution_id(),
      principal_type: :human,
      principal_id: "018f3f56-1111-7222-8333-123456789abf",
      principal_owner_id: nil,
      authorization_version: "role-v7",
      issuance_ceiling: %{
        permissions: [
          "ansible.runs.launch",
          "devices.remote_access.ssh.ca_bundle.read"
        ],
        actions: ["remote_access.ssh_ca.bundle.read"],
        target_keys: [String.duplicate("9", 64)],
        tenant_id: "platform",
        principal_type: :human,
        principal_id: "018f3f56-1111-7222-8333-123456789abf",
        max_ttl_seconds: 600,
        success_budget: 1
      },
      action: "remote_access.ssh_ca.bundle.read",
      action_version: "1.0.0",
      audience: "serviceradar.awx.callback/v1",
      issued_at: now,
      expires_at: DateTime.add(now, 120),
      budget_total: 1,
      budget_remaining: 1,
      target_keys: [String.duplicate("9", 64)],
      scope_digest: scope_digest,
      approval_digest: approval_digest,
      policy_digest: policy_digest,
      approval_snapshot: approval,
      policy_snapshot: policy,
      policy_version: "ssh-policy-v3",
      awx_scope_snapshot: scope,
      response_snapshot: response,
      binding_verified: false,
      job_binding: nil,
      ephemeral_credential_id: nil,
      dispatch_agent_id: "agent-gateway-demo",
      dispatch_partition_id: "farm01",
      launch_envelope_ref: "vault-envelope:callback-grant-1",
      verifier_digest: <<7::256>>,
      verifier_key_id: "callback-v1",
      idempotency_verifier_digest: <<8::256>>,
      idempotency_verifier_key_id: "callback-v1"
    }
  end

  defp grant_id, do: "018f3f56-1111-7222-8333-123456789abc"
  defp operation_id, do: "018f3f56-1111-7222-8333-123456789abd"
  defp execution_id, do: "018f3f56-1111-7222-8333-123456789abe"
  defp controller_id, do: "018f3f56-1111-7222-8333-123456789ac0"
  defp binding_id, do: "018f3f56-1111-7222-8333-123456789ac1"
  defp membership_id, do: "018f3f56-1111-7222-8333-123456789ac2"
end

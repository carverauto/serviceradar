defmodule ServiceRadar.Automation.Callbacks.FoundationTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Automation.Callbacks.AuditEvent
  alias ServiceRadar.Automation.Callbacks.Grant
  alias ServiceRadar.Automation.Callbacks.TokenVerifier
  alias ServiceRadar.Automation.Callbacks.Use
  alias ServiceRadar.Identity.RBAC.Catalog

  @ca_permission "devices.remote_access.ssh.ca_bundle.read"

  test "callback bearer and idempotency verifiers are private sensitive HMAC values" do
    for {resource, attribute_name} <- [
          {Grant, :token_verifier},
          {Grant, :token_pepper_version},
          {Grant, :idempotency_key_verifier},
          {Grant, :idempotency_pepper_version},
          {Grant, :launch_envelope_ref},
          {Grant, :awx_ephemeral_credential_id},
          {Use, :idempotency_key_verifier},
          {Use, :idempotency_pepper_version},
          {Use, :response_reference},
          {Use, :response_bytes}
        ] do
      attribute = Info.attribute(resource, attribute_name)
      refute attribute.public?
      assert attribute.sensitive?
    end

    token = :crypto.strong_rand_bytes(32)
    pepper = :crypto.strong_rand_bytes(32)

    assert {:ok, %{verifier: verifier, pepper_version: "pepper-2026-07"}} =
             TokenVerifier.derive(token, pepper, "pepper-2026-07")

    assert byte_size(verifier) == 32
    refute verifier == token
    assert TokenVerifier.matches?(token, pepper, verifier)
    refute TokenVerifier.matches?(:crypto.strong_rand_bytes(32), pepper, verifier)
  end

  test "grant binds the exact parent, AWX, content, actor, request, target, policy, and budget ceiling" do
    required = [
      :operation_id,
      :execution_id,
      :tenant_id,
      :controller_id,
      :template_binding_id,
      :inventory_id,
      :job_template_id,
      :project_id,
      :scm_revision,
      :content_sha256,
      :action,
      :action_version,
      :audience,
      :response_schema_version,
      :manifest_sha256,
      :callback_phase,
      :remote_access_operation,
      :desired_state,
      :initiator_principal_type,
      :initiator_principal_id,
      :authorization_version,
      :permission_ceiling,
      :authority_ceiling,
      :approval_snapshot,
      :target_membership_ids,
      :target_snapshot,
      :target_digest,
      :policy_version,
      :policy_snapshot,
      :policy_digest,
      :ca_key_set_digest,
      :token_verifier,
      :token_pepper_version,
      :idempotency_key_verifier,
      :idempotency_pepper_version,
      :budget_limit,
      :idempotency_policy,
      :dispatch_agent_id,
      :launch_envelope_ref,
      :issued_at,
      :expires_at
    ]

    create = Info.action(Grant, :create_pending)
    assert MapSet.subset?(MapSet.new(required), MapSet.new(create.accept))

    assert identity_attributes(Grant, :unique_token_verifier) == [:token_verifier]

    assert identity_attributes(Grant, :unique_idempotency_key_verifier) == [
             :idempotency_key_verifier
           ]

    assert identity_attributes(Grant, :one_live_grant_per_partition) == [
             :execution_id,
             :action,
             :action_version,
             :policy_digest
           ]
  end

  test "the persisted initial deployment cannot widen the reviewed action contract" do
    migration =
      "../../../../priv/repo/migrations/20260712181000_add_automation_callback_grants_foundation.exs"
      |> Path.expand(__DIR__)
      |> File.read!()

    for invariant <- [
          "action = 'remote_access.ssh_ca.bundle.read'",
          "action_version = '1.0.0'",
          "remote_access_operation = 'enroll'",
          "desired_state = 'present'",
          "expires_at <= issued_at + INTERVAL '600 seconds'",
          "budget_limit = 1",
          "cardinality(target_membership_ids) BETWEEN 1 AND 100",
          "octet_length(token_verifier) = 32",
          "octet_length(idempotency_key_verifier) = 32",
          "devices.remote_access.ssh.ca_bundle.read"
        ] do
      assert migration =~ invariant
    end
  end

  test "use records enforce keyed idempotency and one committed response per budget slot" do
    assert identity_attributes(Use, :unique_idempotency_key) == [
             :grant_id,
             :idempotency_key_verifier
           ]

    assert identity_attributes(Use, :unique_committed_budget_slot) == [
             :grant_id,
             :budget_sequence
           ]

    assert Info.action(Use, :commit_response).require_atomic?
    assert Info.action(Grant, :record_consumed).require_atomic?

    refute Info.attribute(Use, :response_reference).public?
    refute Enum.any?(Info.attributes(Use), &(&1.name in [:response_body, :bearer, :token]))
  end

  test "audit evidence is append-only and structurally secret free" do
    action_types = AuditEvent |> Info.actions() |> Enum.map(& &1.type)

    assert :create in action_types
    refute :update in action_types
    refute :destroy in action_types

    forbidden =
      ~w(token bearer verifier secret envelope response_body authorization_header metadata)a

    refute Enum.any?(Info.attributes(AuditEvent), &(&1.name in forbidden))
    assert identity_attributes(AuditEvent, :unique_event_key) == [:grant_id, :event_key]
  end

  test "SSH CA policy distribution is administrator-only by default and assignable by key" do
    assert @ca_permission in Catalog.permission_keys()
    assert MapSet.member?(Catalog.permissions_for_role(:admin), @ca_permission)
    refute MapSet.member?(Catalog.permissions_for_role(:operator), @ca_permission)
    refute MapSet.member?(Catalog.permissions_for_role(:helpdesk), @ca_permission)
    refute MapSet.member?(Catalog.permissions_for_role(:viewer), @ca_permission)
  end

  defp identity_attributes(resource, name) do
    resource
    |> Info.identities()
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:keys)
  end
end

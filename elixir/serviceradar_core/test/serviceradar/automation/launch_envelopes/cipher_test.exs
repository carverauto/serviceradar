defmodule ServiceRadar.Automation.LaunchEnvelopes.CipherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.LaunchEnvelopes.Cipher
  alias ServiceRadar.Automation.LaunchEnvelopes.CommandPayload
  alias ServiceRadar.Automation.LaunchEnvelopes.Context

  @key :binary.copy(<<73>>, 32)
  @bearer Base.url_encode64(:binary.copy(<<19>>, 32), padding: false)
  @idempotency_key "srci_v1_" <>
                     Base.url_encode64(:binary.copy(<<29>>, 32), padding: false)

  test "round trips a callback bearer with every launch coordinate authenticated" do
    context = context!()

    assert {:ok, encrypted} =
             Cipher.encrypt(@bearer, @idempotency_key, context, encryption_key: @key)

    assert {:ok, material} =
             Cipher.decrypt(
               encrypted.ciphertext,
               encrypted.cipher_version,
               context,
               encryption_key: @key
             )

    assert material.bearer == @bearer
    assert material.idempotency_key == @idempotency_key
    assert material.callback_grant_id == context.callback_grant_id

    for {field, value} <- tampered_values(context) do
      tampered = Map.put(context, field, value)

      assert {:error, :launch_envelope_decrypt_failed} =
               Cipher.decrypt(
                 encrypted.ciphertext,
                 encrypted.cipher_version,
                 tampered,
                 encryption_key: @key
               )
    end
  end

  test "rejects malformed callback bearers and envelope references" do
    assert {:error, :invalid_callback_bearer} =
             Cipher.encrypt(
               "ordinary-user-token",
               @idempotency_key,
               context!(),
               encryption_key: @key
             )

    assert {:error, :invalid_launch_envelope_reference} =
             Cipher.reference_verifier("not-an-envelope", encryption_key: @key)

    assert {:error, :invalid_launch_envelope_reference} =
             CommandPayload.build("not-an-envelope")

    assert {:error, :invalid_callback_idempotency_key} =
             Cipher.encrypt(
               @bearer,
               String.replace_prefix(@idempotency_key, "srci_v1_", ""),
               context!(),
               encryption_key: @key
             )
  end

  test "command payload accepts exactly one opaque reference" do
    assert {:ok, reference, _verifier} =
             Cipher.issue_reference(
               encryption_key: @key,
               random_bytes: fn size -> :binary.copy(<<7>>, size) end
             )

    assert {:ok, %{"launch_envelope_ref" => ^reference} = payload} =
             CommandPayload.build(reference)

    assert {:ok, ^reference} = CommandPayload.parse(payload)

    assert {:error, :invalid_launch_envelope_payload} =
             CommandPayload.parse(Map.put(payload, "controller_id", Ecto.UUID.generate()))
  end

  test "context refuses expiry beyond the callback deployment ceiling" do
    issued_at = ~U[2026-07-13 01:00:00.000000Z]

    assert {:error, :invalid_launch_envelope_expiry} =
             issued_at
             |> DateTime.add(601, :second)
             |> context_attrs()
             |> Context.new(issued_at: issued_at)
  end

  test "locked grant and scope metadata must match the authenticated context" do
    context = context!()
    grant = correlated_grant(context)

    assert Context.grant_matches?(context, grant)

    refute Context.grant_matches?(
             context,
             put_in(
               grant,
               ["target_snapshot", "awx_scope", "scm_revision"],
               String.duplicate("e", 40)
             )
           )

    refute Context.grant_matches?(
             context,
             put_in(
               grant,
               ["target_snapshot", "response", "manifest_sha256"],
               String.duplicate("f", 64)
             )
           )

    refute Context.grant_matches?(
             context,
             put_in(grant, ["target_snapshot", "awx_scope", "callback_credential_type_id"], 92)
           )

    refute Context.grant_matches?(context, Map.put(grant, "dispatch_agent_id", "agent-other"))

    refute Context.grant_matches?(
             context,
             Map.put(grant, "dispatch_partition_id", "tonka01")
           )
  end

  defp context! do
    issued_at = ~U[2026-07-13 01:00:00.000000Z]

    issued_at
    |> DateTime.add(300, :second)
    |> context_attrs()
    |> Context.new(issued_at: issued_at)
    |> then(fn {:ok, context} -> context end)
  end

  defp context_attrs(expires_at) do
    %{
      tenant_id: "tenant-a",
      command_id: "01980a6d-4a62-7b3f-a249-5f825874ca41",
      child_execution_id: "01980a6d-4a62-7b3f-a249-5f825874ca42",
      callback_grant_id: "01980a6d-4a62-7b3f-a249-5f825874ca43",
      controller_id: "01980a6d-4a62-7b3f-a249-5f825874ca44",
      inventory_id: 17,
      job_template_id: 23,
      dispatch_agent_id: "agent-farm01",
      dispatch_partition_id: "farm01",
      callback_allowed_origin: "https://demo.example.com",
      manifest_sha256: String.duplicate("a", 64),
      scm_revision: String.duplicate("b", 40),
      content_sha256: String.duplicate("c", 64),
      callback_phase: "stage",
      callback_operation: "enroll",
      callback_state: "present",
      callback_credential_type_id: 91,
      callback_credential_organization_id: 2,
      callback_credential_injector_sha256: String.duplicate("d", 64),
      expires_at: expires_at
    }
  end

  defp tampered_values(context) do
    [
      tenant_id: "tenant-b",
      command_id: Ecto.UUID.generate(),
      child_execution_id: Ecto.UUID.generate(),
      callback_grant_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      inventory_id: context.inventory_id + 1,
      job_template_id: context.job_template_id + 1,
      dispatch_agent_id: "agent-tonka01",
      dispatch_partition_id: "tonka01",
      callback_url: String.replace(context.callback_url, "demo", "other"),
      callback_allowed_origin: "https://other.example.com",
      manifest_sha256: String.duplicate("e", 64),
      scm_revision: String.duplicate("f", 40),
      content_sha256: String.duplicate("0", 64),
      callback_phase: "verify",
      callback_operation: "overlap",
      callback_state: "absent",
      callback_credential_type_id: context.callback_credential_type_id + 1,
      callback_credential_organization_id: context.callback_credential_organization_id + 1,
      callback_credential_injector_sha256: String.duplicate("1", 64),
      expires_at: DateTime.add(context.expires_at, -1, :second)
    ]
  end

  defp correlated_grant(context) do
    scope = %{
      "controller_id" => context.controller_id,
      "inventory_id" => context.inventory_id,
      "job_template_id" => context.job_template_id,
      "scm_revision" => context.scm_revision,
      "content_sha256" => context.content_sha256,
      "callback_credential_type_id" => context.callback_credential_type_id,
      "callback_credential_organization_id" => context.callback_credential_organization_id,
      "callback_credential_injector_digest" => context.callback_credential_injector_sha256
    }

    response = %{
      "manifest_sha256" => context.manifest_sha256,
      "phase" => context.callback_phase,
      "operation" => context.callback_operation,
      "state" => context.callback_state
    }

    %{
      "id" => context.callback_grant_id,
      "tenant_id" => context.tenant_id,
      "execution_id" => context.child_execution_id,
      "controller_id" => context.controller_id,
      "inventory_id" => context.inventory_id,
      "job_template_id" => context.job_template_id,
      "dispatch_agent_id" => context.dispatch_agent_id,
      "dispatch_partition_id" => context.dispatch_partition_id,
      "expires_at" => context.expires_at,
      "action" => "remote_access.ssh_ca.bundle.read",
      "scm_revision" => context.scm_revision,
      "content_sha256" => context.content_sha256,
      "manifest_sha256" => context.manifest_sha256,
      "callback_phase" => context.callback_phase,
      "remote_access_operation" => context.callback_operation,
      "desired_state" => context.callback_state,
      "target_snapshot" => %{"awx_scope" => scope, "response" => response}
    }
  end
end

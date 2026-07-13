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
      expires_at: DateTime.add(context.expires_at, -1, :second)
    ]
  end
end

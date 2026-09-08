defmodule ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot

  @evidence_id "018f3f56-1111-7222-8333-123456789a01"
  @command_id "018f3f56-1111-7222-8333-123456789a02"
  @controller_id "018f3f56-1111-7222-8333-123456789a03"
  @binding_id "018f3f56-1111-7222-8333-123456789a04"
  @approval_id "018f3f56-1111-7222-8333-123456789a05"
  @now ~U[2026-07-14 23:20:00.000000Z]

  test "canonicalizes the compact secret-free live-preflight attestation" do
    assert {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(attestation())
    assert attrs.preflight_evidence_id == @evidence_id
    assert attrs.immutable_launch_snapshot["schema"] == AwxLaunchPreflightAttestation.schema()
    assert attrs.immutable_launch_snapshot_digest =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(attrs) =~ "Bearer "
    refute inspect(attrs) =~ "password"
  end

  test "requires an exact canonical attestation shape and a future expiry" do
    assert {:error, :awx_preflight_attestation_fields_invalid} =
             attestation()
             |> Map.put(:unreviewed, true)
             |> AwxLaunchPreflightAttestation.normalize()

    assert {:error, :awx_preflight_attestation_keys_invalid} =
             attestation()
             |> Map.put("schema", AwxLaunchPreflightAttestation.schema())
             |> AwxLaunchPreflightAttestation.normalize()

    assert {:error, :awx_preflight_digest_invalid} =
             attestation()
             |> Map.put(:command_result_digest, "not-a-digest")
             |> AwxLaunchPreflightAttestation.normalize()

    assert {:error, :awx_preflight_expiry_invalid} =
             attestation()
             |> Map.put(:expires_at, @now)
             |> AwxLaunchPreflightAttestation.normalize()
  end

  test "compares DateTime values before storing canonical ISO UTC strings" do
    assert {:ok, snapshot} = AwxLaunchPreflightAttestation.normalize(attestation())

    assert snapshot["verified_at"] == DateTime.to_iso8601(@now)
    assert snapshot["expires_at"] == DateTime.to_iso8601(DateTime.add(@now, 60, :second))
  end

  test "binds both persisted copies to evidence, controller, and the selected edge tuple" do
    controller = controller()
    {:ok, security_snapshot} = ControllerSecuritySnapshot.capture(controller)
    {:ok, security_digest} = ControllerSecuritySnapshot.digest(security_snapshot)

    attestation = attestation(%{controller_security_snapshot_digest: security_digest})
    {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(attestation)
    evidence = evidence(attestation)

    operation = Map.merge(%{id: "operation-1"}, attrs)
    execution = Map.merge(%{id: "execution-1"}, attrs)

    assert {:ok, snapshot} =
             AwxLaunchPreflightAttestation.verify_persisted(
               operation,
               execution,
               controller,
               @now,
               evidence_reader: fn @evidence_id -> {:ok, evidence} end
             )

    assert snapshot["evidence_id"] == @evidence_id

    assert :ok =
             AwxLaunchPreflightAttestation.verify_dispatch_principal(
               snapshot,
               "edge-agent-1",
               "farm01"
             )

    assert {:error, :awx_preflight_partition_drift} =
             AwxLaunchPreflightAttestation.verify_dispatch_principal(
               snapshot,
               "edge-agent-1",
               "tonka01"
             )

    assert {:error, :awx_preflight_evidence_mismatch} =
             AwxLaunchPreflightAttestation.verify_persisted(
               operation,
               Map.put(execution, :preflight_evidence_id, @command_id),
               controller,
               @now,
               evidence_reader: fn @evidence_id -> {:ok, evidence} end
             )
  end

  test "expired attestations remain verifiable only for cleanup" do
    controller = controller()
    {:ok, security_snapshot} = ControllerSecuritySnapshot.capture(controller)
    {:ok, security_digest} = ControllerSecuritySnapshot.digest(security_snapshot)

    expired =
      attestation(%{
        controller_security_snapshot_digest: security_digest,
        verified_at: DateTime.add(@now, -120, :second),
        expires_at: DateTime.add(@now, -1, :second)
      })

    {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(expired)
    evidence = evidence(expired)
    operation = Map.merge(%{id: "operation-1"}, attrs)
    execution = Map.merge(%{id: "execution-1"}, attrs)
    reader = fn @evidence_id -> {:ok, evidence} end

    assert {:error, :awx_preflight_evidence_expired} =
             AwxLaunchPreflightAttestation.verify_persisted(
               operation,
               execution,
               controller,
               @now,
               evidence_reader: reader
             )

    assert {:ok, snapshot} =
             AwxLaunchPreflightAttestation.verify_persisted_for_cleanup(
               operation,
               execution,
               controller,
               @now,
               evidence_reader: reader
             )

    assert :ok =
             AwxLaunchPreflightAttestation.verify_dispatch_principal(
               snapshot,
               "edge-agent-1",
               "farm01"
             )

    assert {:error, :awx_preflight_evidence_mismatch} =
             AwxLaunchPreflightAttestation.verify_persisted_for_cleanup(
               operation,
               Map.put(execution, :preflight_evidence_id, @command_id),
               controller,
               @now,
               evidence_reader: reader
             )

    assert {:error, :awx_preflight_controller_drift} =
             AwxLaunchPreflightAttestation.verify_persisted_for_cleanup(
               operation,
               execution,
               Map.put(controller, :base_url, "https://other-awx.example.test:8443"),
               @now,
               evidence_reader: reader
             )
  end

  test "rejects a binding revision or approval that no longer matches the attestation" do
    assert :ok = AwxLaunchPreflightAttestation.verify_binding(attestation(), reviewed_binding())

    assert {:error, :awx_preflight_binding_drift} =
             AwxLaunchPreflightAttestation.verify_binding(
               attestation(),
               reviewed_binding(%{binding_version: 99})
             )

    assert {:error, :awx_preflight_approval_drift} =
             AwxLaunchPreflightAttestation.verify_binding(
               attestation(),
               reviewed_binding(%{approval_id: @command_id})
             )
  end

  defp attestation(overrides \\ %{}) do
    Map.merge(
      %{
        schema: AwxLaunchPreflightAttestation.schema(),
        evidence_id: @evidence_id,
        command_id: @command_id,
        controller_id: @controller_id,
        dispatch_agent_id: "edge-agent-1",
        dispatch_partition_id: "farm01",
        binding_id: @binding_id,
        binding_version: 3,
        approval_id: @approval_id,
        reviewed_launch_snapshot_digest: String.duplicate("a", 64),
        preflight_request_digest: String.duplicate("b", 64),
        target_snapshot_digest: String.duplicate("c", 64),
        controller_security_snapshot_digest: String.duplicate("d", 64),
        live_launch_snapshot_digest: String.duplicate("e", 64),
        command_result_digest: String.duplicate("f", 64),
        verified_at: @now,
        expires_at: DateTime.add(@now, 60, :second)
      },
      overrides
    )
  end

  defp evidence(attestation) do
    %{
      id: attestation.evidence_id,
      command_id: attestation.command_id,
      controller_id: attestation.controller_id,
      dispatch_agent_id: attestation.dispatch_agent_id,
      dispatch_partition_id: attestation.dispatch_partition_id,
      binding_id: attestation.binding_id,
      binding_version: attestation.binding_version,
      approval_id: attestation.approval_id,
      reviewed_launch_snapshot_digest: attestation.reviewed_launch_snapshot_digest,
      preflight_request_digest: attestation.preflight_request_digest,
      target_snapshot_digest: attestation.target_snapshot_digest,
      controller_security_snapshot_digest: attestation.controller_security_snapshot_digest,
      live_launch_snapshot_digest: attestation.live_launch_snapshot_digest,
      command_result_digest: attestation.command_result_digest,
      verified_at: attestation.verified_at,
      expires_at: attestation.expires_at
    }
  end

  defp reviewed_binding(overrides \\ %{}) do
    Map.merge(
      %{
        id: @binding_id,
        controller_id: @controller_id,
        binding_version: 3,
        approval_id: @approval_id,
        approval_state: :approved,
        current: true,
        reviewed_launch_snapshot_digest: String.duplicate("a", 64)
      },
      overrides
    )
  end

  defp controller do
    %{
      id: @controller_id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:443",
      agent_id: "edge-agent-1",
      enabled: true,
      sync_credential_secret_id: "018f3f56-1111-7222-8333-123456789a06",
      execution_credential_secret_id: "018f3f56-1111-7222-8333-123456789a07",
      callback_credential_secret_id: nil,
      metadata: %{}
    }
  end
end

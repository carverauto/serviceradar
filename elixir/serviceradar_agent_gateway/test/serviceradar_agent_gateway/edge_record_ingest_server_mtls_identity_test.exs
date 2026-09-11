defmodule ServiceRadarAgentGateway.EdgeRecordIngestServerMtlsIdentityTest do
  @moduledoc """
  The mismatched-identity mTLS control fixture required by
  `openspec/changes/unify-sweep-results-proto/tasks.md` task 0.12, acceptance
  group A (see also `data/usp01-0.12-audit/report.md` dispatch item 4a).

  Every other `EdgeRecordIngestServer` test overrides
  `:edge_record_ingest_identity_resolver` with a hand-written stub that returns
  a canned identity map -- none of them exercise the real mTLS trust gate:
  `ServiceRadarAgentGateway.ComponentIdentityResolver.resolve_from_cert/1`
  decoding an actual X.509 certificate, or
  `ServiceRadarAgentGateway.AgentCertificateRevocation`, the production
  revocation registry that gate consults. This file drives both for real.

  ## What "differs only in the authenticated principal" means here

  Task 0.12 asks for a control fixture that differs from the accepted one
  ONLY in the authenticated principal. Two real certificates issued from the
  same trusted test CA, both correctly typed `:agent`, satisfy that: the
  wire bytes (the `lane_open` and `delivery_frame` messages) are byte-for-byte
  identical in both cases, and both certificates are otherwise well-formed and
  CA-trusted -- so the TLS handshake itself, and the type check in
  `EdgeRecordIngestServer.require_agent_identity!/1`, would both accept
  either one. The ONLY thing that distinguishes the control is that its
  specific principal has been revoked in
  `ServiceRadarAgentGateway.AgentCertificateRevocation` -- the real trust
  registry `ComponentIdentityResolver.resolve_from_cert/1` consults on every
  resolution. That is a genuine identity-mismatch outcome (`:unauthenticated`,
  distinct from the `:permission_denied` a wrong component TYPE produces),
  not a proxy for one, and it is asserted before any frame reaches the
  publisher.

  Full grant/contract-bound principal-to-spool authorization (task 3.2) is
  separate, unimplemented, out-of-scope work; this fixture proves what the
  CURRENTLY WIRED trust gate does, not what a future one will.
  """

  use ExUnit.Case, async: false

  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.EdgeRecordIngestServer
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordCapabilityStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordPublisherStub

  @spool_id :binary.copy(<<0xAB>>, 16)
  @session_nonce :binary.copy(<<0xCD>>, 8)
  @network_scope_id :binary.copy(<<0x40>>, 16)

  setup do
    CertificateTestHelpers.ensure_revocation_store!()
    AgentCertificateRevocation.clear()

    previous = %{
      publisher: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_publisher),
      capability: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_capability),
      supervisor: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_task_supervisor)
    }

    _supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

    Application.put_env(:serviceradar_agent_gateway, :edge_record_ingest_publisher, EdgeRecordPublisherStub)
    Application.put_env(:serviceradar_agent_gateway, :edge_record_ingest_capability, EdgeRecordCapabilityStub)

    Application.put_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_task_supervisor,
      __MODULE__.TaskSupervisor
    )

    # Deliberately do NOT override :edge_record_ingest_identity_resolver -- the
    # point of this fixture is to exercise the real default,
    # ComponentIdentityResolver, not a stub.

    parent_dir = CertificateTestHelpers.unique_tmp_dir!("edge-record-mtls-identity-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

    {:ok, accepted_bundle} =
      CertIssuer.issue_agent_bundle(
        "agent-accepted",
        "default",
        :agent,
        ca_cert_file: ca_cert,
        ca_key_file: ca_key,
        temp_parent_dir: parent_dir,
        audit_writer: nil
      )

    {:ok, control_bundle} =
      CertIssuer.issue_agent_bundle(
        "agent-control",
        "default",
        :agent,
        ca_cert_file: ca_cert,
        ca_key_file: ca_key,
        temp_parent_dir: parent_dir,
        audit_writer: nil
      )

    control_cert_der = CertificateTestHelpers.certificate_der!(control_bundle.certificate_pem)
    {:ok, control_identity} = ServiceRadarAgentGateway.ComponentIdentityResolver.resolve_from_cert(control_cert_der)

    on_exit(fn ->
      restore_env(:edge_record_ingest_publisher, previous.publisher)
      restore_env(:edge_record_ingest_capability, previous.capability)
      restore_env(:edge_record_ingest_task_supervisor, previous.supervisor)
    end)

    %{
      accepted_cert_der: CertificateTestHelpers.certificate_der!(accepted_bundle.certificate_pem),
      control_cert_der: control_cert_der,
      control_component_id: control_identity.component_id
    }
  end

  test "accepts a lane_open and publishes over a real, CA-trusted, non-revoked agent certificate", %{
    accepted_cert_der: cert_der
  } do
    record = record()
    frame = frame(1, record)

    messages = [client({:lane_open, lane_open()}), client({:delivery_frame, frame})]

    assert :ok = EdgeRecordIngestServer.stream(messages, stream(cert_der))

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    assert_received {:edge_record_published, publication}
    assert publication.slot.authenticated_agent_id == "agent-accepted"
    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  test "refuses the byte-identical fixture over a real cert whose principal is revoked, before any publish", %{
    control_cert_der: cert_der,
    control_component_id: component_id
  } do
    assert :ok =
             AgentCertificateRevocation.revoke_component_id(component_id,
               reason: "identity-mismatch control fixture"
             )

    # Byte-for-byte the same lane_open + delivery_frame the accepted fixture sends.
    record = record()
    frame = frame(1, record)
    messages = [client({:lane_open, lane_open()}), client({:delivery_frame, frame})]

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream(messages, stream(cert_der))
      end

    assert error.status == GRPC.Status.unauthenticated()

    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, _}
  end

  defp lane_open do
    %EdgeRecordLaneOpen{
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      spool_id: @spool_id,
      sequence_base: 1,
      first_unresolved_sequence: 1,
      session_nonce: @session_nonce,
      requested_byte_credits: 1024,
      requested_frame_credits: 4
    }
  end

  defp record do
    %EdgeRecordV1{
      network_scope_id: @network_scope_id,
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
    }
  end

  defp frame(sequence, record) do
    bytes = EdgeRecordV1.encode(record)

    %EdgeDeliveryFrameV1{
      spool_id: @spool_id,
      sequence: sequence,
      record_sha256: :crypto.hash(:sha256, bytes),
      record_bytes: bytes
    }
  end

  defp client(payload), do: %EdgeRecordClientMessage{payload: payload}

  defp stream(cert_der), do: %{adapter: __MODULE__.RealCertAdapterStub, payload: cert_der, test_pid: self()}

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defmodule RealCertAdapterStub do
    @moduledoc false

    # Echoes back the real, caller-supplied certificate DER instead of a
    # canned dummy value -- this is what makes the fixture exercise the real
    # ComponentIdentityResolver instead of stubbing around it.
    def get_cert(cert_der) when is_binary(cert_der), do: cert_der
  end
end

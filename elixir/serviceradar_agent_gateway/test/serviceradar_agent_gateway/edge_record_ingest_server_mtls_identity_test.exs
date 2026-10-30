defmodule ServiceRadarAgentGateway.EdgeRecordIngestServerMtlsIdentityTest do
  @moduledoc """
  The mismatched-identity mTLS control fixture required by
  `openspec/changes/unify-sweep-results-proto/tasks.md` task 0.12, acceptance
  group A (see also `data/usp01-0.12-audit/report.md` dispatch item 4a), plus
  the certificate-subject identity cases of task 3.2.

  Every other `EdgeRecordIngestServer` test overrides
  `:edge_record_ingest_identity_resolver` with a hand-written stub that returns
  a canned identity map -- none of them exercise the real mTLS trust gate:
  `ServiceRadarAgentGateway.ComponentIdentityResolver.resolve_edge_identity/3`
  decoding an actual X.509 certificate, validating it against the deployment
  CA, or `ServiceRadarAgentGateway.AgentCertificateRevocation`, the production
  revocation registry that gate consults. This file drives all of them for
  real, and authorizes every frame against a real signed production grant.

  ## What "differs only in the authenticated principal" means here

  Task 0.12 asks for a control fixture that differs from the accepted one
  ONLY in the authenticated principal. Two real certificates issued from the
  same trusted test CA, both correctly typed `:agent`, satisfy that: the
  wire bytes (the `lane_open` and `delivery_frame` messages) are byte-for-byte
  identical in both cases, and both certificates are otherwise well-formed and
  CA-trusted -- so the TLS handshake itself, and the role check, would both
  accept either one. The ONLY thing that distinguishes the control is that its
  specific principal has been revoked in
  `ServiceRadarAgentGateway.AgentCertificateRevocation`. That is a genuine
  identity-mismatch outcome (`:unauthenticated`, distinct from the
  `:permission_denied` a wrong component ROLE produces), and it is asserted
  before any frame reaches the publisher.
  """

  use ExUnit.Case, async: false

  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.EdgeRecordIngestServer
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.TestSupport.EdgeContractRegistryStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordCapabilityStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory, as: Factory
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordPublisherStub

  @spool_id :binary.copy(<<0xAB>>, 16)
  @session_nonce :binary.copy(<<0xCD>>, 8)

  setup do
    CertificateTestHelpers.ensure_revocation_store!()
    AgentCertificateRevocation.clear()

    previous = %{
      pipelines: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_pipelines),
      capability: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_capability),
      supervisor: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_task_supervisor),
      registry: Application.get_env(:serviceradar_agent_gateway, :edge_record_contract_registry_impl),
      ca_file: Application.get_env(:serviceradar_agent_gateway, :edge_deployment_ca_file)
    }

    Application.put_env(:serviceradar_agent_gateway, :edge_record_contract_registry_impl, EdgeContractRegistryStub)

    _supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

    EdgeRecordPublisherStub.start_pipeline!(EdgeRecordPublisherStub.publisher(self()))
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
    Application.put_env(:serviceradar_agent_gateway, :edge_deployment_ca_file, ca_cert)

    keys = Factory.keypair()
    scopes = [{"agent-accepted", [Factory.network_scope_id()]}]
    :ok = EdgeRecordTrust.install(Factory.trust_document(keys.public, scopes: scopes))

    issue = fn component_id, type ->
      {:ok, bundle} =
        CertIssuer.issue_agent_bundle(component_id, "default", type,
          ca_cert_file: ca_cert,
          ca_key_file: ca_key,
          temp_parent_dir: parent_dir,
          audit_writer: nil
        )

      CertificateTestHelpers.certificate_der!(bundle.certificate_pem)
    end

    on_exit(fn ->
      EdgeRecordTrust.clear()
      restore_env(:edge_record_ingest_pipelines, previous.pipelines)
      restore_env(:edge_record_ingest_capability, previous.capability)
      restore_env(:edge_record_ingest_task_supervisor, previous.supervisor)
      restore_env(:edge_record_contract_registry_impl, previous.registry)
      restore_env(:edge_deployment_ca_file, previous.ca_file)
    end)

    %{
      keys: keys,
      accepted_cert_der: issue.("agent-accepted", :agent),
      control_cert_der: issue.("agent-control", :agent),
      addon_cert_der: issue.("agent-accepted", :addon),
      cn_only_cert_der:
        CertificateTestHelpers.issue_cn_only_certificate!(
          ca_cert,
          ca_key,
          "agent-accepted.default.serviceradar",
          parent_dir
        )
    }
  end

  test "accepts a lane_open and publishes over a real, CA-trusted, non-revoked agent certificate", ctx do
    messages = messages(ctx)

    assert :ok = EdgeRecordIngestServer.stream(messages, stream(ctx.accepted_cert_der))

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    assert_receive {:edge_record_published, publication}
    assert publication.slot.authenticated_agent_id == "agent-accepted"
    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  test "accepts the same fixture over a deployment-CA certificate that carries no SPIFFE id", ctx do
    assert :ok = EdgeRecordIngestServer.stream(messages(ctx), stream(ctx.cn_only_cert_der))

    assert_receive {:edge_record_published, publication}
    assert publication.slot.authenticated_agent_id == "agent-accepted"
  end

  test "refuses the byte-identical fixture over a real cert whose principal is revoked, before any publish", ctx do
    assert :ok =
             AgentCertificateRevocation.revoke_component_id("agent-control",
               reason: "identity-mismatch control fixture"
             )

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream(messages(ctx), stream(ctx.control_cert_der))
      end

    assert error.status == GRPC.Status.unauthenticated()

    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, _}
  end

  test "refuses the byte-identical fixture over a real cert whose SPIFFE role is not agent, before any publish", ctx do
    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream(messages(ctx), stream(ctx.addon_cert_der))
      end

    assert error.status == GRPC.Status.permission_denied()

    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, _}
  end

  test "permanently rejects a frame whose signed grant names another principal than the certificate", ctx do
    record = Factory.record(ctx.keys.private, principal: "agent-control")
    messages = [client({:lane_open, lane_open()}), client({:delivery_frame, Factory.frame(record)})]

    assert :ok = EdgeRecordIngestServer.stream(messages, stream(ctx.accepted_cert_der))

    refute_received {:edge_record_published, _}

    assert_receive {:edge_record_stream_reply,
                    %EdgeRecordServerMessage{
                      payload: {:ack, %{dispositions: [%{kind: :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT}]}}
                    }}
  end

  # The same lane_open + delivery_frame shape for every certificate in this file: a grant for
  # "agent-accepted", so only the presented certificate differs between tests.
  defp messages(ctx) do
    record = Factory.record(ctx.keys.private, principal: "agent-accepted")
    [client({:lane_open, lane_open()}), client({:delivery_frame, Factory.frame(record)})]
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

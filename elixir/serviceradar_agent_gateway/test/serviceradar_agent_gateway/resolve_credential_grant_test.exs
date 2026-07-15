defmodule ServiceRadarAgentGateway.ResolveCredentialGrantTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer

  defmodule PeerCertAdapter do
    @moduledoc false

    def get_cert({:cert, cert_der}), do: cert_der
    def get_cert(:no_cert), do: :undefined
  end

  setup do
    CertificateTestHelpers.ensure_revocation_store!()
    AgentCertificateRevocation.clear()

    parent_dir = CertificateTestHelpers.unique_tmp_dir!("resolve-credential-grant-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

    %{parent_dir: parent_dir, ca_cert: ca_cert, ca_key: ca_key}
  end

  test "rejects missing agent id before certificate or core lookup" do
    request = credential_request(agent_id: "")

    assert_raise GRPC.RPCError, ~r/agent_id is required/, fn ->
      AgentGatewayServer.resolve_credential_grant(request, no_cert_stream())
    end
  end

  test "rejects missing mtls certificate" do
    request = credential_request(agent_id: "agent-1")

    assert_raise GRPC.RPCError, ~r/invalid client certificate/, fn ->
      AgentGatewayServer.resolve_credential_grant(request, no_cert_stream())
    end
  end

  test "rejects mtls identity mismatch before core lookup", context do
    request = credential_request(agent_id: "agent-1")
    stream = cert_stream(issue_cert_der!("agent-2", context))

    assert_raise GRPC.RPCError, ~r/component_id mismatch/, fn ->
      AgentGatewayServer.resolve_credential_grant(request, stream)
    end
  end

  test "denies resolution when no core node is available", context do
    request = credential_request(agent_id: "agent-1")
    stream = cert_stream(issue_cert_der!("agent-1", context))

    assert %Monitoring.CredentialBrokerResolveResponse{} =
             response =
             AgentGatewayServer.resolve_credential_grant(request, stream)

    refute response.success
    assert response.message == "credential grant resolution denied"
  end

  test "launch envelope rejects mtls identity mismatch before core lookup", context do
    request = launch_envelope_request(agent_id: "agent-1")
    stream = cert_stream(issue_cert_der!("agent-2", context))

    assert_raise GRPC.RPCError, ~r/component_id mismatch/, fn ->
      AgentGatewayServer.resolve_automation_launch_envelope(request, stream)
    end
  end

  test "launch envelope denial is sanitized when no core node is available", context do
    request = launch_envelope_request(agent_id: "agent-1")
    stream = cert_stream(issue_cert_der!("agent-1", context))

    assert %Monitoring.AutomationLaunchEnvelopeResolveResponse{} =
             response =
             AgentGatewayServer.resolve_automation_launch_envelope(request, stream)

    refute response.success
    assert response.bearer == <<>>
    assert response.idempotency_key == <<>>
    assert response.callback_grant_id == ""
    assert response.message == "automation launch envelope resolution denied"
  end

  test "launch envelope response keeps bearer bytes out of the denial contract" do
    expires_at = ~U[2026-07-13 02:05:00.000000Z]

    assert %Monitoring.AutomationLaunchEnvelopeResolveResponse{} =
             response =
             AgentGatewayServer.automation_launch_envelope_response(
               {:ok,
                {:ok,
                 %{
                   bearer: <<1, 2, 3>>,
                   idempotency_key: <<4, 5, 6>>,
                   callback_grant_id: "01980a6d-4a62-7b3f-a249-5f825874ca53",
                   callback_url: "https://demo.example.com/callback",
                   callback_allowed_origin: "https://demo.example.com",
                   manifest_sha256: String.duplicate("a", 64),
                   scm_revision: String.duplicate("b", 40),
                   content_sha256: String.duplicate("c", 64),
                   callback_phase: "stage",
                   callback_operation: "enroll",
                   callback_state: "present",
                   controller_id: "01980a6d-4a62-7b3f-a249-5f825874ca44",
                   inventory_id: 17,
                   job_template_id: 23,
                   callback_credential_type_id: 91,
                   callback_credential_organization_id: 2,
                   callback_credential_injector_sha256: String.duplicate("d", 64),
                   dispatch_agent_id: "agent-1",
                   child_execution_id: "01980a6d-4a62-7b3f-a249-5f825874ca42",
                   command_id: "01980a6d-4a62-7b3f-a249-5f825874ca41",
                   expires_at: expires_at
                 }}},
               "agent-1",
               "01980a6d-4a62-7b3f-a249-5f825874ca41"
             )

    assert response.success
    assert response.bearer == <<1, 2, 3>>
    assert response.idempotency_key == <<4, 5, 6>>
    assert response.callback_url == "https://demo.example.com/callback"
    assert response.callback_allowed_origin == "https://demo.example.com"
    assert response.manifest_sha256 == String.duplicate("a", 64)
    assert response.callback_credential_type_id == 91
    assert response.callback_credential_organization_id == 2
    assert response.callback_credential_injector_sha256 == String.duplicate("d", 64)
    assert response.dispatch_agent_id == "agent-1"
    assert response.command_id == "01980a6d-4a62-7b3f-a249-5f825874ca41"
    assert response.expires_at_unix == DateTime.to_unix(expires_at)
  end

  defp credential_request(overrides) do
    attrs =
      Keyword.merge(
        [
          agent_id: "agent-1",
          grant_id: "grant-1",
          credential_secret_ref: "credentialref:network-credential-secret:secret-1",
          consumer_kind: "plugin",
          consumer_id: "plugin-1",
          purpose: "plugin.http",
          resolution_location: "agent"
        ],
        overrides
      )

    struct!(Monitoring.CredentialBrokerResolveRequest, attrs)
  end

  defp launch_envelope_request(overrides) do
    attrs =
      Keyword.merge(
        [
          agent_id: "agent-1",
          envelope_ref: "srle1_" <> Base.url_encode64(:binary.copy(<<7>>, 32), padding: false),
          command_id: "01980a6d-4a62-7b3f-a249-5f825874ca41"
        ],
        overrides
      )

    struct!(Monitoring.AutomationLaunchEnvelopeResolveRequest, attrs)
  end

  defp cert_stream(cert_der) do
    %GRPC.Server.Stream{adapter: PeerCertAdapter, payload: {:cert, cert_der}}
  end

  defp no_cert_stream do
    %GRPC.Server.Stream{adapter: PeerCertAdapter, payload: :no_cert}
  end

  defp issue_cert_der!(component_id, context) do
    {:ok, bundle} =
      CertIssuer.issue_agent_bundle(
        component_id,
        "default",
        :agent,
        ca_cert_file: context.ca_cert,
        ca_key_file: context.ca_key,
        temp_parent_dir: context.parent_dir,
        audit_writer: nil
      )

    CertificateTestHelpers.certificate_der!(bundle.certificate_pem)
  end
end

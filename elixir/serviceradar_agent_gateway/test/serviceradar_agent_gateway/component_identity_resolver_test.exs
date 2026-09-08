defmodule ServiceRadarAgentGateway.ComponentIdentityResolverTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.ComponentIdentityResolver

  setup do
    CertificateTestHelpers.ensure_revocation_store!()
    AgentCertificateRevocation.clear()

    parent_dir = CertificateTestHelpers.unique_tmp_dir!("component-identity-resolver-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

    {:ok, bundle} =
      CertIssuer.issue_agent_bundle(
        "agent-1",
        "default",
        :agent,
        ca_cert_file: ca_cert,
        ca_key_file: ca_key,
        temp_parent_dir: parent_dir,
        audit_writer: nil
      )

    %{cert_der: CertificateTestHelpers.certificate_der!(bundle.certificate_pem)}
  end

  test "resolves certificate identity with fingerprint and serial", %{cert_der: cert_der} do
    assert {:ok, identity} = ComponentIdentityResolver.resolve_from_cert(cert_der)
    assert identity.component_id == "agent-1"
    assert identity.partition_id == "default"
    assert identity.component_type == :agent
    assert byte_size(identity.certificate_fingerprint) == 64
    assert is_integer(identity.serial_number)
  end

  test "rejects revoked certificate component ids", %{cert_der: cert_der} do
    assert {:ok, identity} = ComponentIdentityResolver.resolve_from_cert(cert_der)
    assert :ok = AgentCertificateRevocation.revoke_component_id(identity.component_id, reason: "compromised")
    assert {:error, :revoked_certificate} = ComponentIdentityResolver.resolve_from_cert(cert_der)
  end

  test "rejects revoked certificate fingerprints", %{cert_der: cert_der} do
    assert {:ok, identity} = ComponentIdentityResolver.resolve_from_cert(cert_der)

    assert :ok =
             AgentCertificateRevocation.revoke_fingerprint(
               identity.certificate_fingerprint,
               reason: "lost device"
             )

    assert {:error, :revoked_certificate} = ComponentIdentityResolver.resolve_from_cert(cert_der)
  end
end

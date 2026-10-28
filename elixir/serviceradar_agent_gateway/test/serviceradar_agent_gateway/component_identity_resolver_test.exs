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
        temp_parent_dir: parent_dir
      )

    %{cert_der: CertificateTestHelpers.certificate_der!(bundle.certificate_pem)}
  end

  test "resolves certificate identity with fingerprint, serial, and validity timestamps", %{
    cert_der: cert_der
  } do
    assert {:ok, identity} = ComponentIdentityResolver.resolve_from_cert(cert_der)
    assert identity.component_id == "agent-1"
    assert identity.partition_id == "default"
    assert identity.component_type == :agent
    assert byte_size(identity.certificate_fingerprint) == 64
    assert identity.cert_fingerprint_sha256 == identity.certificate_fingerprint
    assert is_integer(identity.serial_number)
    assert Regex.match?(~r/\A[0-9a-f]+\z/, identity.cert_serial)
    assert %DateTime{} = identity.cert_not_before
    assert %DateTime{} = identity.cert_not_after
    assert identity.cert_expires_at == identity.cert_not_after
    assert DateTime.diff(identity.cert_not_after, identity.cert_not_before, :second) == 90 * 86_400
  end

  test "rejects expired and not-yet-valid certificates", %{cert_der: cert_der} do
    assert {:ok, identity} = ComponentIdentityResolver.resolve_from_cert(cert_der)

    expired_now = DateTime.shift(identity.cert_not_after, minute: 1)

    assert {:error, :certificate_expired} =
             ComponentIdentityResolver.resolve_from_cert(cert_der, now: expired_now)

    future_now = DateTime.shift(identity.cert_not_before, minute: -1)

    assert {:error, :certificate_not_yet_valid} =
             ComponentIdentityResolver.resolve_from_cert(cert_der, now: future_now)
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

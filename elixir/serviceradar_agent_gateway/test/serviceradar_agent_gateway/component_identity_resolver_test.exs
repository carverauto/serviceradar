defmodule ServiceRadarAgentGateway.ComponentIdentityResolverTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.ComponentIdentityResolver

  setup do
    ensure_revocation_store!()
    AgentCertificateRevocation.clear()

    parent_dir = unique_tmp_dir!("component-identity-resolver-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    generate_ca_bundle!(ca_cert, ca_key)

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

    %{cert_der: certificate_der!(bundle.certificate_pem)}
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

  defp ensure_revocation_store! do
    if Process.whereis(AgentCertificateRevocation) do
      :ok
    else
      start_supervised!(AgentCertificateRevocation)
    end
  end

  defp certificate_der!(certificate_pem) do
    certificate_pem
    |> :public_key.pem_decode()
    |> Enum.find_value(fn
      {:Certificate, der, :not_encrypted} -> der
      _ -> nil
    end) ||
      flunk("issued bundle did not include a certificate")
  end

  defp generate_ca_bundle!(ca_cert, ca_key) do
    args = [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-keyout",
      ca_key,
      "-out",
      ca_cert,
      "-sha256",
      "-days",
      "1",
      "-nodes",
      "-subj",
      "/CN=ServiceRadar Test Root"
    ]

    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("openssl test CA generation failed (#{status}): #{output}")
    end
  end

  defp unique_tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
      )

    File.mkdir_p!(dir)
    dir
  end
end

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

    %{
      cert_der: CertificateTestHelpers.certificate_der!(bundle.certificate_pem),
      ca_cert: ca_cert,
      ca_key: ca_key,
      parent_dir: parent_dir
    }
  end

  describe "resolve_edge_identity/3" do
    test "derives agent, partition and installation trust from the CA and CN alone, without SPIFFE", ctx do
      cert_der =
        CertificateTestHelpers.issue_cn_only_certificate!(
          ctx.ca_cert,
          ctx.ca_key,
          "agent-cn.site-a.serviceradar",
          ctx.parent_dir
        )

      assert {:ok, identity} =
               ComponentIdentityResolver.resolve_edge_identity(cert_der, :agent,
                 trust_anchors: anchors(ctx.ca_cert),
                 gateway_id: "gw-test"
               )

      assert identity.component_id == "agent-cn"
      assert identity.partition_id == "site-a"
      assert identity.component_type == :agent
      assert identity.gateway_id == "gw-test"
      assert identity.spiffe_id == nil
      assert identity.installation_trust_id == CertificateTestHelpers.spki_sha256!(ctx.ca_cert)
    end

    test "accepts a SPIFFE id that agrees with the certificate subject", %{cert_der: cert_der} = ctx do
      assert {:ok, identity} =
               ComponentIdentityResolver.resolve_edge_identity(cert_der, :agent, trust_anchors: anchors(ctx.ca_cert))

      assert identity.component_id == "agent-1"
      assert identity.spiffe_id == "spiffe://serviceradar.local/agent/default/agent-1"
    end

    test "refuses a certificate whose SPIFFE id names another role", ctx do
      {:ok, bundle} =
        CertIssuer.issue_agent_bundle("addon-1", "default", :addon,
          ca_cert_file: ctx.ca_cert,
          ca_key_file: ctx.ca_key,
          temp_parent_dir: ctx.parent_dir,
          audit_writer: nil
        )

      cert_der = CertificateTestHelpers.certificate_der!(bundle.certificate_pem)

      assert {:error, {:identity_conflict, :spiffe}} =
               ComponentIdentityResolver.resolve_edge_identity(cert_der, :agent, trust_anchors: anchors(ctx.ca_cert))
    end

    test "refuses a certificate issued by a CA outside this installation", ctx do
      other_dir = CertificateTestHelpers.unique_tmp_dir!("component-identity-resolver-other-ca")
      on_exit(fn -> File.rm_rf(other_dir) end)
      other_ca = Path.join(other_dir, "root.pem")
      other_key = Path.join(other_dir, "root-key.pem")
      CertificateTestHelpers.generate_ca_bundle!(other_ca, other_key)

      cert_der =
        CertificateTestHelpers.issue_cn_only_certificate!(
          other_ca,
          other_key,
          "agent-x.default.serviceradar",
          other_dir
        )

      assert {:error, :untrusted_installation} =
               ComponentIdentityResolver.resolve_edge_identity(cert_der, :agent, trust_anchors: anchors(ctx.ca_cert))
    end

    test "refuses a CN whose component id is not a valid principal", ctx do
      cert_der =
        CertificateTestHelpers.issue_cn_only_certificate!(
          ctx.ca_cert,
          ctx.ca_key,
          "agent@1.default.serviceradar",
          ctx.parent_dir
        )

      assert {:error, :invalid_principal} =
               ComponentIdentityResolver.resolve_edge_identity(cert_der, :agent, trust_anchors: anchors(ctx.ca_cert))
    end

    test "rejects a revoked principal", %{cert_der: cert_der} = ctx do
      assert :ok = AgentCertificateRevocation.revoke_component_id("agent-1", reason: "compromised")

      assert {:error, :revoked_certificate} =
               ComponentIdentityResolver.resolve_edge_identity(cert_der, :agent, trust_anchors: anchors(ctx.ca_cert))
    end

    test "fails closed when the deployment CA cannot be read", ctx do
      Application.put_env(
        :serviceradar_agent_gateway,
        :edge_deployment_ca_file,
        Path.join(ctx.parent_dir, "missing.pem")
      )

      on_exit(fn -> Application.delete_env(:serviceradar_agent_gateway, :edge_deployment_ca_file) end)

      assert {:error, :installation_trust_unavailable} =
               ComponentIdentityResolver.resolve_edge_identity(ctx.cert_der, :agent)
    end
  end

  defp anchors(ca_cert) do
    ca_cert |> File.read!() |> CertificateTestHelpers.certificate_der!() |> List.wrap()
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

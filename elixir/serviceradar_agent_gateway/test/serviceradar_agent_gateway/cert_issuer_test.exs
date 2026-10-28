defmodule ServiceRadarAgentGateway.CertIssuerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.ComponentIdentityResolver

  test "issues bundles using secure temp staging under the configured parent and cleans up" do
    parent_dir = unique_tmp_dir!("gateway-cert-issuer-test")

    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")

    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    assert {:ok, bundle} =
             CertIssuer.issue_agent_bundle(
               "agent-1",
               "default",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir
             )

    assert bundle.cn == "agent-1.default.serviceradar"
    assert bundle.validity_days == 90
    assert bundle.validity_days == CertIssuer.default_validity_days()
    assert String.length(bundle.certificate_fingerprint) == 64
    assert bundle.private_key_pem =~ "PRIVATE KEY"
    assert bundle.certificate_pem =~ "CERTIFICATE"

    [{:Certificate, cert_der, _}] = :public_key.pem_decode(bundle.certificate_pem)
    assert {:ok, identity} = ComponentIdentityResolver.resolve_from_cert(cert_der)
    assert DateTime.diff(identity.cert_not_after, identity.cert_not_before, :second) == 90 * 86_400

    leftover_dirs =
      parent_dir
      |> File.ls!()
      |> Enum.filter(fn name -> String.starts_with?(name, "serviceradar-cert-") end)

    assert leftover_dirs == []
  end

  test "issues a distinct add-on identity without changing agent certificate defaults" do
    parent_dir = unique_tmp_dir!("gateway-addon-cert-issuer-test")

    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")

    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    assert {:ok, bundle} =
             CertIssuer.issue_agent_bundle(
               "addon-assignment-1",
               "default",
               :addon,
               validity_days: 30,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir
             )

    assert bundle.cn == "addon-assignment-1.default.serviceradar"

    assert bundle.spiffe_id ==
             "spiffe://serviceradar.local/addon/default/addon-assignment-1"
  end

  describe "edge-site NATS leaf certificates" do
    setup do
      parent_dir = unique_tmp_dir!("gateway-nats-leaf-cert-test")
      on_exit(fn -> File.rm_rf(parent_dir) end)

      ca_cert = Path.join(parent_dir, "root.pem")
      ca_key = Path.join(parent_dir, "root-key.pem")
      assert :ok = generate_ca_bundle(ca_cert, ca_key)

      %{opts: [ca_cert_file: ca_cert, ca_key_file: ca_key, temp_parent_dir: parent_dir]}
    end

    test "leaf client certificates carry the partition role URI the hub maps", %{opts: opts} do
      assert {:ok, bundle} = CertIssuer.issue_agent_bundle("leaf-nyc", "acme", :nats_leaf, opts)

      sans = subject_alt_names(bundle.certificate_pem)
      assert {:uniformResourceIdentifier, ~c"spiffe://serviceradar.local/nats-leaf/acme"} in sans
      assert {:uniformResourceIdentifier, ~c"spiffe://serviceradar.local/nats_leaf/acme/leaf-nyc"} in sans
      assert CertIssuer.nats_leaf_role_uri("acme") == "spiffe://serviceradar.local/nats-leaf/acme"
    end

    test "agent certificates never carry the leaf role URI", %{opts: opts} do
      assert {:ok, bundle} = CertIssuer.issue_agent_bundle("agent-1", "acme", :agent, opts)

      refute {:uniformResourceIdentifier, ~c"spiffe://serviceradar.local/nats-leaf/acme"} in subject_alt_names(
               bundle.certificate_pem
             )
    end

    test "leaf server certificates name localhost and the configured local hosts", %{opts: opts} do
      assert {:ok, bundle} =
               CertIssuer.issue_agent_bundle(
                 "leaf-nyc-server",
                 "acme",
                 :nats_leaf_server,
                 Keyword.put(opts, :server_hosts, ["10.0.1.50", "nats.nyc.example.com"])
               )

      sans = subject_alt_names(bundle.certificate_pem)
      assert {:dNSName, ~c"localhost"} in sans
      assert {:dNSName, ~c"nats.nyc.example.com"} in sans
      assert {:iPAddress, <<127, 0, 0, 1>>} in sans
      assert {:iPAddress, <<10, 0, 1, 50>>} in sans
      refute {:uniformResourceIdentifier, ~c"spiffe://serviceradar.local/nats-leaf/acme"} in sans
    end

    test "rejects a server host that is neither an IP nor a DNS name", %{opts: opts} do
      assert {:error, :invalid_server_host} =
               CertIssuer.issue_agent_bundle(
                 "leaf-nyc-server",
                 "acme",
                 :nats_leaf_server,
                 Keyword.put(opts, :server_hosts, ["bad host\nDNS.9 = evil"])
               )
    end
  end

  test "rejects invalid and over-limit validity days before loading CA files" do
    assert {:error, :invalid_validity_days} =
             CertIssuer.issue_agent_bundle("agent-1", "default", :agent, validity_days: 0)

    assert {:error, {:invalid_certificate_validity_days, 1}} =
             CertIssuer.issue_agent_bundle("agent-1", "default", :agent, validity_days: 1)

    assert {:error, {:invalid_certificate_validity_days, 6}} =
             CertIssuer.issue_agent_bundle("agent-1", "default", :agent, validity_days: 6)

    assert {:error, :invalid_validity_days} =
             CertIssuer.issue_agent_bundle("agent-1", "default", :agent, validity_days: "30")

    assert {:error, :validity_days_exceeds_limit} =
             CertIssuer.issue_agent_bundle(
               "agent-1",
               "default",
               :agent,
               validity_days: CertIssuer.max_validity_days() + 1,
               allow_long_ttl?: true,
               long_ttl_approved_by: %{role: :admin}
             )
  end

  test "allows 1-day test certificate lifetime only when allow_short_test_lifetime is set" do
    parent_dir = unique_tmp_dir!("gateway-cert-issuer-short-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    assert {:ok, bundle} =
             CertIssuer.issue_agent_bundle(
               "agent-short-test",
               "default",
               :agent,
               validity_days: 1,
               allow_short_test_lifetime: true,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir
             )

    assert bundle.validity_days == 1
  end

  test "mints certificates with the deployment default lifetime without long-TTL approval" do
    previous = Application.fetch_env(:serviceradar_core, :agent_cert_validity_days)
    Application.put_env(:serviceradar_core, :agent_cert_validity_days, 180)

    parent_dir = unique_tmp_dir!("gateway-cert-issuer-deployment-default")

    on_exit(fn ->
      File.rm_rf(parent_dir)

      case previous do
        {:ok, days} -> Application.put_env(:serviceradar_core, :agent_cert_validity_days, days)
        :error -> Application.delete_env(:serviceradar_core, :agent_cert_validity_days)
      end
    end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    # web-ng sends the resolved default explicitly; gateway-internal callers omit it.
    for requested <- [[validity_days: 180], []] do
      assert {:ok, bundle} =
               CertIssuer.issue_agent_bundle(
                 "agent-deployment-default",
                 "default",
                 :agent,
                 requested ++
                   [ca_cert_file: ca_cert, ca_key_file: ca_key, temp_parent_dir: parent_dir, audit_writer: nil]
               )

      [{:Certificate, cert_der, _}] = :public_key.pem_decode(bundle.certificate_pem)
      assert {:ok, identity} = ComponentIdentityResolver.resolve_from_cert(cert_der)
      assert DateTime.diff(identity.cert_not_after, identity.cert_not_before, :second) == 180 * 86_400
    end
  end

  test "requires admin approval for certificate TTL above the default" do
    assert {:error, :long_ttl_approval_required} =
             CertIssuer.issue_agent_bundle(
               "agent-1",
               "default",
               :agent,
               validity_days: CertIssuer.default_validity_days() + 1
             )
  end

  test "rejects unsafe certificate identity tokens before loading CA files" do
    assert {:error, :invalid_component_id} =
             CertIssuer.issue_agent_bundle("agent.prod", "default", :agent)

    assert {:error, :invalid_component_id} =
             CertIssuer.issue_agent_bundle(" agent-1", "default", :agent)

    assert {:error, :invalid_partition_id} =
             CertIssuer.issue_agent_bundle("agent-1", "partition/prod", :agent)

    assert {:error, :invalid_partition_id} =
             CertIssuer.issue_agent_bundle("agent-1", "partition\nprod", :agent)
  end

  test "rejects component mismatch before loading CA files" do
    assert {:error, :component_not_authorized} =
             CertIssuer.issue_agent_bundle(
               "agent-b",
               "partition-a",
               :agent,
               authorized_component_id: "agent-a"
             )
  end

  test "rejects partition mismatch before loading CA files" do
    assert {:error, :partition_not_authorized} =
             CertIssuer.issue_agent_bundle(
               "agent-1",
               "partition-b",
               :agent,
               authorized_partition_id: "partition-a"
             )
  end

  test "allows explicit long TTL opt-in" do
    parent_dir = unique_tmp_dir!("gateway-cert-issuer-long-ttl-test")

    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")

    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    assert {:ok, bundle} =
             CertIssuer.issue_agent_bundle(
               "agent-1",
               "default",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               validity_days: 180,
               long_ttl_approved_by: %{id: "admin-1", role: :admin}
             )

    assert bundle.validity_days == 180
  end

  test "returns the issuance audit for the requesting node, without key or certificate material" do
    parent_dir = unique_tmp_dir!("gateway-cert-issuer-audit-test")

    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    actor = %{id: "operator-1", email: "operator@example.test"}

    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    assert {:ok, bundle} =
             CertIssuer.issue_agent_bundle(
               "agent-audit",
               "partition-a",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               authorized_partition_id: "partition-a",
               audit_actor: actor
             )

    event = Map.new(bundle.issuance_audit)

    assert event.action == :agent_certificate_issue
    assert event.resource_type == "agent_certificate"
    assert event.resource_id == "agent-audit"
    assert event.resource_name == "agent-audit.partition-a.serviceradar"
    assert event.actor == actor
    assert event.severity == :informational

    assert event.details == %{
             authorized_component_id: nil,
             authorized_partition_id: "partition-a",
             certificate_fingerprint: bundle.certificate_fingerprint,
             cn: "agent-audit.partition-a.serviceradar",
             component_id: "agent-audit",
             component_type: :agent,
             granted_partition_id: "partition-a",
             long_ttl_approved_by: nil,
             predecessor_certificate_fingerprint: nil,
             predecessor_certificate_revoked: false,
             predecessor_certificate_serial_number: nil,
             requested_partition_id: "partition-a",
             spiffe_id: "spiffe://serviceradar.local/agent/partition-a/agent-audit",
             validity_days: CertIssuer.default_validity_days()
           }

    refute Map.has_key?(event.details, :private_key_pem)
    refute Map.has_key?(event.details, :certificate_pem)
    refute Map.has_key?(event.details, :bundle_pem)
    refute inspect(event) =~ "PRIVATE KEY"
    refute inspect(event) =~ "CERTIFICATE-----"
  end

  test "revokes predecessor certificate fingerprint and serial after renewal succeeds" do
    ensure_revocation_store!()
    AgentCertificateRevocation.clear()

    parent_dir = unique_tmp_dir!("gateway-cert-issuer-renewal-test")

    on_exit(fn ->
      if Process.whereis(AgentCertificateRevocation), do: AgentCertificateRevocation.clear()
      File.rm_rf(parent_dir)
    end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")

    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    predecessor_fingerprint = String.duplicate("a", 64)
    predecessor_serial_number = 12_345

    assert {:ok, _bundle} =
             CertIssuer.issue_agent_bundle(
               "agent-renewal",
               "partition-a",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               predecessor_certificate_fingerprint: String.upcase(predecessor_fingerprint),
               predecessor_certificate_serial_number: predecessor_serial_number,
               predecessor_revocation_reason: "renewed by test"
             )

    assert AgentCertificateRevocation.revoked?(%{
             certificate_fingerprint: predecessor_fingerprint,
             serial_number: predecessor_serial_number
           })
  end

  test "issues renewed certificate from a verified ECDSA CSR and emits agent_certificate_renew audit" do
    parent_dir = unique_tmp_dir!("gateway-cert-issuer-csr-test")
    test_pid = self()

    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    csr_der =
      generate_csr_der!(
        ["req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "/dev/null"],
        "/CN=agent-1.default.serviceradar",
        "URI:spiffe://serviceradar.local/agent/default/agent-1,DNS:agent-1.default.serviceradar"
      )

    audit_writer = fn event ->
      send(test_pid, {:csr_renew_audit, event})
      :ok
    end

    assert {:ok, issued} =
             CertIssuer.issue_from_csr(
               csr_der,
               "agent-1",
               "default",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               audit_writer: audit_writer
             )

    assert issued.cn == "agent-1.default.serviceradar"
    assert issued.spiffe_id == "spiffe://serviceradar.local/agent/default/agent-1"
    assert byte_size(issued.certificate_fingerprint) == 64
    assert byte_size(issued.serial_number) > 0
    assert is_integer(issued.serial_number_int) and issued.serial_number_int > 0
    assert issued.not_after_unix > issued.not_before_unix

    sans = subject_alt_names(issued.certificate_pem)

    assert {:uniformResourceIdentifier, ~c"spiffe://serviceradar.local/agent/default/agent-1"} in sans
    assert {:dNSName, ~c"agent-1.default.serviceradar"} in sans

    assert_receive {:csr_renew_audit, event}
    assert event.action == :agent_certificate_renew
    assert event.resource_id == "agent-1"
  end

  test "rejects CSR with forged signature or weak key or mismatched CN/SAN" do
    parent_dir = unique_tmp_dir!("gateway-cert-issuer-csr-reject-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    valid_csr_der =
      generate_csr_der!(
        ["req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "/dev/null"],
        "/CN=agent-1.default.serviceradar",
        "URI:spiffe://serviceradar.local/agent/default/agent-1,DNS:agent-1.default.serviceradar"
      )

    {:CertificationRequest, info, sig_algo, sig} =
      :public_key.der_decode(:CertificationRequest, valid_csr_der)

    <<first, rest::binary>> = sig
    tampered_sig = <<Bitwise.bxor(first, 0xFF), rest::binary>>

    forged_csr_der =
      :public_key.der_encode(
        :CertificationRequest,
        {:CertificationRequest, info, sig_algo, tampered_sig}
      )

    assert {:error, :invalid_csr_signature} =
             CertIssuer.issue_from_csr(
               forged_csr_der,
               "agent-1",
               "default",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               audit_writer: nil
             )

    weak_csr_der =
      generate_csr_der!(
        ["req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:secp256k1", "-nodes", "-keyout", "/dev/null"],
        "/CN=agent-1.default.serviceradar",
        nil
      )

    assert {:error, :weak_public_key} =
             CertIssuer.issue_from_csr(
               weak_csr_der,
               "agent-1",
               "default",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               audit_writer: nil
             )

    mismatched_cn_csr =
      generate_csr_der!(
        ["req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "/dev/null"],
        "/CN=agent-2.default.serviceradar",
        nil
      )

    assert {:error, :csr_identity_mismatch} =
             CertIssuer.issue_from_csr(
               mismatched_cn_csr,
               "agent-1",
               "default",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               audit_writer: nil
             )

    mismatched_san_csr =
      generate_csr_der!(
        ["req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "/dev/null"],
        "/CN=agent-1.default.serviceradar",
        "URI:spiffe://serviceradar.local/agent/default/agent-2,DNS:agent-1.default.serviceradar"
      )

    assert {:error, :csr_identity_mismatch} =
             CertIssuer.issue_from_csr(
               mismatched_san_csr,
               "agent-1",
               "default",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               audit_writer: nil
             )
  end

  defp generate_csr_der!(base_args, subj, san) do
    args =
      base_args ++
        ["-subj", subj] ++
        if(is_binary(san), do: ["-addext", "subjectAltName=#{san}"], else: [])

    case System.cmd("openssl", args, stderr_to_stdout: false) do
      {pem, 0} ->
        [{:CertificationRequest, der, :not_encrypted}] = :public_key.pem_decode(pem)
        der

      {output, status} ->
        flunk("openssl CSR generation failed (#{status}): #{output}")
    end
  end

  defp subject_alt_names(cert_pem) do
    [{:Certificate, der, _}] = :public_key.pem_decode(cert_pem)
    cert = :public_key.pkix_decode_cert(der, :otp)
    {:OTPCertificate, tbs, _, _} = cert
    extensions = elem(tbs, 10)

    Enum.find_value(extensions, [], fn
      {:Extension, {2, 5, 29, 17}, _critical, sans} -> sans
      _ -> nil
    end)
  end

  defp generate_ca_bundle(ca_cert, ca_key) do
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

  defp ensure_revocation_store! do
    if Process.whereis(AgentCertificateRevocation) do
      :ok
    else
      start_supervised!(AgentCertificateRevocation)
    end
  end
end

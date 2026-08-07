defmodule ServiceRadarAgentGateway.CertIssuerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.CertIssuer

  @moduletag :requires_app

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
               temp_parent_dir: parent_dir,
               audit_writer: nil
             )

    assert bundle.cn == "agent-1.default.serviceradar"
    assert bundle.validity_days == CertIssuer.default_validity_days()
    assert String.length(bundle.certificate_fingerprint) == 64
    assert bundle.private_key_pem =~ "PRIVATE KEY"
    assert bundle.certificate_pem =~ "CERTIFICATE"

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
               temp_parent_dir: parent_dir,
               audit_writer: nil
             )

    assert bundle.cn == "addon-assignment-1.default.serviceradar"

    assert bundle.spiffe_id ==
             "spiffe://serviceradar.local/addon/default/addon-assignment-1"
  end

  test "rejects invalid and over-limit validity days before loading CA files" do
    assert {:error, :invalid_validity_days} =
             CertIssuer.issue_agent_bundle("agent-1", "default", :agent, validity_days: 0)

    assert {:error, :invalid_validity_days} =
             CertIssuer.issue_agent_bundle("agent-1", "default", :agent, validity_days: "30")

    assert {:error, :validity_days_exceeds_limit} =
             CertIssuer.issue_agent_bundle(
               "agent-1",
               "default",
               :agent,
               validity_days: CertIssuer.max_validity_days() + 1
             )
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
               validity_days: CertIssuer.max_validity_days() + 1,
               allow_long_ttl?: true,
               long_ttl_approved_by: %{id: "admin-1", role: :admin},
               audit_writer: nil
             )

    assert bundle.validity_days == CertIssuer.max_validity_days() + 1
  end

  test "emits certificate issuance audit without certificate or private key material" do
    parent_dir = unique_tmp_dir!("gateway-cert-issuer-audit-test")
    test_pid = self()

    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    actor = %{id: "operator-1", email: "operator@example.test"}

    assert :ok = generate_ca_bundle(ca_cert, ca_key)

    audit_writer = fn event ->
      send(test_pid, {:cert_issuance_audit, event})
      :ok
    end

    assert {:ok, bundle} =
             CertIssuer.issue_agent_bundle(
               "agent-audit",
               "partition-a",
               :agent,
               ca_cert_file: ca_cert,
               ca_key_file: ca_key,
               temp_parent_dir: parent_dir,
               authorized_partition_id: "partition-a",
               audit_actor: actor,
               audit_writer: audit_writer
             )

    assert_receive {:cert_issuance_audit, event}

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
      AgentCertificateRevocation.clear()
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
               predecessor_revocation_reason: "renewed by test",
               audit_writer: nil
             )

    assert AgentCertificateRevocation.revoked?(%{
             certificate_fingerprint: predecessor_fingerprint,
             serial_number: predecessor_serial_number
           })
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

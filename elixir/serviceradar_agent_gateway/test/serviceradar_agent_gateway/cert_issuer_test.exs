defmodule ServiceRadarAgentGateway.CertIssuerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.CertIssuer

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
    assert bundle.validity_days == 1
    assert String.length(bundle.certificate_fingerprint) == 64
    assert bundle.private_key_pem =~ "PRIVATE KEY"
    assert bundle.certificate_pem =~ "CERTIFICATE"

    leftover_dirs =
      parent_dir
      |> File.ls!()
      |> Enum.filter(fn name -> String.starts_with?(name, "serviceradar-cert-") end)

    assert leftover_dirs == []
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
             authorized_partition_id: "partition-a",
             certificate_fingerprint: bundle.certificate_fingerprint,
             cn: "agent-audit.partition-a.serviceradar",
             component_id: "agent-audit",
             component_type: :agent,
             granted_partition_id: "partition-a",
             requested_partition_id: "partition-a",
             spiffe_id: "spiffe://serviceradar.local/agent/partition-a/agent-audit",
             validity_days: 1
           }

    refute Map.has_key?(event.details, :private_key_pem)
    refute Map.has_key?(event.details, :certificate_pem)
    refute Map.has_key?(event.details, :bundle_pem)
    refute inspect(event) =~ "PRIVATE KEY"
    refute inspect(event) =~ "CERTIFICATE-----"
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
end

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
               temp_parent_dir: parent_dir
             )

    assert bundle.cn == "agent-1.default.serviceradar"
    assert bundle.private_key_pem =~ "PRIVATE KEY"
    assert bundle.certificate_pem =~ "CERTIFICATE"

    leftover_dirs =
      parent_dir
      |> File.ls!()
      |> Enum.filter(fn name -> String.starts_with?(name, "serviceradar-cert-") end)

    assert leftover_dirs == []
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

defmodule ServiceRadarAgentGateway.CertificateTestHelpers do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias ServiceRadarAgentGateway.AgentCertificateRevocation

  def ensure_revocation_store! do
    if Process.whereis(AgentCertificateRevocation) do
      :ok
    else
      start_supervised!(AgentCertificateRevocation)
    end
  end

  def certificate_der!(certificate_pem) do
    certificate_pem
    |> :public_key.pem_decode()
    |> Enum.find_value(fn
      {:Certificate, der, :not_encrypted} -> der
      _ -> nil
    end) ||
      flunk("issued bundle did not include a certificate")
  end

  def generate_ca_bundle!(ca_cert, ca_key) do
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

  def unique_tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
      )

    File.mkdir_p!(dir)
    dir
  end
end

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

  # A leaf carrying ONLY a subject CN -- no SAN, so no SPIFFE id -- signed directly by the CA.
  # Returns the certificate DER.
  def issue_cn_only_certificate!(ca_cert, ca_key, cn, dir) do
    key = Path.join(dir, "cn-only-key.pem")
    csr = Path.join(dir, "cn-only.csr")
    cert = Path.join(dir, "cn-only.pem")

    openssl!(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-subj", "/CN=#{cn}"])

    openssl!(~w(x509 -req -in #{csr} -CA #{ca_cert} -CAkey #{ca_key} -CAcreateserial -out #{cert} -days 1 -sha256))

    cert |> File.read!() |> certificate_der!()
  end

  # The DER SubjectPublicKeyInfo SHA-256 of a PEM certificate, read through openssl rather than
  # the resolver under test.
  def spki_sha256!(cert_pem_path) do
    {pem, 0} = System.cmd("openssl", ["x509", "-in", cert_pem_path, "-noout", "-pubkey"])
    [{:SubjectPublicKeyInfo, der, :not_encrypted}] = :public_key.pem_decode(pem)
    :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)
  end

  defp openssl!(args) do
    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("openssl #{hd(args)} failed (#{status}): #{output}")
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

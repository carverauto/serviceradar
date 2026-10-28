defmodule ServiceRadarAgentGateway.TlsDiagnosticLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.TlsDiagnosticLogger

  setup do
    parent_dir = CertificateTestHelpers.unique_tmp_dir!("tls-diagnostic-logger-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

    {:ok, bundle} =
      CertIssuer.issue_agent_bundle(
        "agent-diag-1",
        "partition-alpha",
        :agent,
        ca_cert_file: ca_cert,
        ca_key_file: ca_key,
        temp_parent_dir: parent_dir,
        audit_writer: nil
      )

    cert_der = CertificateTestHelpers.certificate_der!(bundle.certificate_pem)
    otp_cert = :public_key.pkix_decode_cert(cert_der, :otp)

    %{cert_der: cert_der, otp_cert: otp_cert}
  end

  test "logs structured warning for expired client certificate handshake failure", %{
    otp_cert: otp_cert
  } do
    log =
      capture_log(fn ->
        assert {:fail, :cert_expired} =
                 TlsDiagnosticLogger.ssl_verify(otp_cert, {:bad_cert, :cert_expired}, %{})
      end)

    assert log =~ "Edge mTLS peer certificate rejected:"
    assert log =~ "reason=certificate_expired"
    assert log =~ "subject=agent-diag-1.partition-alpha.serviceradar"
    assert log =~ "component_id=agent-diag-1"
    assert log =~ "partition_id=partition-alpha"
    assert log =~ "issuer=ServiceRadar Test Root"
    assert log =~ "serial="
    assert log =~ "not_after="
  end

  test "logs structured warning for unknown CA and bad_cert handshake failures", %{
    otp_cert: otp_cert,
    cert_der: cert_der
  } do
    unknown_ca_log =
      capture_log(fn ->
        assert {:fail, :unknown_ca} =
                 TlsDiagnosticLogger.ssl_verify(otp_cert, {:bad_cert, :unknown_ca}, %{})
      end)

    assert unknown_ca_log =~ "reason=unknown_ca"
    assert unknown_ca_log =~ "subject=agent-diag-1.partition-alpha.serviceradar"
    assert unknown_ca_log =~ "issuer=ServiceRadar Test Root"

    bad_cert_log =
      capture_log(fn ->
        diag = TlsDiagnosticLogger.log_handshake_failure({:bad_cert, :selfsigned_peer}, cert_der)
        assert diag.reason == :bad_cert
        assert diag.component_id == "agent-diag-1"
        assert diag.partition_id == "partition-alpha"
        assert byte_size(diag.serial) > 0
        assert %DateTime{} = diag.not_after
      end)

    assert bad_cert_log =~ "reason=bad_cert"
    assert bad_cert_log =~ "subject=agent-diag-1.partition-alpha.serviceradar"
  end
end

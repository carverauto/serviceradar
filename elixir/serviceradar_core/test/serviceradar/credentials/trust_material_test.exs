defmodule ServiceRadar.Credentials.Validations.TrustMaterialTest do
  use ExUnit.Case, async: true

  alias Ash.Changeset
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.Validations.TrustMaterial

  # Invented self-signed CA used only as a valid PEM CERTIFICATE fixture.
  # Not captured from a deployment.
  @synthetic_cluster_ca """
  -----BEGIN CERTIFICATE-----
  MIIDUTCCAjmgAwIBAgIUKUZwSCVIDKvZGoamLzkMXzJs9Z0wDQYJKoZIhvcNAQEL
  BQAwODEgMB4GA1UEAwwXVGVzdCBDbHVzdGVyIE1hbmFnZXIgQ0ExFDASBgNVBAoM
  C0V4YW1wbGUgT3JnMB4XDTI2MDkwNTEwMTAxM1oXDTM2MDkwMjEwMTAxM1owODEg
  MB4GA1UEAwwXVGVzdCBDbHVzdGVyIE1hbmFnZXIgQ0ExFDASBgNVBAoMC0V4YW1w
  bGUgT3JnMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0YIpcYqFn0Ff
  l0biMHv6hgcbfxItJ66/cICfrrRypBkEUnPMC0j3Zt8Za8TUkMSs05fA0HcK4IMN
  4zcy3axUZa8xi4C1EdhwNbQ2Lb9fMUhCBdy/CYzbX/UFh67G/mc2PLo6Ut/D0BXj
  g93PQBgRJp9/2dU9Lbg4r01Jisb46xwj2ag70Wxul9iok14s4wemnwLiLVxI3T/N
  7cIzrbI8XqwLVKbT8b56hpB2PlCw4QaBIMnmGADGEKAgPYzffaO4Y/lx84wPQUKy
  l0MRjXjh7o8XnEqf0s7zdL+zpRtFdlWu5LV22Z9W6XPaXBoU1xrN8JwozLeGmQwM
  /9tw/8L6hQIDAQABo1MwUTAdBgNVHQ4EFgQUWbYdBESaLWUifO7OZgIIJ3ga0SAw
  HwYDVR0jBBgwFoAUWbYdBESaLWUifO7OZgIIJ3ga0SAwDwYDVR0TAQH/BAUwAwEB
  /zANBgkqhkiG9w0BAQsFAAOCAQEAMdYVgV3P3Ku/FpuTlaWk6SfckmtnveBNp2J7
  ql7yO3sc5TMY/RH59hDdA7qb7JDQCCLgzgU1OfSQ3WATw0cFwiGR7Ms4NUq3cnYa
  N91Zw39hfNYZS7iiMjAc/u1KfOeGO19wsyMfWf4cJCgEHVp2ixFnfEHvBTLBu72J
  /g8AgzTHy8L7EW0rY2QfiLozKhvNuTKf/pL+YyOcazWbtGH07DfSJgrHu+025h3h
  T0opheaYh9j1yhgaiMCAIoveAWJYaRWDRz8SsPBPlbwLGmjptNI2eCjvMmde9L6m
  kwxElYAKzP7iL0DAiomV14hpww2FwS9ZLX3li6Lp/K/S0UZocw==
  -----END CERTIFICATE-----
  """

  describe "no trust material" do
    test "a rule without either field is valid" do
      assert :ok = validate(%{})
    end

    test "blank strings are treated as absent" do
      assert :ok = validate(%{ca_bundle_pem: "   ", server_cert_fingerprint: ""})
    end
  end

  describe "server_cert_fingerprint" do
    test "accepts sha256 followed by 64 lowercase hex characters" do
      assert :ok = validate(%{server_cert_fingerprint: "sha256:" <> String.duplicate("a1", 32)})
    end

    test "rejects a bare hex digest with no algorithm prefix" do
      assert {:error, opts} = validate(%{server_cert_fingerprint: String.duplicate("a1", 32)})
      assert opts[:field] == :server_cert_fingerprint
    end

    test "rejects uppercase hex" do
      assert {:error, _} =
               validate(%{server_cert_fingerprint: "sha256:" <> String.duplicate("A1", 32)})
    end

    test "rejects a digest of the wrong length" do
      assert {:error, _} = validate(%{server_cert_fingerprint: "sha256:abcdef"})
    end

    test "rejects a colon-separated OpenSSL-style digest" do
      openssl_style =
        Enum.map_join(1..32, ":", fn _ -> "a1" end)

      assert {:error, _} = validate(%{server_cert_fingerprint: "sha256:" <> openssl_style})
    end
  end

  describe "ca_bundle_pem" do
    test "accepts a valid PEM certificate chain" do
      assert :ok = validate(%{ca_bundle_pem: @synthetic_cluster_ca})
    end

    test "rejects text that is not PEM at all" do
      assert {:error, opts} = validate(%{ca_bundle_pem: "not a certificate"})
      assert opts[:field] == :ca_bundle_pem
    end

    test "rejects a PEM block that is not a certificate" do
      csr_pem = """
      -----BEGIN CERTIFICATE REQUEST-----
      MIHnMIGdAgEAMCsxKTAnBgNVBAMMIG5vdC1hLWNlcnRpZmljYXRlLmV4YW1wbGUu
      -----END CERTIFICATE REQUEST-----
      """

      assert {:error, opts} = validate(%{ca_bundle_pem: csr_pem})
      assert opts[:field] == :ca_bundle_pem
    end
  end

  describe "mutual exclusivity" do
    test "supplying both forms is rejected" do
      assert {:error, opts} =
               validate(%{
                 ca_bundle_pem: @synthetic_cluster_ca,
                 server_cert_fingerprint: "sha256:" <> String.duplicate("a1", 32)
               })

      assert opts[:field] == :server_cert_fingerprint
    end
  end

  defp validate(attrs) do
    NetworkCredentialRule
    |> Changeset.new()
    |> then(fn changeset ->
      Enum.reduce(attrs, changeset, fn {field, value}, acc ->
        Changeset.force_change_attribute(acc, field, value)
      end)
    end)
    |> TrustMaterial.validate([], %{})
  end
end

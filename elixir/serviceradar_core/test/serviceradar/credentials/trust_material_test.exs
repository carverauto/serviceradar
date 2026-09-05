defmodule ServiceRadar.Credentials.Validations.TrustMaterialTest do
  use ExUnit.Case, async: true

  alias Ash.Changeset
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.Validations.TrustMaterial

  # A real Proxmox VE cluster CA, captured from demo pve02
  # (/etc/pve/pve-root-ca.pem). It is a public trust anchor, not a secret, and
  # using the genuine article is the point: the hand-rolled RFC 5280 validity
  # parsing below is exercised against a certificate PVE actually issues rather
  # than one shaped to suit the parser.
  @pve_cluster_ca """
  -----BEGIN CERTIFICATE-----
  MIIFzTCCA7WgAwIBAgIUHue7uth6SOpAAeulaimp/rF9m74wDQYJKoZIhvcNAQEL
  BQAwdjEkMCIGA1UEAwwbUHJveG1veCBWaXJ0dWFsIEVudmlyb25tZW50MS0wKwYD
  VQQLDCQyNDYxMzQ4NS1jYjI5LTRiMGUtOTViMi00YWEyOTVjMjI3MmExHzAdBgNV
  BAoMFlBWRSBDbHVzdGVyIE1hbmFnZXIgQ0EwHhcNMjUwNTI0MTYzNTQzWhcNMzUw
  NTIyMTYzNTQzWjB2MSQwIgYDVQQDDBtQcm94bW94IFZpcnR1YWwgRW52aXJvbm1l
  bnQxLTArBgNVBAsMJDI0NjEzNDg1LWNiMjktNGIwZS05NWIyLTRhYTI5NWMyMjcy
  YTEfMB0GA1UECgwWUFZFIENsdXN0ZXIgTWFuYWdlciBDQTCCAiIwDQYJKoZIhvcN
  AQEBBQADggIPADCCAgoCggIBAKhu65kvsNBe6lTMzIWinpHMZ/Ft6ank1y1wrUmM
  sek87dNEVemjpEeJrjOag50EnnKI5Uhghp/PbvGvyVTE8zewAr9/R1POgusOTJxR
  T7bW+Iwc30kmnO7zHIipVlN7vH59NJi8kTPeBUlcT/O1wYQbOsNYGET9it95PVKq
  jQUPq0tU3irntqmf9PYfu0U4x4ct8LCi76fZ2tl5zY7S6eQccJE3/D1o/n2+NUJ5
  O7+L7xcVgjJYAXGQ0YVoODztV9tXGXZK9/cHz7dd3/gBOphddYqc1zp8E0IziFZ2
  /x9gQClPo/5E/tG0u2mh+jC9oaazh5NzdylvgnUs3GhZibTBLo7arh8pcnLuNenW
  0HBVvWGJHJTEE3c5jbtth+vFMht9blfBjbAavpfSO6OpK5w0SvcEOb0VNZxuaLnC
  fNAejUyO83EIFI3sMGn6g4+ui9UhUOsfQTkvZv7N7YDowM2EFL1kSgW9a0K3Kbza
  7/EqgTMmXntqiqcUiX2lKRujypt68v7KDBVKIGhryaLqpA0cfbkStPxjHyYH52ag
  /kWjRkx6NqplPB9o4NHQewcCKmLn43+FO503msVjd4kKiUmdxjK/0k6rVsHyWZ+5
  DZ95MkQRzZWk8GCxB+L3bJegMv/W8TNtgJIZoPc4GEkJ/l5fC0ZHolKHGRzxq9EQ
  qVl1AgMBAAGjUzBRMB0GA1UdDgQWBBQC3I7UVO2akE2n3bBFt9jn0qCMqDAfBgNV
  HSMEGDAWgBQC3I7UVO2akE2n3bBFt9jn0qCMqDAPBgNVHRMBAf8EBTADAQH/MA0G
  CSqGSIb3DQEBCwUAA4ICAQCNT4e2Fd452xKQmwbBBtVRT66+ddXp7QmXcsJ4vM7X
  Wl+eAcxqkdqB/wtNmHe3BMuv+o4uSPooZdlujIVUfn+VHrP2jB9DqULEiModQ3sr
  s17gzIGCUd388+/ywyueQNph7VStiYe8jm+WdMmQFaxPKpnRvaqUGsEnI6VVoFKD
  71ZOpMujDwEwTsI6LqpRlX24oqRMHB7PkAFljS4p47n1jtphM6VXKUlC8fgmqbSP
  hG2xXzydzn1QKDdzTgsktpDUswfSZlj/CFaU6aYkm5foieC8kz7IjavmbNexcnT+
  KcnVcDaAkpruWl0lrleITd/StUO4ztrPPrc9p0tdkIKsRUc9hm18gzfwDhuAGrrX
  aWIIlQwF3fY44fjQQebIlShjTdPAx1hM+K9QvlcToZuu44ipl7blV92z5pboi3/a
  FyYkBniYpLivaiWyQ0CP6vn3sf2odN+IavlUKJcnGXnFo61GmOxRbI1Z5gzvttPt
  iWWUZ3679Xv6Kr46MX1caYt6GpjXiRxHY5ADOlCwT0vFrPQw/XiAV3sd0Hq21oTp
  P5G2xn+hDnvP9I2Rtrq9qjAQfyo45RIontII2dn2RK4xrJ4pA2gHbZN6M+BiKT+N
  Vwvr29zb9Cdhx6/+KqWY9rA3Lt2bxJpXiO5DcJt2cjWArTOjz1mXjrcl4e3OcCSv
  gw==
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
    test "accepts a real Proxmox cluster CA" do
      assert :ok = validate(%{ca_bundle_pem: @pve_cluster_ca})
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
                 ca_bundle_pem: @pve_cluster_ca,
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

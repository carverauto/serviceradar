defmodule ServiceRadar.Policies.OutboundURLPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Policies.OutboundURLPolicy

  test "accepts public https urls" do
    assert {:ok, %URI{scheme: "https", host: "example.com"}} =
             OutboundURLPolicy.validate_https_public_url("https://example.com/releases/latest")
  end

  test "rejects invalid or insecure urls" do
    assert {:error, :invalid_url} = OutboundURLPolicy.validate_https_public_url("")
    assert {:error, :invalid_url} = OutboundURLPolicy.validate_https_public_url("example.com")

    assert {:error, :disallowed_scheme} =
             OutboundURLPolicy.validate_https_public_url("http://example.com")
  end

  test "rejects private and local urls" do
    assert {:error, :disallowed_host} =
             OutboundURLPolicy.validate_https_public_url("https://localhost/path")

    assert {:error, :disallowed_host} =
             OutboundURLPolicy.validate_https_public_url("https://10.0.0.5/path")

    assert {:error, :disallowed_host} =
             OutboundURLPolicy.validate_https_public_url("https://[::ffff:169.254.169.254]/")
  end

  test "requires allowlisted ports" do
    assert {:ok, _} = OutboundURLPolicy.validate_https_public_url("https://1.1.1.1")
    assert {:ok, _} = OutboundURLPolicy.validate_https_public_url("https://1.1.1.1:443")

    assert {:error, :disallowed_port} =
             OutboundURLPolicy.validate_https_public_url("https://1.1.1.1:8443")

    assert {:ok, _} =
             OutboundURLPolicy.validate_https_public_url("https://1.1.1.1:8443",
               allowed_ports: [443, 8443]
             )
  end
end

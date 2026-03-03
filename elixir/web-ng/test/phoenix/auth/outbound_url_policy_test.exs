defmodule ServiceRadarWebNGWeb.Auth.OutboundURLPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Auth.OutboundURLPolicy

  test "allows https URLs" do
    assert {:ok, %URI{scheme: "https", host: "example.com"}} =
             OutboundURLPolicy.validate("https://example.com/.well-known/openid-configuration")
  end

  test "rejects http URLs by default" do
    assert {:error, :disallowed_scheme} = OutboundURLPolicy.validate("http://example.com/jwks")
  end

  test "rejects localhost URLs" do
    assert {:error, :disallowed_host} =
             OutboundURLPolicy.validate("https://localhost/.well-known/openid-configuration")
  end

  test "rejects private IPv4 URLs" do
    assert {:error, :disallowed_host} = OutboundURLPolicy.validate("https://10.1.2.3/jwks")
    assert {:error, :disallowed_host} = OutboundURLPolicy.validate("https://192.168.10.8/jwks")
    assert {:error, :disallowed_host} = OutboundURLPolicy.validate("https://127.0.0.1/jwks")
  end
end

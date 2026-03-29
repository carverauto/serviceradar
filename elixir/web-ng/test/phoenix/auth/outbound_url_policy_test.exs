defmodule ServiceRadarWebNGWeb.Auth.OutboundURLPolicyTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Auth.OutboundURLPolicy

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :allow_insecure_metadata_urls)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :allow_insecure_metadata_urls, previous)
    end)

    :ok
  end

  test "allows https URLs" do
    assert {:ok, %URI{scheme: "https", host: "example.com"}} =
             OutboundURLPolicy.validate("https://example.com/.well-known/openid-configuration")
  end

  test "rejects http URLs by default" do
    assert {:error, :disallowed_scheme} = OutboundURLPolicy.validate("http://example.com/jwks")
  end

  test "rejects http URLs even when insecure metadata config is enabled" do
    Application.put_env(:serviceradar_web_ng, :allow_insecure_metadata_urls, true)

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

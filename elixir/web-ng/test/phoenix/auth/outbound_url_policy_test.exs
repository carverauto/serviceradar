defmodule ServiceRadarWebNGWeb.Auth.OutboundURLPolicyTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Auth.OutboundURLPolicy

  @moduletag :db_free

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

  test "req_opts keeps conservative timeouts and no redirects" do
    opts = OutboundURLPolicy.req_opts()

    assert opts[:connect_options] == [timeout: 5_000]
    assert opts[:receive_timeout] == 10_000
    assert opts[:redirect] == false
  end

  test "req_opts retries a closed pooled connection on GET/HEAD" do
    retry = OutboundURLPolicy.req_opts()[:retry]

    assert is_function(retry, 2)
    assert retry.(%{method: :get}, %Req.TransportError{reason: :closed})
    assert retry.(%{method: :head}, %Req.TransportError{reason: :closed})
  end

  test "req_opts never retries POST - the token exchange owns its own retry" do
    retry = OutboundURLPolicy.req_opts()[:retry]

    refute retry.(%{method: :post}, %Req.TransportError{reason: :closed})
  end

  test "req_opts does not retry a timeout - retrying only stalls the user" do
    retry = OutboundURLPolicy.req_opts()[:retry]

    refute retry.(%{method: :get}, %Req.TransportError{reason: :timeout})
    refute retry.(%{method: :get}, %Req.TransportError{reason: :econnrefused})
    refute retry.(%{method: :get}, %Req.Response{status: 503})
    refute retry.(%{method: :get}, :dns_resolution_failed)
  end

  test "req_opts disables Req retry chatter" do
    assert OutboundURLPolicy.req_opts()[:retry_log_level] == false
  end
end

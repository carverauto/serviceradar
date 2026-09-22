defmodule ServiceRadarWebNGWeb.Auth.OutboundFetchTest do
  use ExUnit.Case, async: true

  alias Req.Request
  alias ServiceRadarWebNGWeb.Auth.OutboundFetch

  @moduletag :db_free

  test "build_request binds the request to the validated address and preserves host identity" do
    assert {:ok, request} =
             OutboundFetch.build_request(
               :get,
               "https://1.1.1.1/.well-known/openid-configuration",
               resolved_address: {93, 184, 216, 34}
             )

    assert request.method == :get
    assert request.url.host == "93.184.216.34"
    assert Request.get_header(request, "host") == ["1.1.1.1"]

    assert Request.get_option(request, :connect_options)[:hostname] == "1.1.1.1"
    assert Request.get_option(request, :redirect) == false
  end

  test "build_request refuses non-allowlisted ports" do
    assert {:error, :disallowed_port} =
             OutboundFetch.build_request(
               :get,
               "https://1.1.1.1:8443/.well-known/openid-configuration",
               resolved_address: {93, 184, 216, 34}
             )
  end

  test "timeouts fail fast instead of entering Req retry backoff" do
    assert {:ok, request} =
             OutboundFetch.build_request(
               :get,
               "https://1.1.1.1/.well-known/openid-configuration",
               resolved_address: {93, 184, 216, 34}
             )

    retry = Request.get_option(request, :retry)
    assert is_function(retry, 2)
    refute retry.(request, %Req.TransportError{reason: :timeout})
    assert retry.(request, %Req.TransportError{reason: :closed})
    assert Request.get_option(request, :retry_log_level) == false
  end

  test "POST requests are never retried - the token exchange owns its retry" do
    assert {:ok, request} =
             OutboundFetch.build_request(
               :post,
               "https://1.1.1.1/token",
               resolved_address: {93, 184, 216, 34}
             )

    retry = Request.get_option(request, :retry)
    assert is_function(retry, 2)
    refute retry.(request, %Req.TransportError{reason: :closed})
  end

  test "redirects cannot be enabled by caller options" do
    assert {:ok, request} =
             OutboundFetch.build_request(
               :get,
               "https://1.1.1.1/.well-known/openid-configuration",
               resolved_address: {93, 184, 216, 34},
               redirect: true
             )

    assert Request.get_option(request, :redirect) == false
  end
end

defmodule ServiceRadar.Policies.OutboundFetchTest do
  use ExUnit.Case, async: true

  alias Req.Request
  alias ServiceRadar.Policies.OutboundFetch

  test "build_request binds to the resolved address and keeps original host identity" do
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

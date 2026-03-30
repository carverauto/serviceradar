defmodule ServiceRadarWebNGWeb.Auth.OutboundFetchTest do
  use ExUnit.Case, async: true

  alias Req.Request
  alias ServiceRadarWebNGWeb.Auth.OutboundFetch

  test "build_request binds the request to the validated address and preserves host identity" do
    assert {:ok, request} =
             OutboundFetch.build_request(
               :get,
               "https://idp.example.com/.well-known/openid-configuration",
               resolved_address: {93, 184, 216, 34}
             )

    assert request.method == :get
    assert request.url.host == "93.184.216.34"
    assert Request.get_header(request, "host") == ["idp.example.com"]

    assert Request.get_option(request, :connect_options)[:hostname] == "idp.example.com"
    assert Request.get_option(request, :redirect) == false
  end
end

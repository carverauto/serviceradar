defmodule ServiceRadarWebNGWeb.Router.SAMLACSRouteTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Router

  @moduletag :db_free

  # The IdP's POST carries neither a CSRF token nor, usually, the session cookie,
  # so the assertion consumer must not sit behind :browser's forgery protection.
  # The controller test drives the endpoint end to end; this keeps the routing
  # decision visible in the database-free tier.
  test "the assertion consumer runs in the :saml_acs pipeline, not :browser" do
    info = Phoenix.Router.route_info(Router, "POST", "/auth/saml/consume", "localhost")

    assert info.plug == ServiceRadarWebNGWeb.SAMLController
    assert info.plug_opts == :consume
    assert info.pipe_through == [:saml_acs, :rate_limit_auth_saml]
  end

  test "starting a SAML login stays in the :browser pipeline" do
    info = Phoenix.Router.route_info(Router, "GET", "/auth/saml", "localhost")

    assert info.plug_opts == :request
    assert :browser in info.pipe_through
  end
end

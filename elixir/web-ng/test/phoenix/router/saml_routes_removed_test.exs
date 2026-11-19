defmodule ServiceRadarWebNGWeb.Router.SAMLRoutesRemovedTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Router

  @moduletag :db_free

  # SAML was removed, and with it the unauthenticated assertion consumer. The
  # former SAML endpoints must not be served by anything: the router raises
  # NoRouteError, which the endpoint renders as a 404.
  test "the former SAML endpoints are not routed and answer 404" do
    for {method, path} <- [
          {"GET", "/auth/saml"},
          {"GET", "/auth/saml/metadata"},
          {"POST", "/auth/saml/consume"}
        ] do
      error =
        assert_raise Phoenix.Router.NoRouteError, fn ->
          method
          |> Plug.Test.conn(path)
          |> Router.call(Router.init([]))
        end

      assert Plug.Exception.status(error) == 404
    end
  end
end

defmodule ServiceRadarWebNGWeb.Router.PublicRegistrationRouteTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Router

  @moduletag :db_free

  test "public password registration is not routed" do
    assert Phoenix.Router.route_info(Router, "POST", "/auth/register", "localhost") == :error
  end
end

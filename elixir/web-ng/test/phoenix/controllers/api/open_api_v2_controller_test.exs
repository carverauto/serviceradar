defmodule ServiceRadarWebNGWeb.Api.OpenApiV2ControllerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias ServiceRadarWebNGWeb.Api.OpenApiV2Controller
  alias ServiceRadarWebNGWeb.AshJsonApiRouter

  @moduletag :db_free

  test "AshJsonApiRouter mounts the Notifications domain" do
    assert ServiceRadar.Notifications in AshJsonApiRouter.domains()
  end

  test "show/2 generates OpenAPI document containing Notifications routes" do
    conn =
      :get
      |> conn("/api/v2/open_api")
      |> OpenApiV2Controller.show(%{})

    assert conn.status == 200
    doc = Jason.decode!(conn.resp_body)
    assert doc["openapi"] =~ "3.0"
    assert Map.has_key?(doc["paths"], "/api/v2/notification-channels")
    assert Map.has_key?(doc["paths"], "/api/v2/notification-routes")
  end
end

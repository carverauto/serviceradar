defmodule ServiceRadarWebNG.Api.OpenapiControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.AshTestHelpers

  describe "GET /api/admin/openapi" do
    test "returns admin OpenAPI document for admin user", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      conn =
        conn
        |> log_in_user(admin)
        |> get(~p"/api/admin/openapi")

      assert conn.status == 200
      body = json_response(conn, 200)

      assert body["openapi"] == "3.0.3"
      assert get_in(body, ["paths", "/api/admin/bmp-settings", "get"])
      assert get_in(body, ["paths", "/api/admin/bmp-settings", "put"])
      assert get_in(body, ["components", "schemas", "BmpSettings"])
    end

    test "returns 403 for viewer", %{conn: conn} do
      viewer = AshTestHelpers.viewer_user_fixture()

      conn =
        conn
        |> log_in_user(viewer)
        |> get(~p"/api/admin/openapi")

      assert conn.status == 403
    end
  end
end

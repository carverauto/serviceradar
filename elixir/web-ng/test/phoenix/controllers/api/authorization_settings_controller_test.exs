defmodule ServiceRadarWebNGWeb.Api.AuthorizationSettingsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.AshTestHelpers

  describe "GET /api/admin/authorization-settings" do
    test "returns settings for admin", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      conn =
        conn
        |> log_in_user(admin)
        |> get(~p"/api/admin/authorization-settings")

      assert conn.status == 200

      body = json_response(conn, 200)
      assert Map.has_key?(body, "default_role")
      assert Map.has_key?(body, "role_mappings")
    end

    test "returns 403 for non-admin", %{conn: conn} do
      user = AshTestHelpers.viewer_user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/api/admin/authorization-settings")

      assert conn.status == 403
    end
  end

  describe "PUT /api/admin/authorization-settings" do
    test "updates settings for admin", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      conn =
        conn
        |> log_in_user(admin)
        |> put(~p"/api/admin/authorization-settings", %{
          "default_role" => "operator",
          "role_mappings" => [%{"source" => "groups", "value" => "NetOps", "role" => "operator"}]
        })

      assert conn.status == 200
      body = json_response(conn, 200)
      assert body["default_role"] == "operator"
    end

    test "returns 422 for invalid role_mappings json", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      conn =
        conn
        |> log_in_user(admin)
        |> put(~p"/api/admin/authorization-settings", %{
          "default_role" => "viewer",
          "role_mappings" => "{invalid json}"
        })

      assert conn.status == 422

      body = json_response(conn, 422)
      assert body["error"] == "validation_error"

      details = body["details"] || []
      assert is_list(details)

      assert Enum.any?(details, fn item ->
               (item["field"] || "") == "role_mappings" and (item["message"] || "") =~ "invalid"
             end)
    end
  end
end

defmodule ServiceRadarWebNG.Api.AuthorizationSettingsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    admin = AshTestHelpers.admin_user_fixture()
    conn = log_in_api_user(conn, admin)
    scope = ServiceRadarWebNG.Accounts.Scope.for_user(admin)
    %{conn: conn, admin: admin, scope: scope}
  end

  describe "GET /api/admin/authorization-settings" do
    test "returns default settings", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/authorization-settings")
      result = json_response(conn, 200)

      assert result["default_role"] == "viewer"
      assert result["role_mappings"] == []
    end
  end

  describe "PUT /api/admin/authorization-settings" do
    test "updates settings", %{conn: conn, scope: scope} do
      params = %{
        "default_role" => "operator",
        "role_mappings" => [
          %{"source" => "groups", "value" => "Network Ops", "role" => "operator"},
          %{"source" => "email_domain", "value" => "example.com", "role" => "admin"}
        ]
      }

      conn = put(conn, ~p"/api/admin/authorization-settings", params)
      result = json_response(conn, 200)

      assert result["default_role"] == "operator"
      assert length(result["role_mappings"]) == 2

      {:ok, settings} =
        AuthorizationSettings
        |> Ash.Query.for_read(:get_singleton, %{}, scope: scope)
        |> Ash.read_one(scope: scope)

      assert settings.default_role == :operator
    end

    test "rejects invalid role", %{conn: conn} do
      params = %{"default_role" => "invalid"}

      conn = put(conn, ~p"/api/admin/authorization-settings", params)

      assert json_response(conn, 400)["error"] =~ "default_role must be one of"
    end
  end

  describe "admin access" do
    test "non-admin is forbidden", %{conn: conn} do
      viewer = AshTestHelpers.user_fixture()
      conn = log_in_api_user(conn, viewer)

      conn = get(conn, ~p"/api/admin/authorization-settings")
      assert json_response(conn, 403)["errors"]["detail"] == "Forbidden"
    end
  end
end

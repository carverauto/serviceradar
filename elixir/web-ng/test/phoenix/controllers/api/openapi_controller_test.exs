defmodule ServiceRadarWebNGWeb.Api.OpenapiControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNGWeb.OpenAPI.AdminSpec

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
      assert get_in(body, ["paths", "/api/admin/users", "get"])
      assert get_in(body, ["paths", "/api/admin/edge-packages/{id}/download", "post"])
      assert get_in(body, ["paths", "/api/admin/plugin-packages/{id}/approve", "post"])
      assert get_in(body, ["paths", "/api/admin/collectors/{id}/download", "post"])
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

  describe "GET /api/docs/v1/admin/openapi.json" do
    test "returns public published OpenAPI document without authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/docs/v1/admin/openapi.json")

      assert conn.status == 200
      body = json_response(conn, 200)

      assert body["openapi"] == "3.0.3"
      assert body["x-serviceradar-doc-version"] == "v1"
      assert body["x-serviceradar-doc-surface"] == "admin"
      assert body["x-serviceradar-doc-source"] == "serviceradar-web-ng"
      assert body["x-serviceradar-doc-artifact-path"] == AdminSpec.portal_artifact_path()
      assert get_in(body, ["paths", "/api/admin/users", "get"])
      assert get_in(body, ["components", "schemas", "BmpSettings"])
    end
  end

  describe "GET /api/v2/open_api" do
    test "returns the Ash JSON:API OpenAPI document without authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/open_api")

      assert conn.status == 200
      body = json_response(conn, 200)

      assert body["openapi"] == "3.0.3"
      assert get_in(body, ["info", "title"]) == "ServiceRadar API"
      assert get_in(body, ["info", "version"]) == "2.0.0"
      assert is_map(body["paths"])
    end
  end

  describe "GET /api/v2/swaggerui" do
    test "renders SwaggerUI for the Ash JSON:API OpenAPI document", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/swaggerui")

      assert conn.status == 200
      body = html_response(conn, 200)

      assert body =~ "Swagger UI"
      assert body =~ "/api/v2/open_api"
    end
  end

  describe "GET /api/v2/redoc" do
    test "renders Redoc for the Ash JSON:API OpenAPI document", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/redoc")

      assert conn.status == 200
      body = html_response(conn, 200)

      assert body =~ "ReDoc"
      assert body =~ "/api/v2/open_api"
    end
  end
end

defmodule ServiceRadarWebNGWeb.Api.BmpSettingsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.AshTestHelpers

  describe "GET /api/admin/bmp-settings" do
    test "returns settings for admin", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      conn =
        conn
        |> log_in_user(admin)
        |> get(~p"/api/admin/bmp-settings")

      assert conn.status == 200

      body = json_response(conn, 200)
      assert Map.has_key?(body, "bmp_routing_retention_days")
      assert Map.has_key?(body, "bmp_ocsf_min_severity")
      assert Map.has_key?(body, "god_view_causal_overlay_window_seconds")
      assert Map.has_key?(body, "god_view_causal_overlay_max_events")
      assert Map.has_key?(body, "god_view_routing_causal_severity_threshold")
    end

    test "returns 403 for viewer", %{conn: conn} do
      user = AshTestHelpers.viewer_user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/api/admin/bmp-settings")

      assert conn.status == 403
    end
  end

  describe "PUT /api/admin/bmp-settings" do
    test "updates settings for admin", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      conn =
        conn
        |> log_in_user(admin)
        |> put(~p"/api/admin/bmp-settings", %{
          "bmp_routing_retention_days" => "5",
          "bmp_ocsf_min_severity" => "3",
          "god_view_causal_overlay_window_seconds" => "240",
          "god_view_causal_overlay_max_events" => "700",
          "god_view_routing_causal_severity_threshold" => "2"
        })

      assert conn.status == 200
      body = json_response(conn, 200)
      assert body["bmp_routing_retention_days"] == 5
      assert body["bmp_ocsf_min_severity"] == 3
      assert body["god_view_causal_overlay_window_seconds"] == 240
      assert body["god_view_causal_overlay_max_events"] == 700
      assert body["god_view_routing_causal_severity_threshold"] == 2
    end

    test "returns 400 for invalid integer payload", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      conn =
        conn
        |> log_in_user(admin)
        |> put(~p"/api/admin/bmp-settings", %{
          "bmp_routing_retention_days" => "abc"
        })

      assert conn.status == 400
      body = json_response(conn, 400)
      assert body["error"] == "bmp_routing_retention_days must be an integer"
    end
  end
end

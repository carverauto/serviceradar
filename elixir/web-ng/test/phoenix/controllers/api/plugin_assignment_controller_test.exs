defmodule ServiceRadarWebNGWeb.Api.PluginAssignmentControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian

  describe "GET /api/admin/plugin-assignments/:id" do
    test "returns 404 for an unknown assignment", %{conn: conn} do
      user = admin_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(user)

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/admin/plugin-assignments/#{Ecto.UUID.generate()}")

      assert conn.status == 404
    end

    test "rejects viewers", %{conn: conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/admin/plugin-assignments/#{Ecto.UUID.generate()}")

      assert conn.status == 403
    end
  end
end

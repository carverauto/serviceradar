defmodule ServiceRadarWebNGWeb.Api.CameraRelayStreamControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.CameraRelayStreamController

  test "returns forbidden for browser viewers without devices.view", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.assign(
        :current_scope,
        %Scope{
          user: %{id: "viewer-unauthorized-1", email: "viewer@example.com", role: :viewer},
          permissions: MapSet.new()
        }
      )

    conn = CameraRelayStreamController.connect(conn, %{"id" => Ecto.UUID.generate()})
    body = json_response(conn, 403)

    assert body["error"] == "forbidden"
    assert body["message"] == "viewer is not authorized for camera relay access"
  end
end

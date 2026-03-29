defmodule ServiceRadarWebNGWeb.Api.SpatialControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  test "index fails closed without an authenticated scope", %{conn: conn} do
    conn = ServiceRadarWebNGWeb.Api.SpatialController.index(conn, %{})

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end
end

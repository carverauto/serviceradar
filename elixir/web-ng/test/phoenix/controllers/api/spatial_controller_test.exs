defmodule ServiceRadarWebNGWeb.Api.SpatialControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNG.Accounts.Scope

  test "index fails closed without an authenticated scope", %{conn: conn} do
    conn = ServiceRadarWebNGWeb.Api.SpatialController.index(conn, %{})

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end

  test "index returns forbidden without spatial sample permission", %{conn: conn} do
    conn =
      conn
      |> assign(:current_scope, %Scope{user: %{id: "viewer", email: "viewer@example.com"}, permissions: MapSet.new()})
      |> ServiceRadarWebNGWeb.Api.SpatialController.index(%{})

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "forbidden"}
  end
end

defmodule ServiceRadarWebNGWeb.PageControllerTest do
  use ServiceRadarWebNGWeb.ConnCase

  @moduletag :web_ng_shared_fixture_db

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end

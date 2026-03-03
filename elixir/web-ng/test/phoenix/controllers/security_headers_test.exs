defmodule ServiceRadarWebNGWeb.SecurityHeadersTest do
  use ServiceRadarWebNGWeb.ConnCase

  test "browser responses include hardened CSP without unsafe-inline scripts", %{conn: conn} do
    conn = get(conn, ~p"/")
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "script-src 'self' blob:"
    refute csp =~ "script-src 'self' 'unsafe-inline'"
  end
end

defmodule ServiceRadarWebNGWeb.SecurityHeadersTest do
  use ServiceRadarWebNGWeb.ConnCase

  test "browser responses include hardened CSP without unsafe-inline scripts", %{conn: conn} do
    conn = get(conn, ~p"/")

    csp =
      List.first(
        get_resp_header(conn, "content-security-policy") ++ get_resp_header(conn, "content-security-policy-report-only")
      )

    assert csp
    assert csp =~ "script-src 'self' blob:"
    assert csp =~ "media-src 'none'"
    assert csp =~ "frame-ancestors 'none'"
    refute csp =~ "script-src 'self' 'unsafe-inline'"
  end
end

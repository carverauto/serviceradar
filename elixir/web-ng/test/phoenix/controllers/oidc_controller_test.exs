defmodule ServiceRadarWebNGWeb.OIDCControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  test "rejects callback when OIDC session state and nonce are missing", %{conn: conn} do
    conn = get(conn, ~p"/auth/oidc/callback", %{code: "test-code", state: "test-state"})

    assert redirected_to(conn) == ~p"/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Authentication failed: invalid state. Please try again."
  end
end

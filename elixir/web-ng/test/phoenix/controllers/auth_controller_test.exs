defmodule ServiceRadarWebNGWeb.AuthControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNGWeb.Auth.RateLimiter

  @action "password_auth"
  @ip "127.0.0.1"

  setup do
    RateLimiter.clear_rate_limit(@action, @ip)

    on_exit(fn ->
      RateLimiter.clear_rate_limit(@action, @ip)
    end)

    :ok
  end

  test "password login is rate limited before authentication work begins", %{conn: conn} do
    Enum.each(1..10, fn _ -> RateLimiter.record_attempt(@action, @ip) end)

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post(~p"/auth/sign-in", %{
        "user" => %{"email" => "nobody@example.com", "password" => "bad-password"}
      })

    assert redirected_to(conn) == ~p"/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Too many login attempts. Please try again"
  end
end

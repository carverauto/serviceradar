defmodule ServiceRadarWebNGWeb.AuthControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNGWeb.Auth.RateLimiter

  @password_action "password_auth"
  @reset_action "password_reset"
  @ip "127.0.0.1"

  setup do
    RateLimiter.clear_rate_limit(@password_action, @ip)
    RateLimiter.clear_rate_limit(@reset_action, @ip)

    on_exit(fn ->
      RateLimiter.clear_rate_limit(@password_action, @ip)
      RateLimiter.clear_rate_limit(@reset_action, @ip)
    end)

    :ok
  end

  test "password login is rate limited before authentication work begins", %{conn: conn} do
    Enum.each(1..10, fn _ -> RateLimiter.record_attempt(@password_action, @ip) end)

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

  test "password reset is rate limited before notifier work begins", %{conn: conn} do
    Enum.each(1..5, fn _ -> RateLimiter.record_attempt(@reset_action, @ip) end)

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post(~p"/auth/password-reset", %{
        "user" => %{"email" => "nobody@example.com"}
      })

    assert redirected_to(conn) == ~p"/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Too many password reset requests. Please try again"
  end
end

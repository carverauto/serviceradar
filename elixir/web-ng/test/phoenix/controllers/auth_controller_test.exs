defmodule ServiceRadarWebNGWeb.AuthControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Security.RateLimiter

  @password_action :auth_local
  @reset_action :auth_password_reset
  @ip "127.0.0.1"

  setup do
    RateLimiter.clear(@password_action, @ip)
    RateLimiter.clear(@reset_action, @ip)

    on_exit(fn ->
      RateLimiter.clear(@password_action, @ip)
      RateLimiter.clear(@reset_action, @ip)
    end)

    :ok
  end

  test "password login is rate limited before authentication work begins", %{conn: conn} do
    Enum.each(1..10, fn _ -> RateLimiter.record(@password_action, @ip) end)

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
    Enum.each(1..5, fn _ -> RateLimiter.record(@reset_action, @ip) end)

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

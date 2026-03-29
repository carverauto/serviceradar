defmodule ServiceRadarWebNGWeb.OAuthControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNGWeb.Auth.RateLimiter

  @password_action "oauth_password_grant"
  @client_credentials_action "oauth_client_credentials"
  @ip "127.0.0.1"

  setup do
    RateLimiter.clear_rate_limit(@password_action, @ip)
    RateLimiter.clear_rate_limit(@client_credentials_action, @ip)

    on_exit(fn ->
      RateLimiter.clear_rate_limit(@password_action, @ip)
      RateLimiter.clear_rate_limit(@client_credentials_action, @ip)
    end)

    :ok
  end

  test "password grant is rate limited", %{conn: conn} do
    Enum.each(1..10, fn _ -> RateLimiter.record_attempt(@password_action, @ip) end)

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post(~p"/oauth/token", %{
        "grant_type" => "password",
        "username" => "nobody@example.com",
        "password" => "bad-password"
      })

    assert json_response(conn, 429)["error"] == "slow_down"
  end

  test "client credentials grant is rate limited", %{conn: conn} do
    Enum.each(1..20, fn _ -> RateLimiter.record_attempt(@client_credentials_action, @ip) end)

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post(~p"/oauth/token", %{
        "grant_type" => "client_credentials",
        "client_id" => Ecto.UUID.generate(),
        "client_secret" => "bad-secret"
      })

    assert json_response(conn, 429)["error"] == "slow_down"
  end
end

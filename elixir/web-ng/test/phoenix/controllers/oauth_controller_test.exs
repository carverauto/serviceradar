defmodule ServiceRadarWebNGWeb.OAuthControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.AshTestHelpers

  @password_action :oauth_password_grant
  @client_credentials_action :oauth_client_credentials
  @ip "127.0.0.1"

  setup do
    RateLimiter.clear(@password_action, @ip)
    RateLimiter.clear(@client_credentials_action, @ip)

    on_exit(fn ->
      RateLimiter.clear(@password_action, @ip)
      RateLimiter.clear(@client_credentials_action, @ip)
    end)

    :ok
  end

  test "password grant is rate limited", %{conn: conn} do
    Enum.each(1..10, fn _ -> RateLimiter.record(@password_action, @ip) end)

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
    Enum.each(1..20, fn _ -> RateLimiter.record(@client_credentials_action, @ip) end)

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

  # Regression: the whole OAuth2 client-credentials API-access path was broken
  # end-to-end (no API credential could ever list devices) due to three defects:
  #   1. OAuthClient `:authenticate` was a plain policy ANDed with the
  #      `action_type(:read)` policy, so a nil actor filtered every valid
  #      credential to empty -> `invalid_client` (now a bypass).
  #   2. The controller computed a SystemActor but never passed it to
  #      `OAuthClient.authenticate/3` (now passed as `actor:`).
  #   3. The bearer resolver pinned `token_type: "access"`, but api tokens are
  #      minted with `typ: "api"`, so `/api/*` rejected every OAuth-issued token
  #      with `authentication_required` (now verified without pinning the type).
  #
  # This test exercises the full path: mint a client -> POST /oauth/token ->
  # GET /api/devices with the issued Bearer token. Requires a DB.
  test "client_credentials token is accepted end-to-end by /api/devices", %{conn: _conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, client, raw_secret} =
      Credentials.create_client(user.id,
        name: "regression-oauth-client-#{System.unique_integer([:positive])}",
        scopes: ["read"],
        actor: AshTestHelpers.system_actor()
      )

    # (b) Exchange the raw client_secret for a Bearer access token.
    token_conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post(~p"/oauth/token", %{
        "grant_type" => "client_credentials",
        "client_id" => to_string(client.id),
        "client_secret" => raw_secret,
        "scope" => "read"
      })

    body = json_response(token_conn, 200)
    assert body["token_type"] == "Bearer"
    assert is_binary(body["access_token"]) and body["access_token"] != ""

    # (c) The issued token must be accepted by the `:api_auth` pipeline.
    # Before the fix this returned 401 `authentication_required`.
    api_conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("authorization", "Bearer #{body["access_token"]}")
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/devices")

    refute api_conn.status == 401
    assert api_conn.status in 200..299
  end
end

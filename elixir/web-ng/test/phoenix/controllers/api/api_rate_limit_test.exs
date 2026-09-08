defmodule ServiceRadarWebNGWeb.Api.ApiRateLimitTest do
  @moduledoc """
  Regression coverage for #319: the remote-access `/api` scope must be
  rate-limited (`:rate_limit_api_default`), not just authenticated
  (`:api_auth`).

  Floods an endpoint inside the scope with the `:api_default` bucket shrunk
  to 2 requests/minute and asserts the third request is denied with 429.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadar.Security.RateLimiter

  @ip "127.0.0.1"

  setup do
    # Keep the OAuth buckets clear so minting a token never trips an
    # unrelated limiter, and start the api_default bucket empty.
    RateLimiter.clear(:oauth_client_credentials, @ip)
    RateLimiter.clear(:oauth_password_grant, @ip)
    RateLimiter.clear(:api_default, @ip)

    # Shrink the production 120/minute bucket so the flood test needs only
    # three requests instead of 121.
    previous = Application.get_env(:serviceradar_core, RateLimiter)

    Application.put_env(
      :serviceradar_core,
      RateLimiter,
      Keyword.put(
        previous || [],
        :buckets,
        Map.put(
          Keyword.get(previous || [], :buckets, %{}),
          :api_default,
          limit: 2,
          window_seconds: 60
        )
      )
    )

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, RateLimiter)
      else
        Application.put_env(:serviceradar_core, RateLimiter, previous)
      end

      RateLimiter.clear(:oauth_client_credentials, @ip)
      RateLimiter.clear(:oauth_password_grant, @ip)
      RateLimiter.clear(:api_default, @ip)
    end)

    owner = admin_user_fixture()

    {:ok, client, secret} =
      Credentials.create_client(owner.id,
        name: "API Rate Limit #{System.unique_integer([:positive])}",
        scopes: ["read"],
        actor: owner
      )

    %{client: client, secret: secret}
  end

  test "flooding the /api scope trips the api_default bucket", %{
    client: client,
    secret: secret
  } do
    token = mint_token(client, secret)

    assert %{"entities" => _} =
             token |> api_conn() |> get(~p"/api/srql/catalog") |> json_response(200)

    assert %{"entities" => _} =
             token |> api_conn() |> get(~p"/api/srql/catalog") |> json_response(200)

    denied = token |> api_conn() |> get(~p"/api/srql/catalog")

    assert denied.status == 429
    assert get_resp_header(denied, "x-ratelimit-limit") == ["2"]
    assert get_resp_header(denied, "x-ratelimit-remaining") == ["0"]
    assert get_resp_header(denied, "retry-after") != []
  end

  test "unauthenticated flood is still 401 (auth runs before the limiter)", %{
    client: client,
    secret: secret
  } do
    token = mint_token(client, secret)
    RateLimiter.clear(:api_default, @ip)

    conn = get(build_conn(), ~p"/api/srql/catalog")

    assert json_response(conn, 401)["error"] == "authentication_required"

    # The authorized route still has its full (shrunk-for-test) budget: the
    # unauthenticated request above never consumed it.
    assert %{"entities" => _} =
             token |> api_conn() |> get(~p"/api/srql/catalog") |> json_response(200)
  end

  defp mint_token(client, secret) do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/oauth/token", %{
        "grant_type" => "client_credentials",
        "client_id" => client.id,
        "client_secret" => secret
      })

    json_response(conn, 200)["access_token"]
  end

  defp api_conn(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
  end
end

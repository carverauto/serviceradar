defmodule ServiceRadarWebNGWeb.Plugs.GatewayAuthPolicyTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Plugs.GatewayAuth
  alias ServiceRadarWebNGWeb.UserAuth

  @rsa_private_key JOSE.JWK.generate_key({:rsa, 2048})
  @rsa_public_key JOSE.JWK.to_public(@rsa_private_key)
  @rsa_public_pem elem(JOSE.JWK.to_pem(@rsa_public_key), 1)
  @issuer "https://gateway.example.com"
  @audience "serviceradar"

  setup do
    maybe_start_config_cache()
    clear_auth_cache()

    put_auth_settings(%{
      is_enabled: true,
      mode: :passive_proxy,
      jwt_header_name: "authorization",
      jwt_public_key_pem: nil,
      jwt_jwks_url: nil,
      jwt_issuer: @issuer,
      jwt_audience: @audience
    })

    on_exit(fn ->
      clear_auth_cache()
    end)

    :ok
  end

  test "rejects passive proxy token when verification material is not configured" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> unsigned_token())
      |> put_private(:phoenix_format, "json")
      |> GatewayAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "unauthorized"
  end

  test "passive proxy settings require JWKS or public key material" do
    changeset =
      Ash.Changeset.for_create(AuthSettings, :create, %{is_enabled: true, mode: :passive_proxy}, actor: system_actor())

    refute changeset.valid?

    assert Enum.any?(changeset.errors, fn error ->
             error.field == :jwt_jwks_url and
               String.contains?(Exception.message(error), "requires a JWKS URL or public key PEM")
           end)
  end

  test "valid gateway token JIT provisions a viewer and establishes a browser session", %{
    conn: conn
  } do
    put_auth_settings(%{
      is_enabled: true,
      mode: :passive_proxy,
      jwt_header_name: "authorization",
      jwt_public_key_pem: @rsa_public_pem,
      jwt_jwks_url: nil,
      jwt_issuer: @issuer,
      jwt_audience: @audience
    })

    email = "proxy-#{System.unique_integer([:positive])}@example.com"
    token = signed_token(%{"email" => email, "sub" => "gateway|#{email}"})

    conn =
      conn
      |> init_test_session(%{})
      |> put_private(:phoenix_format, "html")
      |> put_req_header("authorization", "Bearer " <> token)
      |> GatewayAuth.call([])

    refute conn.halted
    assert get_session(conn, "user_token")
    assert get_session(conn, :live_socket_id) == "users_sessions:#{conn.assigns.current_scope.user.id}"
    assert to_string(conn.assigns.current_scope.user.email) == email
    assert conn.assigns.current_scope.user.role == :viewer
    assert conn.assigns.current_scope.identity_claims["email"] == email

    socket = %Phoenix.LiveView.Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}}
    }

    assert {:cont, updated_socket} =
             UserAuth.on_mount(:require_authenticated, %{}, get_session(conn), socket)

    assert to_string(updated_socket.assigns.current_scope.user.email) == email
  end

  test "valid gateway token requires mapped email and subject claims", %{conn: conn} do
    put_auth_settings(%{
      is_enabled: true,
      mode: :passive_proxy,
      jwt_header_name: "authorization",
      jwt_public_key_pem: @rsa_public_pem,
      jwt_jwks_url: nil,
      jwt_issuer: @issuer,
      jwt_audience: @audience
    })

    conn =
      conn
      |> init_test_session(%{})
      |> put_private(:phoenix_format, "json")
      |> put_req_header("authorization", "Bearer " <> signed_token(%{"sub" => "gateway|missing-email"}))
      |> GatewayAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "unauthorized"
  end

  test "protected browser route redirects without gateway token or session", %{conn: conn} do
    conn = get(conn, ~p"/dashboard")

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "local admin sign-in page remains available in passive proxy mode", %{conn: conn} do
    conn = get(conn, ~p"/auth/local")

    assert html_response(conn, 200) =~ "Administrator Login"
  end

  defp maybe_start_config_cache do
    case Process.whereis(ConfigCache) do
      nil -> start_supervised!({ConfigCache, ttl_ms: 60_000})
      _pid -> :ok
    end
  end

  defp clear_auth_cache do
    if :ets.whereis(ConfigCache) != :undefined do
      :ets.delete(ConfigCache, :auth_settings)
      ConfigCache.clear_cache()
    end
  end

  defp put_auth_settings(settings) when is_map(settings) do
    expires_at = System.monotonic_time(:millisecond) + to_timeout(minute: 5)
    :ets.insert(ConfigCache, {:auth_settings, settings, expires_at})
  end

  defp unsigned_token do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)

    payload =
      Base.url_encode64(
        Jason.encode!(%{
          "sub" => "gateway|123",
          "email" => "proxy@example.com",
          "iss" => "https://gateway.example.com",
          "aud" => "serviceradar",
          "exp" => System.system_time(:second) + 3600
        }),
        padding: false
      )

    "#{header}.#{payload}.signature"
  end

  defp signed_token(extra_claims) do
    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => @audience,
          "name" => "Proxy User",
          "iat" => System.system_time(:second),
          "exp" => System.system_time(:second) + 3600
        },
        extra_claims
      )

    {_meta, token} =
      @rsa_private_key
      |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end
end

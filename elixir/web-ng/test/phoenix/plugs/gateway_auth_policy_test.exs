defmodule ServiceRadarWebNGWeb.Plugs.GatewayAuthPolicyTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Plugs.GatewayAuth

  @endpoint ServiceRadarWebNGWeb.Endpoint

  setup do
    maybe_start_config_cache()
    clear_auth_cache()

    put_auth_settings(%{
      is_enabled: true,
      mode: :passive_proxy,
      jwt_header_name: "authorization",
      jwt_public_key_pem: nil,
      jwt_jwks_url: nil,
      jwt_issuer: "https://gateway.example.com",
      jwt_audience: "serviceradar"
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
end

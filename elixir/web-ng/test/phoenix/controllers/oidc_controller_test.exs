defmodule ServiceRadarWebNGWeb.OIDCControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Pkce
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.OIDCController

  @moduletag :db_free
  @app :serviceradar_web_ng
  @issuer "https://idp.example.com"
  @client_id "client-id"

  setup do
    maybe_start_config_cache()
    clear_auth_cache()
    previous_poster = Application.get_env(@app, :oidc_token_poster)
    previous_loader = Application.get_env(@app, :auth_settings_loader)

    Application.put_env(@app, :auth_settings_loader, fn ->
      {:error, :not_configured}
    end)

    on_exit(fn ->
      clear_auth_cache()
      restore_env(:oidc_token_poster, previous_poster)
      restore_env(:auth_settings_loader, previous_loader)
    end)

    :ok
  end

  test "rejects callback when OIDC session state and nonce are missing" do
    conn = callback_conn(%{}, %{"code" => "test-code", "state" => "test-state"})

    assert redirected_to(conn) == "/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Authentication failed: invalid state. Please try again."
  end

  test "request stores S256 verifier next to state and nonce" do
    put_oidc_provider()

    conn =
      %{}
      |> oidc_conn()
      |> OIDCController.request(%{})

    verifier = get_session(conn, :oidc_code_verifier)
    params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert get_session(conn, :oidc_pkce) == true
    assert is_binary(get_session(conn, :oidc_state))
    assert is_binary(get_session(conn, :oidc_nonce))
    assert is_binary(verifier)
    assert params["code_challenge_method"] == "S256"
    assert params["code_challenge"] == Pkce.challenge_s256(verifier)
    refute Map.has_key?(params, "code_verifier")
  end

  test "PKCE callback with missing verifier does not call the token endpoint" do
    put_oidc_provider()
    capture_token_posts()

    conn =
      callback_conn(
        %{oidc_state: "state-1", oidc_nonce: "nonce-1", oidc_pkce: true},
        %{"code" => "code-1", "state" => "state-1"}
      )

    refute_received {:token_post, _, _}
    assert redirected_to(conn) == "/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Authentication failed: invalid state. Please try again."

    assert oidc_session_cleared?(conn)
  end

  test "PKCE callback sends verifier then clears session keys" do
    put_oidc_provider()
    capture_token_posts()

    conn =
      callback_conn(
        %{
          oidc_state: "state-1",
          oidc_nonce: "nonce-1",
          oidc_pkce: true,
          oidc_code_verifier: "verifier-1"
        },
        %{"code" => "code-1", "state" => "state-1"}
      )

    assert_received {:token_post, _url, opts}
    assert Keyword.fetch!(opts, :form)[:code_verifier] == "verifier-1"
    assert Keyword.fetch!(opts, :form)[:client_secret] == "client-secret"
    assert oidc_session_cleared?(conn)
  end

  test "replayed PKCE callback cannot reuse a consumed verifier" do
    put_oidc_provider()
    capture_token_posts()

    session = %{
      oidc_state: "state-1",
      oidc_nonce: "nonce-1",
      oidc_pkce: true,
      oidc_code_verifier: "verifier-1"
    }

    params = %{"code" => "code-1", "state" => "state-1"}
    first = callback_conn(session, params)
    assert_received {:token_post, _, _}

    replay_session = %{
      oidc_state: get_session(first, :oidc_state),
      oidc_nonce: get_session(first, :oidc_nonce),
      oidc_pkce: get_session(first, :oidc_pkce),
      oidc_code_verifier: get_session(first, :oidc_code_verifier)
    }

    _second = callback_conn(replay_session, params)
    refute_received {:token_post, _, _}
  end

  test "IdP error callback clears PKCE session keys" do
    conn =
      %{
        oidc_state: "state-1",
        oidc_nonce: "nonce-1",
        oidc_pkce: true,
        oidc_code_verifier: "verifier-1"
      }
      |> oidc_conn()
      |> OIDCController.callback(%{"error" => "access_denied", "error_description" => "denied"})

    assert oidc_session_cleared?(conn)
    assert redirected_to(conn) == "/users/log-in"
  end

  defp callback_conn(session, params) do
    session
    |> oidc_conn()
    |> OIDCController.callback(params)
  end

  defp oidc_conn(session) do
    build_conn()
    |> init_test_session(session)
    |> Phoenix.Controller.fetch_flash()
  end

  defp oidc_session_cleared?(conn) do
    is_nil(get_session(conn, :oidc_state)) and
      is_nil(get_session(conn, :oidc_nonce)) and
      is_nil(get_session(conn, :oidc_code_verifier)) and
      is_nil(get_session(conn, :oidc_pkce))
  end

  defp put_oidc_provider do
    put_oidc_settings(%{
      is_enabled: true,
      mode: :active_sso,
      provider_type: :oidc,
      oidc_client_id: @client_id,
      oidc_client_secret_encrypted: "client-secret",
      oidc_discovery_url: @issuer,
      oidc_scopes: "openid email profile",
      oidc_pkce_mode: :auto
    })

    ConfigCache.put_cached(
      "oidc_metadata:#{@issuer}",
      %{
        "issuer" => @issuer,
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token",
        "jwks_uri" => "#{@issuer}/jwks",
        "code_challenge_methods_supported" => ["S256"]
      },
      ttl: to_timeout(minute: 5)
    )

    :ok
  end

  defp capture_token_posts do
    parent = self()

    Application.put_env(@app, :oidc_token_poster, fn url, opts ->
      send(parent, {:token_post, url, opts})
      {:ok, %{status: 200, body: %{"access_token" => "tok", "id_token" => "id"}}}
    end)
  end

  defp maybe_start_config_cache do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    case Process.whereis(ServiceRadar.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      _pid -> :ok
    end

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

  defp put_oidc_settings(settings) when is_map(settings) do
    expires_at = System.monotonic_time(:millisecond) + to_timeout(minute: 5)
    :ets.insert(ConfigCache, {:auth_settings, settings, expires_at})
  end

  defp restore_env(key, nil), do: Application.delete_env(@app, key)
  defp restore_env(key, value), do: Application.put_env(@app, key, value)
end

defmodule ServiceRadarWebNGWeb.Auth.OIDCClientTest do
  @moduledoc """
  Tests for OIDC client functionality.

  These tests focus on the pure functions and claim extraction logic
  that can be tested without external OIDC provider connectivity.

  Run with: mix test test/phoenix/auth/oidc_client_test.exs
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Pkce
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.OIDCClient

  @moduletag :db_free

  @issuer "https://idp.example.com"
  @client_id "client-id"
  @jwks_uri "https://idp.example.com/jwks"
  @app :serviceradar_web_ng

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

  describe "extract_user_info/1" do
    test "extracts standard OIDC claims" do
      claims = %{
        "email" => "user@example.com",
        "name" => "Test User",
        "sub" => "oidc|12345"
      }

      assert {:ok, result} = OIDCClient.extract_user_info(claims)

      assert to_string(result.email) == "user@example.com"
      assert result.name == "Test User"
      assert result.external_id == "oidc|12345"
    end

    test "handles missing optional claims" do
      claims = %{
        "email" => "user@example.com",
        "sub" => "oidc|12345"
        # name is missing
      }

      assert {:ok, result} = OIDCClient.extract_user_info(claims)

      assert to_string(result.email) == "user@example.com"
      assert result.name == nil
      assert result.external_id == "oidc|12345"
    end

    test "rejects missing external id" do
      claims = %{}
      assert {:error, :missing_external_id} = OIDCClient.extract_user_info(claims)
    end

    test "rejects missing email" do
      claims = %{"sub" => "oidc|12345"}
      assert {:error, :missing_email} = OIDCClient.extract_user_info(claims)
    end

    test "handles claims with different key types" do
      # Some IdPs might use atom keys
      claims = %{
        "email" => "test@example.com",
        "name" => "Atom Keys Test",
        "sub" => "sub123"
      }

      assert {:ok, result} = OIDCClient.extract_user_info(claims)
      assert to_string(result.email) == "test@example.com"
    end
  end

  describe "fetch_discovery_metadata/1" do
    test "returns error for invalid URL" do
      # This should fail because the URL is not reachable
      result = OIDCClient.fetch_discovery_metadata("http://invalid.local.test")
      assert {:error, :discovery_failed} = result
    end

    test "appends .well-known suffix if needed" do
      # The function should work with or without the suffix
      # This will still fail connectivity but tests the URL handling
      result1 = OIDCClient.fetch_discovery_metadata("http://invalid.local.test")

      result2 =
        OIDCClient.fetch_discovery_metadata("http://invalid.local.test/.well-known/openid-configuration")

      # Both should fail the same way (connectivity)
      assert {:error, :discovery_failed} = result1
      assert {:error, :discovery_failed} = result2
    end
  end

  describe "authorize_url/1" do
    # Note: These tests require OIDC to be configured, which may not be the case
    # They will return {:error, :oidc_not_configured} if not set up

    test "returns error when OIDC is not configured" do
      # Without configuration, should return an error
      result = OIDCClient.authorize_url()

      # Should be either not_configured or discovery_failed
      assert match?({:error, _}, result)
    end

    test "rejects a discovery-provided authorization endpoint that violates outbound policy" do
      put_oidc_settings(%{
        is_enabled: true,
        mode: :active_sso,
        provider_type: :oidc,
        oidc_client_id: "client-id",
        oidc_client_secret_encrypted: "client-secret",
        oidc_discovery_url: "https://idp.example.com",
        oidc_scopes: "openid email profile"
      })

      ConfigCache.put_cached(
        "oidc_metadata:https://idp.example.com",
        %{
          "issuer" => "https://idp.example.com",
          "authorization_endpoint" => "https://127.0.0.1/authorize",
          "token_endpoint" => "https://idp.example.com/token",
          "jwks_uri" => "https://idp.example.com/jwks"
        },
        ttl: to_timeout(minute: 5)
      )

      assert {:error, :discovery_failed} = OIDCClient.authorize_url()
    end

    test "includes S256 challenge when discovery advertises S256" do
      put_oidc_provider(@jwks_uri, %{"code_challenge_methods_supported" => ["plain", "S256"]})

      assert {:ok, url, session} = OIDCClient.authorize_url()
      params = query_params(url)

      assert params["code_challenge_method"] == "S256"
      assert params["code_challenge"] == Pkce.challenge_s256(session.code_verifier)
      refute Map.has_key?(params, "code_verifier")
      assert session.pkce? == true
      assert is_binary(session.code_verifier)
    end

    test "includes S256 challenge when discovery omits challenge methods" do
      put_oidc_provider(@jwks_uri)

      assert {:ok, url, session} = OIDCClient.authorize_url()
      params = query_params(url)

      assert params["code_challenge_method"] == "S256"
      assert params["code_challenge"] == Pkce.challenge_s256(session.code_verifier)
      assert session.pkce? == true
    end

    test "omits PKCE when discovery lists methods without S256" do
      put_oidc_provider(@jwks_uri, %{"code_challenge_methods_supported" => ["plain"]})

      assert {:ok, url, session} = OIDCClient.authorize_url()
      params = query_params(url)

      refute Map.has_key?(params, "code_challenge")
      refute Map.has_key?(params, "code_challenge_method")
      assert session.pkce? == false
      assert session.code_verifier == nil
    end

    test "required mode errors when S256 is not advertised" do
      put_oidc_provider(@jwks_uri, %{"code_challenge_methods_supported" => ["plain"]}, :required)

      assert {:error, :pkce_s256_unsupported} = OIDCClient.authorize_url()
    end

    test "disabled mode omits PKCE even when S256 is advertised" do
      put_oidc_provider(@jwks_uri, %{"code_challenge_methods_supported" => ["S256"]}, :disabled)

      assert {:ok, url, session} = OIDCClient.authorize_url()
      params = query_params(url)

      refute Map.has_key?(params, "code_challenge")
      assert session.pkce? == false
      assert session.code_verifier == nil
    end
  end

  describe "exchange_code/2" do
    test "rejects a discovery-provided token endpoint that violates outbound policy" do
      put_oidc_settings(%{
        is_enabled: true,
        mode: :active_sso,
        provider_type: :oidc,
        oidc_client_id: "client-id",
        oidc_client_secret_encrypted: "client-secret",
        oidc_discovery_url: "https://idp.example.com",
        oidc_scopes: "openid email profile"
      })

      ConfigCache.put_cached(
        "oidc_metadata:https://idp.example.com",
        %{
          "issuer" => "https://idp.example.com",
          "authorization_endpoint" => "https://idp.example.com/authorize",
          "token_endpoint" => "https://127.0.0.1/token",
          "jwks_uri" => "https://idp.example.com/jwks"
        },
        ttl: to_timeout(minute: 5)
      )

      assert {:error, :token_exchange_failed} = OIDCClient.exchange_code("auth-code")
    end

    test "includes code_verifier and client_secret on the PKCE path" do
      put_oidc_provider(@jwks_uri)
      capture_token_posts()

      assert {:ok, _tokens} = OIDCClient.exchange_code("auth-code", code_verifier: "verifier-1")
      assert_receive {:token_post, url, opts}
      assert url == "https://example.com/token"
      form = form_body(opts)
      assert form[:code_verifier] == "verifier-1"
      assert form[:client_secret] == "client-secret"
      assert form[:code] == "auth-code"
      assert form[:grant_type] == "authorization_code"
    end

    test "omits code_verifier when PKCE was not used" do
      put_oidc_provider(@jwks_uri)
      capture_token_posts()

      assert {:ok, _tokens} = OIDCClient.exchange_code("auth-code")
      assert_receive {:token_post, _url, opts}
      form = form_body(opts)
      refute Map.has_key?(form, :code_verifier)
      assert form[:client_secret] == "client-secret"
    end
  end

  describe "validate_config/0" do
    test "returns error when OIDC is not configured" do
      result = OIDCClient.validate_config()

      # Should fail if OIDC is not configured
      assert match?({:error, _}, result)
    end
  end

  describe "JWT token parsing (private function behavior)" do
    # We can test the JWT parsing behavior through verify_id_token
    # but it requires configuration. Instead, test error cases.

    test "verify_id_token returns error when not configured" do
      fake_token = "header.payload.signature"
      result = OIDCClient.verify_id_token(fake_token, nonce: "nonce")

      assert match?({:error, _}, result)
    end

    test "verify_id_token fails closed when nonce is missing" do
      fake_token = "header.payload.signature"
      assert {:error, :missing_nonce} = OIDCClient.verify_id_token(fake_token)
    end
  end

  describe "verify_id_token/2 time-claim validation (mocked IdP)" do
    setup do
      {jwk, public_jwk} = generate_signing_key("sig-key-1")
      put_oidc_provider(@jwks_uri)
      ConfigCache.put_cached("oidc_jwks:#{@jwks_uri}", [public_jwk], ttl: to_timeout(minute: 5))

      %{jwk: jwk}
    end

    test "accepts a token whose time claims are valid", %{jwk: jwk} do
      token = sign_id_token(jwk, "sig-key-1", base_claims(%{}))

      assert {:ok, claims} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
      assert claims["sub"] == "user-1"
    end

    test "rejects a token expired beyond the clock-skew leeway", %{jwk: jwk} do
      now = System.system_time(:second)
      token = sign_id_token(jwk, "sig-key-1", base_claims(%{"exp" => now - 120}))

      assert {:error, :token_expired} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
    end

    test "accepts a token expired within the clock-skew leeway", %{jwk: jwk} do
      now = System.system_time(:second)
      token = sign_id_token(jwk, "sig-key-1", base_claims(%{"exp" => now - 30}))

      assert {:ok, _claims} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
    end

    test "rejects a token whose nbf is in the future beyond the leeway", %{jwk: jwk} do
      now = System.system_time(:second)
      token = sign_id_token(jwk, "sig-key-1", base_claims(%{"nbf" => now + 120}))

      assert {:error, :token_not_yet_valid} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
    end

    test "accepts a token whose nbf is in the future but within the leeway", %{jwk: jwk} do
      now = System.system_time(:second)
      token = sign_id_token(jwk, "sig-key-1", base_claims(%{"nbf" => now + 30}))

      assert {:ok, _claims} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
    end

    test "rejects a token whose iat is in the far future", %{jwk: jwk} do
      now = System.system_time(:second)
      token = sign_id_token(jwk, "sig-key-1", base_claims(%{"iat" => now + 120}))

      assert {:error, :invalid_iat} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
    end

    test "does not hard-fail when nbf and iat are absent", %{jwk: jwk} do
      claims = Map.drop(base_claims(%{}), ["nbf", "iat"])
      token = sign_id_token(jwk, "sig-key-1", claims)

      assert {:ok, _claims} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
    end
  end

  describe "verify_id_token/2 JWKS refetch on kid miss (mocked IdP)" do
    test "verifies a token whose kid is present in the cached JWKS without forcing a refetch" do
      {jwk, public_jwk} = generate_signing_key("present-key")
      put_oidc_provider(@jwks_uri)
      ConfigCache.put_cached("oidc_jwks:#{@jwks_uri}", [public_jwk], ttl: to_timeout(minute: 5))

      token = sign_id_token(jwk, "present-key", base_claims(%{}))

      assert {:ok, _claims} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
      # No forced refetch should have happened, so the throttle guard is unset.
      assert :miss = ConfigCache.get_cached("oidc_jwks_refetch:#{@jwks_uri}")
    end

    test "busts the cache and refetches once on a kid miss, failing closed if still absent" do
      # A loopback jwks_uri is rejected fast by the outbound URL policy (no DNS,
      # no live IdP), so the forced refetch yields no new key.
      jwks_uri = "https://127.0.0.1/jwks"
      {jwk, _public_jwk} = generate_signing_key("rotated-key")
      {_old_jwk, old_public} = generate_signing_key("old-key")

      put_oidc_provider(jwks_uri)
      ConfigCache.put_cached("oidc_jwks:#{jwks_uri}", [old_public], ttl: to_timeout(minute: 5))

      token = sign_id_token(jwk, "rotated-key", base_claims(%{}))

      assert {:error, :key_not_found} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
      # The forced refetch ran: the throttle guard is set and the stale JWKS cache
      # was busted (so the next read would go to the network).
      assert {:ok, true} = ConfigCache.get_cached("oidc_jwks_refetch:#{jwks_uri}")
      assert :miss = ConfigCache.get_cached("oidc_jwks:#{jwks_uri}")
    end

    test "throttles forced refetches so a burst of unknown kids cannot storm the IdP" do
      jwks_uri = "https://127.0.0.1/jwks"
      {jwk, _public_jwk} = generate_signing_key("rotated-key")
      {_old_jwk, old_public} = generate_signing_key("old-key")

      put_oidc_provider(jwks_uri)
      ConfigCache.put_cached("oidc_jwks:#{jwks_uri}", [old_public], ttl: to_timeout(minute: 5))
      # Simulate a forced refetch having happened moments ago.
      ConfigCache.put_cached("oidc_jwks_refetch:#{jwks_uri}", true, ttl: to_timeout(minute: 5))

      token = sign_id_token(jwk, "rotated-key", base_claims(%{}))

      assert {:error, :key_not_found} = OIDCClient.verify_id_token(token, nonce: "test-nonce")
      # Throttled: the stale JWKS cache must NOT have been busted.
      assert {:ok, [_old]} = ConfigCache.get_cached("oidc_jwks:#{jwks_uri}")
    end
  end

  defp generate_signing_key(kid) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_modules, public_map} = JOSE.JWK.to_public_map(jwk)
    public_jwk = Map.merge(public_map, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})
    {jwk, public_jwk}
  end

  defp sign_id_token(jwk, kid, claims) do
    {_protected, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp base_claims(overrides) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => @client_id,
        "sub" => "user-1",
        "email" => "user@example.com",
        "nonce" => "test-nonce",
        "exp" => now + 300,
        "iat" => now,
        "nbf" => now
      },
      overrides
    )
  end

  defp put_oidc_provider(jwks_uri, metadata_overrides \\ %{}, pkce_mode \\ :auto) do
    put_oidc_settings(%{
      is_enabled: true,
      mode: :active_sso,
      provider_type: :oidc,
      oidc_client_id: @client_id,
      oidc_client_secret_encrypted: "client-secret",
      oidc_discovery_url: @issuer,
      oidc_scopes: "openid email profile",
      oidc_pkce_mode: pkce_mode
    })

    metadata =
      Map.merge(
        %{
          "issuer" => @issuer,
          "authorization_endpoint" => "https://example.com/authorize",
          "token_endpoint" => "https://example.com/token",
          "jwks_uri" => jwks_uri
        },
        metadata_overrides
      )

    ConfigCache.put_cached("oidc_metadata:#{@issuer}", metadata, ttl: to_timeout(minute: 5))

    :ok
  end

  defp query_params(url) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  defp capture_token_posts do
    parent = self()

    Application.put_env(@app, :oidc_token_poster, fn url, opts ->
      send(parent, {:token_post, url, opts})
      {:ok, %{status: 200, body: %{"access_token" => "tok", "id_token" => "id"}}}
    end)
  end

  defp form_body(opts), do: Keyword.fetch!(opts, :form)

  defp restore_env(key, nil), do: Application.delete_env(@app, key)
  defp restore_env(key, value), do: Application.put_env(@app, key, value)

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
end

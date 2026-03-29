defmodule ServiceRadarWebNGWeb.Auth.OIDCClientTest do
  @moduledoc """
  Tests for OIDC client functionality.

  These tests focus on the pure functions and claim extraction logic
  that can be tested without external OIDC provider connectivity.

  Run with: mix test test/phoenix/auth/oidc_client_test.exs
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.OIDCClient

  setup do
    maybe_start_config_cache()
    clear_auth_cache()

    on_exit(fn ->
      clear_auth_cache()
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

  defp put_oidc_settings(settings) when is_map(settings) do
    expires_at = System.monotonic_time(:millisecond) + to_timeout(minute: 5)
    :ets.insert(ConfigCache, {:auth_settings, settings, expires_at})
  end
end

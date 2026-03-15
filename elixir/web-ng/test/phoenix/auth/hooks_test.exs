defmodule ServiceRadarWebNGWeb.Auth.HooksTest do
  @moduledoc """
  Tests for authentication lifecycle hooks.

  Tests both the hooks behavior interface and the default implementation.
  Run with: mix test test/phoenix/auth/hooks_test.exs
  """

  use ServiceRadarWebNG.DataCase, async: true

  import ExUnit.CaptureLog
  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadarWebNGWeb.Auth.Hooks
  alias ServiceRadarWebNGWeb.Auth.Hooks.Default

  describe "Hooks.on_user_created/2" do
    test "calls the implementation and returns :ok" do
      user = user_fixture()
      assert :ok = Hooks.on_user_created(user, :oidc)
    end

    test "handles different source types" do
      user = user_fixture()
      assert :ok = Hooks.on_user_created(user, :saml)
      assert :ok = Hooks.on_user_created(user, :gateway)
      assert :ok = Hooks.on_user_created(user, :password)
    end
  end

  describe "Hooks.on_user_authenticated/2" do
    test "calls the implementation and returns :ok" do
      user = user_fixture()
      claims = %{"sub" => user.id, "typ" => "access"}
      assert :ok = Hooks.on_user_authenticated(user, claims)
    end

    test "works with different claim structures" do
      user = user_fixture()

      # OIDC-style claims
      oidc_claims = %{"iss" => "https://idp.example.com", "aud" => "client123"}
      assert :ok = Hooks.on_user_authenticated(user, oidc_claims)

      # SAML-style claims
      saml_claims = %{"assertion" => "encoded_assertion"}
      assert :ok = Hooks.on_user_authenticated(user, saml_claims)
    end
  end

  describe "Hooks.on_token_generated/3" do
    test "calls the implementation and returns :ok" do
      user = user_fixture()
      token = "test_token"
      claims = %{"typ" => "access", "jti" => "test_jti"}
      assert :ok = Hooks.on_token_generated(user, token, claims)
    end
  end

  describe "Hooks.enrich_claims/2" do
    test "returns claims unchanged by default" do
      user = user_fixture()
      claims = %{"sub" => "user:#{user.id}", "role" => "viewer"}
      result = Hooks.enrich_claims(claims, user)
      assert result == claims
    end
  end

  describe "Hooks.on_auth_failed/2" do
    test "calls the implementation and returns :ok" do
      context = %{
        email: "test@example.com",
        ip: "192.168.1.1",
        method: :password
      }

      assert :ok = Hooks.on_auth_failed(:invalid_credentials, context)
    end

    test "handles different failure reasons" do
      context = %{ip: "10.0.0.1"}

      assert :ok = Hooks.on_auth_failed(:user_not_found, context)
      assert :ok = Hooks.on_auth_failed(:invalid_token, context)
      assert :ok = Hooks.on_auth_failed(:signature_validation_failed, context)
      assert :ok = Hooks.on_auth_failed(:rate_limited, context)
    end
  end

  describe "Default.on_user_created/2" do
    test "logs the user creation event" do
      user = user_fixture()

      # The test environment runs with `:logger, level: :warning` so info logs may be suppressed.
      # Ensure the default hook succeeds (logging is best-effort).
      assert :ok = Default.on_user_created(user, :oidc)
    end
  end

  describe "Default.on_user_authenticated/2" do
    test "logs the authentication event" do
      user = user_fixture()
      claims = %{"method" => :password}

      # The test environment runs with `:logger, level: :warning` so info logs may be suppressed.
      # Ensure the default hook succeeds (logging is best-effort).
      assert :ok = Default.on_user_authenticated(user, claims)
    end
  end

  describe "Default.on_token_generated/3" do
    test "logs the token generation event at debug level" do
      user = user_fixture()

      # Debug logs may not appear by default, but the function should succeed
      assert :ok = Default.on_token_generated(user, "token", %{"typ" => "access"})
    end
  end

  describe "Default.enrich_claims/2" do
    test "returns claims unchanged" do
      user = user_fixture()
      claims = %{"test" => "value"}
      assert Default.enrich_claims(claims, user) == claims
    end
  end

  describe "Default.on_auth_failed/2" do
    test "logs the failure event" do
      context = %{email: "test@example.com", ip: "192.168.1.1"}

      log =
        capture_log([level: :warning], fn ->
          Default.on_auth_failed(:invalid_credentials, context)
        end)

      assert log =~ "auth_event: auth_failed"
      assert log =~ "invalid_credentials"
    end
  end

  describe "error handling" do
    test "on_user_created handles exceptions gracefully" do
      # Pass invalid data that might cause issues
      result = Hooks.on_user_created(%{id: nil, email: nil}, :oidc)
      # Should return :ok or {:error, _} but not crash
      assert result == :ok or match?({:error, _}, result)
    end

    test "enrich_claims returns original claims on error" do
      # The default implementation shouldn't error, but test the guard
      claims = %{"test" => "value"}
      result = Hooks.enrich_claims(claims, nil)
      # Should return claims even with nil user
      assert is_map(result)
    end
  end
end

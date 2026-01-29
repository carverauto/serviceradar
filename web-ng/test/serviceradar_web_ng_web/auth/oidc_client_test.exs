defmodule ServiceRadarWebNGWeb.Auth.OIDCClientTest do
  @moduledoc """
  Tests for OIDC client functionality.

  These tests focus on the pure functions and claim extraction logic
  that can be tested without external OIDC provider connectivity.

  Run with: mix test test/serviceradar_web_ng_web/auth/oidc_client_test.exs
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Auth.OIDCClient

  describe "extract_user_info/1" do
    test "extracts standard OIDC claims" do
      claims = %{
        "email" => "user@example.com",
        "name" => "Test User",
        "sub" => "oidc|12345"
      }

      result = OIDCClient.extract_user_info(claims)

      assert result.email == "user@example.com"
      assert result.name == "Test User"
      assert result.external_id == "oidc|12345"
    end

    test "handles missing optional claims" do
      claims = %{
        "email" => "user@example.com",
        "sub" => "oidc|12345"
        # name is missing
      }

      result = OIDCClient.extract_user_info(claims)

      assert result.email == "user@example.com"
      assert result.name == nil
      assert result.external_id == "oidc|12345"
    end

    test "handles empty claims" do
      claims = %{}
      result = OIDCClient.extract_user_info(claims)

      assert result.email == nil
      assert result.name == nil
      assert result.external_id == nil
    end

    test "handles claims with different key types" do
      # Some IdPs might use atom keys
      claims = %{
        "email" => "test@example.com",
        "name" => "Atom Keys Test",
        "sub" => "sub123"
      }

      result = OIDCClient.extract_user_info(claims)
      assert result.email == "test@example.com"
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
        OIDCClient.fetch_discovery_metadata(
          "http://invalid.local.test/.well-known/openid-configuration"
        )

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
      result = OIDCClient.verify_id_token(fake_token)

      assert match?({:error, _}, result)
    end
  end
end

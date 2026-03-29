defmodule ServiceRadarWebNG.Auth.GuardianTest do
  @moduledoc """
  Tests for Guardian JWT token encoding/decoding.

  These tests require a database connection as they create test users.
  Run with: mix test test/phoenix/auth/guardian_test.exs
  """

  use ServiceRadarWebNG.DataCase, async: true

  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Auth.TokenRevocation

  describe "subject_for_token/2" do
    test "returns user:id format for user resource" do
      user = user_fixture()
      assert {:ok, "user:" <> id} = Guardian.subject_for_token(user, %{})
      assert id == user.id
    end

    test "returns error for invalid resource" do
      assert {:error, :invalid_resource} = Guardian.subject_for_token(%{}, %{})
      assert {:error, :invalid_resource} = Guardian.subject_for_token(nil, %{})
    end
  end

  describe "resource_from_claims/1" do
    test "loads user from valid claims" do
      user = user_fixture()
      claims = %{"sub" => "user:#{user.id}"}

      assert {:ok, loaded_user} = Guardian.resource_from_claims(claims)
      assert loaded_user.id == user.id
      assert loaded_user.email == user.email
    end

    test "returns error for non-existent user" do
      claims = %{"sub" => "user:#{Ecto.UUID.generate()}"}
      assert {:error, :user_not_found} = Guardian.resource_from_claims(claims)
    end

    test "returns error for invalid claims format" do
      assert {:error, :invalid_claims} = Guardian.resource_from_claims(%{})
      assert {:error, :invalid_claims} = Guardian.resource_from_claims(%{"sub" => "invalid"})
    end
  end

  describe "create_access_token/2" do
    test "creates a valid access token" do
      user = user_fixture()

      assert {:ok, token, claims} = Guardian.create_access_token(user)
      assert is_binary(token)
      assert claims["typ"] == "access"
      assert claims["sub"] == "user:#{user.id}"
      assert claims["role"] == to_string(user.role)
      assert is_binary(claims["jti"])
    end

    test "token can be verified" do
      user = user_fixture()

      {:ok, token, _claims} = Guardian.create_access_token(user)
      assert {:ok, verified_claims} = Guardian.decode_and_verify(token)
      assert verified_claims["typ"] == "access"
    end
  end

  describe "create_refresh_token/2" do
    test "creates a valid refresh token" do
      user = user_fixture()

      assert {:ok, token, claims} = Guardian.create_refresh_token(user)
      assert is_binary(token)
      assert claims["typ"] == "refresh"
      assert claims["sub"] == "user:#{user.id}"
    end

    test "token can be verified with refresh type" do
      user = user_fixture()

      {:ok, token, _claims} = Guardian.create_refresh_token(user)

      assert {:ok, verified_claims} =
               Guardian.decode_and_verify(token, %{}, token_type: "refresh")

      assert verified_claims["typ"] == "refresh"
    end
  end

  describe "create_api_token/2" do
    test "creates a valid API token with default scopes" do
      user = user_fixture()

      assert {:ok, token, claims} = Guardian.create_api_token(user)
      assert is_binary(token)
      assert claims["typ"] == "api"
      assert claims["scopes"] == ["read"]
    end

    test "creates API token with custom scopes" do
      user = user_fixture()

      assert {:ok, _token, claims} = Guardian.create_api_token(user, scopes: [:read, :write])
      assert claims["scopes"] == ["read", "write"]
    end
  end

  describe "verify_token/2" do
    test "verifies access token and returns user" do
      user = user_fixture()

      {:ok, token, _claims} = Guardian.create_access_token(user)
      assert {:ok, verified_user, claims} = Guardian.verify_token(token, token_type: "access")
      assert verified_user.id == user.id
      assert claims["typ"] == "access"
    end

    test "rejects token with wrong type" do
      user = user_fixture()

      {:ok, token, _claims} = Guardian.create_access_token(user)
      assert {:error, :invalid_token_type} = Guardian.verify_token(token, token_type: "refresh")
    end

    test "rejects refresh tokens when no explicit token type is requested" do
      user = user_fixture()

      {:ok, token, _claims} = Guardian.create_refresh_token(user)
      assert {:error, :invalid_token_type} = Guardian.verify_token(token)
    end

    test "rejects invalid token" do
      assert {:error, _reason} = Guardian.verify_token("invalid_token")
    end

    test "rejects tampered token" do
      user = user_fixture()

      {:ok, token, _claims} = Guardian.create_access_token(user)
      # Tamper with the token
      tampered = token <> "x"
      assert {:error, _reason} = Guardian.verify_token(tampered)
    end

    test "accepts a new token issued after user-wide revocation" do
      user = user_fixture()

      assert :ok = TokenRevocation.revoke_all_for_user(user.id, reason: :password_changed)
      Process.sleep(10)

      {:ok, token, _claims} = Guardian.create_access_token(user)

      assert {:ok, verified_user, claims} = Guardian.verify_token(token, token_type: "access")
      assert verified_user.id == user.id
      assert claims["typ"] == "access"
    end

    test "rejects a token issued before user-wide revocation" do
      user = user_fixture()

      {:ok, token, _claims} = Guardian.create_access_token(user)
      assert :ok = TokenRevocation.revoke_all_for_user(user.id, reason: :password_changed)

      assert {:error, :user_revoked} = Guardian.verify_token(token, token_type: "access")
    end
  end

  describe "exchange_refresh_token/1" do
    test "exchanges refresh token for rotated credentials" do
      user = user_fixture()

      {:ok, refresh_token, _claims} = Guardian.create_refresh_token(user)

      assert {:ok, returned_user, credentials} =
               Guardian.exchange_refresh_token(refresh_token)

      assert returned_user.id == user.id
      assert is_binary(credentials.access_token)
      assert credentials.access_claims["typ"] == "access"
      assert is_binary(credentials.refresh_token)
      assert credentials.refresh_claims["typ"] == "refresh"
    end

    test "rejects a reused refresh token after successful exchange" do
      user = user_fixture()
      {:ok, refresh_token, _claims} = Guardian.create_refresh_token(user)

      assert {:ok, _returned_user, _credentials} = Guardian.exchange_refresh_token(refresh_token)
      assert {:error, :revoked} = Guardian.exchange_refresh_token(refresh_token)
    end

    test "rejects access token for exchange" do
      user = user_fixture()

      {:ok, access_token, _claims} = Guardian.create_access_token(user)
      assert {:error, :invalid_token_type} = Guardian.exchange_refresh_token(access_token)
    end
  end

  describe "get_scopes/1 and has_scope?/2" do
    test "extracts scopes from claims" do
      user = user_fixture()

      {:ok, _token, claims} = Guardian.create_api_token(user, scopes: [:read, :write])
      assert Guardian.get_scopes(claims) == [:read, :write]
    end

    test "returns empty list for claims without scopes" do
      claims = %{}
      assert Guardian.get_scopes(claims) == []
    end

    test "has_scope? returns true for existing scope" do
      user = user_fixture()

      {:ok, _token, claims} = Guardian.create_api_token(user, scopes: [:read, :write])
      assert Guardian.has_scope?(claims, :read)
      assert Guardian.has_scope?(claims, :write)
      refute Guardian.has_scope?(claims, :delete)
    end

    test "has_scope? works with string scopes" do
      claims = %{"scopes" => ["read", "write"]}
      assert Guardian.has_scope?(claims, "read")
      refute Guardian.has_scope?(claims, "delete")
    end
  end

  describe "build_claims/3" do
    test "adds role to claims" do
      user = user_fixture()

      {:ok, _token, claims} = Guardian.create_access_token(user)
      assert claims["role"] == to_string(user.role)
    end

    test "adds custom scopes when provided" do
      user = user_fixture()

      {:ok, _token, claims} = Guardian.create_api_token(user, scopes: [:admin])
      assert "admin" in claims["scopes"]
    end
  end
end

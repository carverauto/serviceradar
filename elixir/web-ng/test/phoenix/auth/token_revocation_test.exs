defmodule ServiceRadarWebNGWeb.Auth.TokenRevocationTest do
  @moduledoc """
  Tests for token revocation service.

  These tests don't require database access but need the application started
  (for ETS tables). The test_helper.exs currently requires database connection,
  so these tests run as part of the standard test suite.

  Run with: mix test test/phoenix/auth/token_revocation_test.exs
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Auth.TokenRevocation

  # TokenRevocation uses ETS which is started by the application
  # These tests verify the module's public API

  setup do
    # Generate unique JTI for each test to avoid collisions
    jti = "test_jti_#{System.unique_integer([:positive])}"
    user_id = Ecto.UUID.generate()
    {:ok, jti: jti, user_id: user_id}
  end

  describe "revoke_token/2" do
    test "revokes a token by JTI", %{jti: jti, user_id: user_id} do
      assert :ok = TokenRevocation.revoke_token(jti, user_id: user_id, reason: :test)
    end

    test "accepts different reasons", %{jti: jti} do
      assert :ok = TokenRevocation.revoke_token(jti, reason: :user_logout)
      assert :ok = TokenRevocation.revoke_token(jti <> "_2", reason: :password_changed)
      assert :ok = TokenRevocation.revoke_token(jti <> "_3", reason: :admin_action)
    end
  end

  describe "check_revoked/1" do
    test "returns :ok for non-revoked token", %{jti: jti} do
      assert :ok = TokenRevocation.check_revoked(jti)
    end

    test "returns {:error, :revoked} for revoked token", %{jti: jti} do
      TokenRevocation.revoke_token(jti)
      assert {:error, :revoked} = TokenRevocation.check_revoked(jti)
    end

    test "returns :ok for nil JTI" do
      assert :ok = TokenRevocation.check_revoked(nil)
    end
  end

  describe "revoke_all_for_user/2" do
    test "revokes all tokens for a user", %{user_id: user_id} do
      assert :ok = TokenRevocation.revoke_all_for_user(user_id, reason: :password_changed)
    end

    test "creates a marker for user-wide revocation", %{user_id: user_id} do
      TokenRevocation.revoke_all_for_user(user_id)

      # The marker JTI should be revoked
      marker_jti = "user:#{user_id}:all"
      assert {:error, :revoked} = TokenRevocation.check_revoked(marker_jti)
    end
  end

  describe "check_user_tokens_revoked/2" do
    test "returns :ok when user has no revocation", %{user_id: user_id} do
      # Token issued now
      issued_at = DateTime.utc_now()
      assert :ok = TokenRevocation.check_user_tokens_revoked(user_id, issued_at)
    end

    test "returns {:error, :revoked} for tokens issued before revocation", %{user_id: user_id} do
      # Token issued 1 hour ago
      issued_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      # Revoke all user tokens now
      TokenRevocation.revoke_all_for_user(user_id)

      # Token issued before revocation should be rejected
      assert {:error, :revoked} = TokenRevocation.check_user_tokens_revoked(user_id, issued_at)
    end

    test "returns :ok for tokens issued after revocation", %{user_id: user_id} do
      # Revoke all user tokens
      TokenRevocation.revoke_all_for_user(user_id)

      # Small delay to ensure token is issued after revocation
      Process.sleep(10)

      # Token issued after revocation should be accepted
      issued_at = DateTime.utc_now()
      assert :ok = TokenRevocation.check_user_tokens_revoked(user_id, issued_at)
    end

    test "accepts unix timestamp for issued_at", %{user_id: user_id} do
      # Token issued 1 hour ago as unix timestamp
      issued_at = System.system_time(:second) - 3600

      # Revoke all user tokens now
      TokenRevocation.revoke_all_for_user(user_id)

      # Token issued before revocation should be rejected
      assert {:error, :revoked} = TokenRevocation.check_user_tokens_revoked(user_id, issued_at)
    end
  end

  describe "get_revocation_info/1" do
    test "returns :not_found for non-revoked token", %{jti: jti} do
      assert :not_found = TokenRevocation.get_revocation_info(jti)
    end

    test "returns revocation info for revoked token", %{jti: jti, user_id: user_id} do
      TokenRevocation.revoke_token(jti, user_id: user_id, reason: :test_reason)

      assert {:ok, info} = TokenRevocation.get_revocation_info(jti)
      assert info.jti == jti
      assert info.user_id == user_id
      assert info.reason == :test_reason
      assert %DateTime{} = info.revoked_at
    end
  end

  describe "clear_revocation/1" do
    test "removes revocation for a token", %{jti: jti} do
      TokenRevocation.revoke_token(jti)
      assert {:error, :revoked} = TokenRevocation.check_revoked(jti)

      TokenRevocation.clear_revocation(jti)
      assert :ok = TokenRevocation.check_revoked(jti)
    end
  end
end

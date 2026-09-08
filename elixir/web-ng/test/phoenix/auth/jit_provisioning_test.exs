defmodule ServiceRadarWebNGWeb.Auth.JITProvisioningTest do
  @moduledoc """
  Tests for Just-In-Time (JIT) user provisioning.

  JIT provisioning creates users automatically on first SSO login.
  This is used by OIDC, SAML, and gateway authentication.

  Run with: mix test test/phoenix/auth/jit_provisioning_test.exs
  """

  use ServiceRadarWebNG.DataCase, async: true

  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User

  describe "User.provision_sso_user/2" do
    setup do
      actor = SystemActor.system(:test)
      {:ok, actor: actor}
    end

    test "creates a new user with OIDC provider", %{actor: actor} do
      params = %{
        email: "oidc_user@example.com",
        display_name: "OIDC User",
        external_id: "oidc|12345",
        provider: :oidc
      }

      assert {:ok, user} = User.provision_sso_user(params, actor: actor)
      assert to_string(user.email) == "oidc_user@example.com"
      assert user.display_name == "OIDC User"
      assert user.external_id == "oidc|12345"
      assert user.role == :viewer
      # SSO users should be auto-confirmed
      assert user.confirmed_at
    end

    test "creates a new user with SAML provider", %{actor: actor} do
      params = %{
        email: "saml_user@example.com",
        display_name: "SAML User",
        external_id: "saml:nameid:67890",
        provider: :saml
      }

      assert {:ok, user} = User.provision_sso_user(params, actor: actor)
      assert to_string(user.email) == "saml_user@example.com"
      assert user.external_id == "saml:nameid:67890"
    end

    test "creates a new user with gateway provider", %{actor: actor} do
      params = %{
        email: "gateway_user@example.com",
        display_name: "Gateway User",
        external_id: "gateway:sub:abcdef",
        provider: :gateway
      }

      assert {:ok, user} = User.provision_sso_user(params, actor: actor)
      assert to_string(user.email) == "gateway_user@example.com"
    end

    test "fails with invalid provider", %{actor: actor} do
      params = %{
        email: "invalid@example.com",
        display_name: "Test",
        external_id: "test:123",
        provider: :invalid_provider
      }

      assert {:error, _} = User.provision_sso_user(params, actor: actor)
    end

    test "fails without external_id", %{actor: actor} do
      params = %{
        email: "no_external_id@example.com",
        display_name: "Test",
        provider: :oidc
      }

      assert {:error, _} = User.provision_sso_user(params, actor: actor)
    end

    test "fails without provider", %{actor: actor} do
      params = %{
        email: "no_provider@example.com",
        display_name: "Test",
        external_id: "test:123"
      }

      assert {:error, _} = User.provision_sso_user(params, actor: actor)
    end

    test "fails with duplicate email", %{actor: actor} do
      # Create an existing user
      existing = user_fixture()

      params = %{
        email: to_string(existing.email),
        display_name: "Duplicate",
        external_id: "new:external:id",
        provider: :oidc
      }

      assert {:error, _} = User.provision_sso_user(params, actor: actor)
    end
  end

  describe "User.get_by_email/2" do
    test "finds user by email" do
      user = user_fixture()
      actor = SystemActor.system(:test)

      assert {:ok, found} = User.get_by_email(user.email, actor: actor)
      assert found.id == user.id
    end

    test "returns error for non-existent email" do
      actor = SystemActor.system(:test)
      assert {:error, _} = User.get_by_email("nonexistent@example.com", actor: actor)
    end

    test "email comparison is case insensitive" do
      user = user_fixture(%{email: "CaseSensitive@Example.COM"})
      actor = SystemActor.system(:test)

      # Should find with different case
      assert {:ok, found} = User.get_by_email("casesensitive@example.com", actor: actor)
      assert found.id == user.id
    end
  end

  describe "find user by external_id" do
    setup do
      actor = SystemActor.system(:test)

      # Create a user with external_id
      {:ok, user} =
        User.provision_sso_user(
          %{
            email: "external_id_test@example.com",
            display_name: "External ID User",
            external_id: "unique:external:id:123",
            provider: :oidc
          },
          actor: actor
        )

      {:ok, user: user, actor: actor}
    end

    test "finds user by external_id", %{user: user, actor: actor} do
      require Ash.Query

      query =
        User
        |> Ash.Query.filter(external_id == "unique:external:id:123")
        |> Ash.Query.limit(1)

      assert {:ok, [found]} = Ash.read(query, actor: actor)
      assert found.id == user.id
    end

    test "returns empty when external_id not found", %{actor: actor} do
      require Ash.Query

      query =
        User
        |> Ash.Query.filter(external_id == "nonexistent:external:id")
        |> Ash.Query.limit(1)

      assert {:ok, []} = Ash.read(query, actor: actor)
    end
  end

  describe "User.update/3 for linking existing users" do
    test "can update display_name" do
      user = user_fixture()
      actor = SystemActor.system(:test)

      assert {:ok, updated} = User.update(user, %{display_name: "New Name"}, actor: actor)
      assert updated.display_name == "New Name"
    end

    test "preserves other fields when updating" do
      user = user_fixture()
      actor = SystemActor.system(:test)
      original_email = user.email

      assert {:ok, updated} = User.update(user, %{display_name: "Updated"}, actor: actor)
      assert updated.email == original_email
    end
  end

  describe "User.record_authentication/2" do
    test "updates authenticated_at timestamp" do
      user = user_fixture()
      actor = SystemActor.system(:test)

      # Initial state - might be nil
      original_timestamp = user.authenticated_at

      # Record authentication
      assert {:ok, updated} = User.record_authentication(user, actor: actor)

      # Should have updated timestamp
      if original_timestamp do
        assert DateTime.compare(updated.authenticated_at, original_timestamp) in [:gt, :eq]
      else
        assert updated.authenticated_at
      end
    end

    test "can be called multiple times" do
      user = user_fixture()
      actor = SystemActor.system(:test)

      assert {:ok, first} = User.record_authentication(user, actor: actor)
      Process.sleep(10)
      assert {:ok, second} = User.record_authentication(first, actor: actor)

      # Second timestamp should be same or later
      assert DateTime.compare(second.authenticated_at, first.authenticated_at) in [
               :gt,
               :eq
             ]
    end
  end

  describe "SSO user confirmation" do
    setup do
      actor = SystemActor.system(:test)
      {:ok, actor: actor}
    end

    test "SSO provisioned users are automatically confirmed", %{actor: actor} do
      params = %{
        email: "auto_confirmed@example.com",
        display_name: "Auto Confirmed",
        external_id: "sso:auto:confirm",
        provider: :oidc
      }

      assert {:ok, user} = User.provision_sso_user(params, actor: actor)
      assert user.confirmed_at
    end

    test "confirmed_at is set to current time", %{actor: actor} do
      # confirmed_at is persisted through Postgres, which may truncate precision (seconds).
      before = DateTime.truncate(DateTime.utc_now(), :second)

      params = %{
        email: "timestamp_test@example.com",
        display_name: "Timestamp Test",
        external_id: "sso:timestamp:test",
        provider: :saml
      }

      {:ok, user} = User.provision_sso_user(params, actor: actor)
      after_time = DateTime.truncate(DateTime.utc_now(), :second)

      assert DateTime.compare(user.confirmed_at, before) in [:gt, :eq]
      assert DateTime.compare(user.confirmed_at, after_time) in [:lt, :eq]
    end
  end
end

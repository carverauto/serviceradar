defmodule ServiceRadarWebNGWeb.Auth.SSOProvisioningTest do
  use ServiceRadarWebNG.DataCase, async: true

  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning

  describe "record_successful_authentication/3" do
    test "persists the trusted OIDC and SAML authentication method" do
      actor = SystemActor.system(:test)

      for provider <- [:oidc, :saml] do
        user = user_fixture(%{email: "#{provider}-login@example.com"})

        assert {:ok, recorded} =
                 SSOProvisioning.record_successful_authentication(user, provider, actor)

        assert recorded.authenticated_at
        assert recorded.last_login_at
        assert recorded.last_auth_method == provider

        assert {:ok, persisted} = Ash.get(User, user.id, actor: actor)
        assert persisted.last_auth_method == provider
      end
    end

    test "does not make local password authentication SSO-eligible" do
      actor = SystemActor.system(:test)
      user = user_fixture(%{email: "local-login@example.com"})

      assert {:error, :unsupported_sso_provider} =
               SSOProvisioning.record_successful_authentication(user, :password, actor)

      assert {:ok, persisted} = Ash.get(User, user.id, actor: actor)
      assert is_nil(persisted.last_auth_method)
    end
  end

  describe "find_or_create_user/4" do
    test "rejects implicit linking to an existing local account by email" do
      user = user_fixture(%{email: "existing@example.com"})
      actor = SystemActor.system(:test)

      assert {:error, :unsafe_account_linking} =
               SSOProvisioning.find_or_create_user(
                 %{email: to_string(user.email), name: "Existing User", external_id: "oidc|123"},
                 %{"sub" => "oidc|123", "email" => to_string(user.email)},
                 :oidc,
                 actor
               )
    end

    test "finds an existing SSO user by external_id" do
      actor = SystemActor.system(:test)

      {:ok, existing} =
        User.provision_sso_user(
          %{
            email: "sso-existing@example.com",
            display_name: "Original Name",
            external_id: "saml|existing",
            provider: :saml
          },
          actor: actor
        )

      assert {:ok, found} =
               SSOProvisioning.find_or_create_user(
                 %{email: "different@example.com", name: "Updated Name", external_id: "saml|existing"},
                 %{"sub" => "saml|existing"},
                 :saml,
                 actor
               )

      assert found.id == existing.id
      assert found.external_id == "saml|existing"
    end

    test "denies JIT provisioning by default when no local account exists" do
      actor = SystemActor.system(:test)

      # No AuthSettings row exists, so sso_auto_provision is treated as the
      # default (false): an unknown SSO identity must be denied, not created.
      assert {:error, :no_local_account} =
               SSOProvisioning.find_or_create_user(
                 %{email: "newcomer@example.com", name: "Newcomer", external_id: "oidc|new-1"},
                 %{"sub" => "oidc|new-1", "email" => "newcomer@example.com"},
                 :oidc,
                 actor
               )

      assert {:error, _} = User.get_by_email("newcomer@example.com", actor: actor)
    end

    test "denies JIT provisioning when sso_auto_provision is explicitly off" do
      actor = SystemActor.system(:test)
      {:ok, _settings} = AuthSettings.create(%{sso_auto_provision: false}, actor: actor)

      assert {:error, :no_local_account} =
               SSOProvisioning.find_or_create_user(
                 %{email: "newcomer2@example.com", name: "Newcomer", external_id: "saml|new-2"},
                 %{"sub" => "saml|new-2", "email" => "newcomer2@example.com"},
                 :saml,
                 actor
               )

      assert {:error, _} = User.get_by_email("newcomer2@example.com", actor: actor)
    end

    test "creates a new account when sso_auto_provision is enabled" do
      actor = SystemActor.system(:test)
      {:ok, _settings} = AuthSettings.create(%{sso_auto_provision: true}, actor: actor)

      assert {:ok, user} =
               SSOProvisioning.find_or_create_user(
                 %{email: "provisioned@example.com", name: "Provisioned", external_id: "oidc|new-3"},
                 %{"sub" => "oidc|new-3", "email" => "provisioned@example.com"},
                 :oidc,
                 actor
               )

      assert to_string(user.email) == "provisioned@example.com"
      assert user.external_id == "oidc|new-3"
      assert user.role == :viewer
    end
  end
end

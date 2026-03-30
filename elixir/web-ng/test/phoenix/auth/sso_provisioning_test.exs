defmodule ServiceRadarWebNGWeb.Auth.SSOProvisioningTest do
  use ServiceRadarWebNG.DataCase, async: true

  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning

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
  end
end

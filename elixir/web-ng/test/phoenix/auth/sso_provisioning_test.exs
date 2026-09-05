defmodule ServiceRadarWebNGWeb.Auth.SSOProvisioningTest do
  use ServiceRadarWebNG.DataCase, async: true

  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.RoleProfile
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
                 %{
                   email: "different@example.com",
                   name: "Updated Name",
                   external_id: "saml|existing"
                 },
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
                 %{
                   email: "provisioned@example.com",
                   name: "Provisioned",
                   external_id: "oidc|new-3"
                 },
                 %{"sub" => "oidc|new-3", "email" => "provisioned@example.com"},
                 :oidc,
                 actor
               )

      assert to_string(user.email) == "provisioned@example.com"
      assert user.external_id == "oidc|new-3"
      assert user.role == :viewer
    end
  end

  describe "group mappings grant and revoke access" do
    setup do
      %{actor: SystemActor.system(:idp_mapping_test)}
    end

    test "applies a role profile a group mapping grants", %{actor: actor} do
      profile = role_profile!(actor)
      settings!([mapping("plugin-authors", %{"role_profile_id" => profile.id})], actor)

      {:ok, user} = sign_in("author@example.com", "oidc|author", ["plugin-authors"], actor)

      assert {:ok, persisted} = Ash.get(User, user.id, actor: actor)
      assert persisted.role_profile_id == profile.id
      assert persisted.role_profile_source == :idp
    end

    test "revokes the profile once the user leaves the group", %{actor: actor} do
      # The behaviour the whole change is for: access granted by group membership
      # has to go away when the membership does, without an operator noticing.
      profile = role_profile!(actor)
      settings!([mapping("plugin-authors", %{"role_profile_id" => profile.id})], actor)

      {:ok, user} = sign_in("leaver@example.com", "oidc|leaver", ["plugin-authors"], actor)
      assert {:ok, granted} = Ash.get(User, user.id, actor: actor)
      assert granted.role_profile_id == profile.id

      {:ok, _user} = sign_in("leaver@example.com", "oidc|leaver", [], actor)

      assert {:ok, revoked} = Ash.get(User, user.id, actor: actor)
      assert is_nil(revoked.role_profile_id)
      assert revoked.role_profile_source == :manual
    end

    test "leaves a profile an operator assigned by hand alone", %{actor: actor} do
      # Clearing every unmatched profile would silently strip access from users
      # who have no mapping at all -- which is most of them.
      profile = role_profile!(actor)
      settings!([mapping("plugin-authors", %{"role_profile_id" => profile.id})], actor)

      {:ok, user} = sign_in("manual@example.com", "oidc|manual", [], actor)

      {:ok, _assigned} =
        User.update_role_profile(
          user,
          %{role_profile_id: profile.id, role_profile_source: :manual},
          actor: actor
        )

      {:ok, _user} = sign_in("manual@example.com", "oidc|manual", [], actor)

      assert {:ok, persisted} = Ash.get(User, user.id, actor: actor)
      assert persisted.role_profile_id == profile.id
      assert persisted.role_profile_source == :manual
    end

    test "the highest role among several matching groups wins", %{actor: actor} do
      settings!(
        [
          mapping("helpdesk-team", %{"role" => "helpdesk"}),
          mapping("ops", %{"role" => "operator"})
        ],
        actor
      )

      {:ok, user} = sign_in("both@example.com", "oidc|both", ["helpdesk-team", "ops"], actor)

      assert {:ok, persisted} = Ash.get(User, user.id, actor: actor)
      assert persisted.role == :operator
    end

    test "upgrades an existing viewer's role when a group mapping grants a higher one", %{
      actor: actor
    } do
      settings!([mapping("helpdesk-team", %{"role" => "helpdesk"})], actor)

      {:ok, existing} =
        User.provision_sso_user(
          %{
            email: "promoted@example.com",
            display_name: "Mapped User",
            external_id: "oidc|promoted",
            role: :viewer,
            provider: :oidc
          },
          actor: actor
        )

      assert existing.role == :viewer

      {:ok, user} = sign_in("promoted@example.com", "oidc|promoted", ["helpdesk-team"], actor)

      assert user.id == existing.id
      assert {:ok, persisted} = Ash.get(User, user.id, actor: actor)
      assert persisted.role == :helpdesk
    end
  end

  defp mapping(value, grant) do
    Map.merge(%{"source" => "groups", "value" => value, "claim" => "groups"}, grant)
  end

  defp settings!(mappings, actor) do
    {:ok, settings} =
      AuthorizationSettings.create_settings(
        %{default_role: :viewer, role_mappings: mappings},
        actor: actor
      )

    settings
  end

  defp role_profile!(actor) do
    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "plugin-authors-#{System.unique_integer([:positive])}",
          permissions: ["settings.auth.manage"]
        },
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    profile
  end

  defp sign_in(email, external_id, groups, actor) do
    # Mapping tests are about what happens on an existing SSO user, not JIT.
    # Pre-provision so a missing AuthSettings row (sso_auto_provision off)
    # cannot hide a broken apply_role_mapping/3 behind {:error, :no_local_account}.
    case SSOProvisioning.find_user_by_external_id(external_id, actor) do
      {:ok, _user} ->
        :ok

      {:error, :not_found} ->
        {:ok, _user} =
          User.provision_sso_user(
            %{
              email: email,
              display_name: "Mapped User",
              external_id: external_id,
              role: :viewer,
              provider: :oidc
            },
            actor: actor
          )
    end

    SSOProvisioning.find_or_create_user(
      %{email: email, name: "Mapped User", external_id: external_id},
      %{"sub" => external_id, "email" => email, "groups" => groups},
      :oidc,
      actor
    )
  end
end

defmodule ServiceRadarWebNGWeb.Auth.SSOProvisioningIdpBoundaryDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning

  require Ash.Query

  @moduletag :integration
  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  for initially_present <- [true, false] do
    @tag initially_present: initially_present
    test "one invalid group mapping does not block sign-in or another membership (settings present: #{initially_present})",
         %{initially_present: initially_present} do
      marker = "sso-idp-boundary-#{System.unique_integer([:positive])}"
      actor = SystemActor.system(:sso_idp_boundary_test)
      email = "#{marker}@example.test"

      original_settings = settings_snapshot()

      on_exit(fn ->
        try do
          cleanup!(marker, email)
        after
          restore_settings!(original_settings, marker)
        end
      end)

      # Exercise both initial states in the disposable fixture database. Keep any
      # previous singleton only in memory and register restoration before writes.
      Repo.delete_all(from(s in "authorization_settings", prefix: "platform", where: s.key == "default"))

      if initially_present do
        {:ok, _settings} =
          AuthorizationSettings.create_settings(
            %{
              default_role: :operator,
              role_mappings: [mapping("#{marker}-initial", %{"role" => "operator"})],
              cli_session_ttl_days: 17
            },
            actor: actor
          )
      end

      prior_settings = settings_snapshot()

      valid_group_name = "#{marker}-valid"
      stale_group_name = "#{marker}-stale"
      missing_group_id = Ecto.UUID.generate()

      {:ok, _settings} =
        put_settings(
          %{
            default_role: :viewer,
            role_mappings: [
              mapping(valid_group_name, %{"role" => "operator"}),
              mapping(stale_group_name, %{"user_group_id" => missing_group_id})
            ]
          },
          actor
        )

      {:ok, _user} =
        User.provision_sso_user(
          %{
            email: email,
            display_name: "Synthetic Mapped User",
            external_id: "oidc|#{marker}",
            role: :viewer,
            provider: :oidc
          },
          actor: actor
        )

      assert {:ok, user} =
               SSOProvisioning.find_or_create_user(
                 %{
                   email: email,
                   name: "Synthetic Mapped User",
                   external_id: "oidc|#{marker}"
                 },
                 %{
                   "sub" => "oidc|#{marker}",
                   "email" => email,
                   "groups" => [stale_group_name, valid_group_name]
                 },
                 :oidc,
                 actor
               )

      assert {:ok, %UserGroup{id: valid_group_id}} =
               UserGroup
               |> Ash.Query.filter(name == ^valid_group_name)
               |> Ash.read_one(actor: actor)

      assert [%UserGroupMembership{group_id: ^valid_group_id, source: :idp}] =
               UserGroupMembership.list_by_user!(user.id, actor: actor)

      restore_settings!(prior_settings, marker)
      assert settings_snapshot() == prior_settings
    end
  end

  defp put_settings(attrs, actor) do
    case Ash.get(AuthorizationSettings, "default", actor: actor, not_found_error?: false) do
      {:ok, nil} -> AuthorizationSettings.create_settings(attrs, actor: actor)
      {:ok, settings} -> AuthorizationSettings.update_settings(settings, attrs, actor: actor)
    end
  end

  defp settings_snapshot do
    fields = Enum.map(Ash.Resource.Info.attributes(AuthorizationSettings), & &1.name)

    Repo.one(
      from(s in "authorization_settings",
        prefix: "platform",
        where: s.key == "default",
        select: map(s, ^fields)
      )
    )
  end

  defp restore_settings!(nil, marker) do
    Repo.delete_all(
      from(s in "authorization_settings",
        prefix: "platform",
        where:
          s.key == "default" and
            fragment("?::text LIKE ?", s.role_mappings, ^"%#{marker}%")
      )
    )

    assert settings_snapshot() == nil
  end

  defp restore_settings!(snapshot, _marker) do
    Repo.delete_all(from(s in "authorization_settings", prefix: "platform", where: s.key == "default"))

    Repo.insert_all("authorization_settings", [snapshot], prefix: "platform")
    assert settings_snapshot() == snapshot
  end

  defp mapping(value, grant) do
    Map.merge(%{"source" => "groups", "value" => value, "claim" => "groups"}, grant)
  end

  defp cleanup!(marker, email) do
    Repo.delete_all(from(g in "user_groups", prefix: "platform", where: like(g.name, ^"#{marker}-%")))

    Repo.delete_all(from(u in "ng_users", prefix: "platform", where: u.email == ^email))

    refute Repo.exists?(from(g in "user_groups", prefix: "platform", where: like(g.name, ^"#{marker}-%")))

    refute Repo.exists?(from(u in "ng_users", prefix: "platform", where: u.email == ^email))
  end
end

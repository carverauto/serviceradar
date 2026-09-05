defmodule ServiceRadarWebNGWeb.Auth.SSOProvisioning do
  @moduledoc """
  Shared SSO provisioning rules for OIDC and SAML authentication flows.
  """

  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.IdpGroupMemberships
  alias ServiceRadar.Identity.MappedUserGroups
  alias ServiceRadar.Identity.RoleMapping
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadarWebNG.Audit.UserAuthEvents
  alias ServiceRadarWebNG.Auth.Hooks

  require Ash.Query
  require Logger

  @type provider :: :oidc | :saml

  @spec record_successful_authentication(User.t(), provider(), term()) ::
          {:ok, User.t()} | {:error, term()}
  def record_successful_authentication(user, provider, actor) when provider in [:oidc, :saml] do
    with {:ok, user} <- User.record_authentication(user, actor: actor) do
      Users.record_login(user, provider, actor: actor)
    end
  end

  def record_successful_authentication(_user, _provider, _actor), do: {:error, :unsupported_sso_provider}

  @spec find_or_create_user(map(), map(), provider(), term()) ::
          {:ok, User.t()} | {:error, term()}
  def find_or_create_user(%{email: email, name: name, external_id: external_id}, claims, provider, actor)
      when provider in [:oidc, :saml] and is_map(claims) do
    resolution = RoleMapping.resolve(claims, actor: actor)
    resolved_role = resolution.role

    case find_user_by_external_id(external_id, actor) do
      {:ok, user} ->
        user
        |> maybe_update_user(name, actor)
        |> maybe_update_role(resolved_role, actor)
        |> maybe_update_role_profile(resolution, actor)
        |> maybe_sync_group_memberships(resolution, actor)

      {:error, :not_found} ->
        case User.get_by_email(email, actor: actor) do
          {:ok, user} ->
            Logger.warning(
              "Rejected implicit SSO account linking for existing local user #{user.id} provider=#{provider}"
            )

            {:error, :unsafe_account_linking}

          {:error, _} ->
            email
            |> maybe_create_sso_user(name, external_id, resolved_role, provider, actor)
            |> maybe_update_role_profile(resolution, actor)
            |> maybe_sync_group_memberships(resolution, actor)
        end
    end
  end

  # Default-deny JIT provisioning: an SSO identity with no pre-existing local
  # account (neither external_id nor email matched) is only auto-created when an
  # admin has explicitly enabled `sso_auto_provision`. Otherwise login is denied.
  defp maybe_create_sso_user(email, name, external_id, resolved_role, provider, actor) do
    if sso_auto_provision?(actor) do
      create_sso_user(email, name, external_id, resolved_role, provider, actor)
    else
      Logger.info("Denied SSO JIT provisioning (sso_auto_provision off) for #{provider}")
      {:error, :no_local_account}
    end
  end

  defp sso_auto_provision?(actor) do
    case AuthSettings.get_settings(actor: actor) do
      {:ok, %{sso_auto_provision: true}} -> true
      _ -> false
    end
  end

  def find_user_by_external_id(nil, _actor), do: {:error, :not_found}

  def find_user_by_external_id(external_id, actor) do
    query =
      User
      |> Ash.Query.filter(external_id == ^external_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, [user]} -> {:ok, user}
      {:ok, []} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp maybe_update_user(user, name, actor) do
    if is_binary(name) and name != "" and user.display_name != name do
      case User.update(user, %{display_name: name}, actor: actor) do
        {:ok, updated} -> {:ok, updated}
        {:error, _} -> {:ok, user}
      end
    else
      {:ok, user}
    end
  end

  defp maybe_update_role({:ok, user}, role, actor) do
    apply_role_mapping(user, role, actor)
  end

  defp maybe_update_role_profile({:error, _reason} = error, _resolution, _actor), do: error

  # A mapping that names a role profile is what makes a group grant a permission
  # set rather than one of the four built-in roles.
  #
  # Removing a user from the group revokes it. That is only safe because
  # `role_profile_source` records who assigned the profile: clearing every
  # profile on a no-match would also wipe one an operator assigned by hand to a
  # user who has no mapping at all. A manually assigned profile is left alone.
  defp maybe_update_role_profile({:ok, user}, %{role_profile_ids: []}, actor) do
    if user.role_profile_source == :idp and not is_nil(user.role_profile_id) do
      revoke_idp_role_profile(user, actor)
    else
      {:ok, user}
    end
  end

  defp maybe_update_role_profile({:ok, user}, %{role_profile_ids: [profile_id | rest]}, actor) do
    if rest != [] do
      # Union of permissions across several profiles is not expressible while a
      # user carries a single role_profile_id. Applying the first and saying so
      # beats silently dropping the others.
      Logger.warning(
        "Multiple role profiles matched for user #{user.id}; applying #{profile_id} and ignoring #{inspect(rest)}"
      )
    end

    if user.role_profile_id == profile_id and user.role_profile_source == :idp do
      {:ok, user}
    else
      params = %{role_profile_id: profile_id, role_profile_source: :idp}

      case User.update_role_profile(user, params, actor: actor) do
        {:ok, updated} ->
          {:ok, updated}

        {:error, reason} ->
          # A mapping pointing at a deleted profile must not fail the login; the
          # user keeps whatever access they already had.
          Logger.warning("Could not apply role profile #{profile_id} to user #{user.id}: #{inspect(reason)}")

          {:ok, user}
      end
    end
  end

  defp maybe_sync_group_memberships({:error, _reason} = error, _resolution, _actor), do: error

  # Runs on every sign-in, including when nothing matched: that is what
  # withdraws memberships for a user who has left the mapped group. Operator-
  # created memberships are never touched -- see `IdpGroupMemberships`.
  defp maybe_sync_group_memberships({:ok, user}, resolution, actor) do
    record_mapping_provenance(user, resolution)
    group_ids = MappedUserGroups.ids_for_resolution(resolution, actor: actor)

    case IdpGroupMemberships.sync(user.id, group_ids, actor: actor) do
      %{added: added, withdrawn: withdrawn} when added != [] or withdrawn != [] ->
        Logger.info(
          "Synced IdP group memberships for user #{user.id}: " <>
            "added=#{length(added)} withdrawn=#{length(withdrawn)}"
        )

      %{added: _added, withdrawn: _withdrawn} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not reconcile IdP group memberships for user #{user.id}: #{inspect(reason)}")
    end

    {:ok, user}
  end

  # Only when something matched: an event per sign-in that says "nothing applied"
  # would bury the ones that did.
  defp record_mapping_provenance(_user, %{matched: []}), do: :ok

  defp record_mapping_provenance(user, resolution) do
    UserAuthEvents.record_role_mapping(user, resolution, "sso")
  end

  defp revoke_idp_role_profile(user, actor) do
    params = %{role_profile_id: nil, role_profile_source: :manual}

    case User.update_role_profile(user, params, actor: actor) do
      {:ok, updated} ->
        Logger.info("Revoked IdP-granted role profile from user #{user.id}: no mapping matched at sign-in")

        {:ok, updated}

      {:error, reason} ->
        # Failing the login would lock out a user whose access we were reducing.
        # Log loudly and let them in with the role, which `apply_role_mapping/3`
        # has already reset to the configured default.
        Logger.error("Could not revoke IdP role profile from user #{user.id}: #{inspect(reason)}")

        {:ok, user}
    end
  end

  defp apply_role_mapping(user, role, actor) do
    cond do
      is_nil(role) ->
        {:ok, user}

      user.role == :admin and role != :admin ->
        {:ok, user}

      user.role == role ->
        {:ok, user}

      true ->
        User.update_role(user, %{role: role}, actor: actor)
    end
  end

  defp create_sso_user(email, name, external_id, role, provider, actor) do
    params = %{
      email: email,
      display_name: name,
      external_id: external_id,
      role: role,
      provider: provider
    }

    case User.provision_sso_user(params, actor: actor) do
      {:ok, user} ->
        Logger.info("Created new user via #{provider} JIT provisioning: #{user.id}")
        Hooks.on_user_created(user, provider)
        {:ok, user}

      {:error, error} ->
        Logger.error("Failed to create #{provider} SSO user: #{inspect(error)}")
        {:error, :user_creation_failed}
    end
  end
end

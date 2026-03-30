defmodule ServiceRadarWebNGWeb.Auth.SSOProvisioning do
  @moduledoc """
  Shared SSO provisioning rules for OIDC and SAML authentication flows.
  """

  alias ServiceRadar.Identity.RoleMapping
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Auth.Hooks

  require Ash.Query
  require Logger

  @type provider :: :oidc | :saml

  @spec find_or_create_user(map(), map(), provider(), term()) ::
          {:ok, User.t()} | {:error, term()}
  def find_or_create_user(%{email: email, name: name, external_id: external_id}, claims, provider, actor)
      when provider in [:oidc, :saml] and is_map(claims) do
    resolved_role = RoleMapping.resolve_role(claims, actor: actor)

    case find_user_by_external_id(external_id, actor) do
      {:ok, user} ->
        user
        |> maybe_update_user(name, actor)
        |> maybe_update_role(resolved_role, actor)

      {:error, :not_found} ->
        case User.get_by_email(email, actor: actor) do
          {:ok, user} ->
            Logger.warning(
              "Rejected implicit SSO account linking for existing local user #{user.id} provider=#{provider}"
            )

            {:error, :unsafe_account_linking}

          {:error, _} ->
            create_sso_user(email, name, external_id, resolved_role, provider, actor)
        end
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

  defp maybe_update_role(result, _role, _actor), do: result

  defp apply_role_mapping(user, role, actor) do
    cond do
      is_nil(role) ->
        {:ok, user}

      user.role == :admin and role != :admin ->
        {:ok, user}

      user.role == role ->
        {:ok, user}

      true ->
        User.update_role(user, role, actor: actor)
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

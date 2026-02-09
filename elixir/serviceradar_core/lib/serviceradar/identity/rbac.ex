defmodule ServiceRadar.Identity.RBAC do
  @moduledoc """
  RBAC evaluation helpers for role profiles.
  """

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User

  @spec catalog() :: list()
  def catalog, do: Catalog.catalog()

  @spec permission_keys() :: list(String.t())
  def permission_keys, do: Catalog.permission_keys()

  @spec permissions_for_user(User.t() | map(), keyword()) :: list(String.t())
  def permissions_for_user(user, opts \\ [])

  def permissions_for_user(%User{} = user, opts) do
    key = {:rbac_permissions, user.id}

    case Process.get(key) do
      permissions when is_list(permissions) ->
        permissions

      nil ->
        actor = Keyword.get(opts, :actor, SystemActor.system(:rbac))

        permissions =
          case effective_profile(user, actor) do
            {:ok, %RoleProfile{permissions: permissions}} -> permissions
            {:ok, nil} -> Catalog.permissions_for_role(user.role)
            {:error, _} -> Catalog.permissions_for_role(user.role)
          end

        Process.put(key, permissions)
        permissions
    end
  end

  def permissions_for_user(%{permissions: permissions} = _user, _opts)
      when is_list(permissions) do
    permissions
  end

  def permissions_for_user(%{role: role} = _user, _opts) do
    Catalog.permissions_for_role(role)
  end

  def permissions_for_user(_, _opts), do: []

  @doc "Clears the process-level RBAC cache."
  def clear_process_cache do
    Process.get_keys()
    |> Enum.each(fn
      {:rbac_permissions, _} = key -> Process.delete(key)
      _ -> :ok
    end)
  end

  @spec has_permission?(User.t() | map(), String.t(), keyword()) :: boolean()
  def has_permission?(user, permission, opts \\ []) do
    permission in permissions_for_user(user, opts)
  end

  @spec effective_profile(User.t(), map()) :: {:ok, RoleProfile.t()} | {:error, term()}
  def effective_profile(%User{} = user, actor) do
    cond do
      not is_nil(user.role_profile_id) ->
        RoleProfile.get_by_id(user.role_profile_id, actor: actor)

      system_profile = Catalog.system_profile_for_role(user.role) ->
        RoleProfile.get_by_system_name(system_profile.system_name, actor: actor)

      true ->
        {:error, :no_profile}
    end
  end
end

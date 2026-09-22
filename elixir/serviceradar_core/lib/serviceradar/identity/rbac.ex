defmodule ServiceRadar.Identity.RBAC do
  @moduledoc """
  RBAC evaluation helpers for role profiles.

  Uses one shared permission cache:
  - **L1**: Shared ETS table via `RBAC.Cache` (cross-process, TTL-based)
  - **L2**: Database query via `effective_authority/2` (fallback)

  Permissions are stored as `MapSet.t(String.t())` for O(1) membership checks.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership

  require Ash.Query

  @spec catalog() :: list()
  def catalog, do: Catalog.catalog()

  @spec permission_keys() :: list(String.t())
  def permission_keys, do: Catalog.permission_keys()

  @spec permissions_for_user(User.t() | map(), keyword()) :: MapSet.t(String.t())
  def permissions_for_user(user, opts \\ [])

  def permissions_for_user(%User{} = user, opts) do
    if Keyword.get(opts, :fresh?, false) do
      permissions = query_permissions(user, opts)
      Cache.put(user.id, permissions)
      permissions
    else
      fetch_cached_or_query(user, opts)
    end
  end

  # Backward compat for map actors with pre-loaded permissions
  def permissions_for_user(%{permissions: %MapSet{} = permissions}, _opts) do
    permissions
  end

  def permissions_for_user(%{permissions: permissions}, _opts) when is_list(permissions) do
    MapSet.new(permissions)
  end

  def permissions_for_user(%{role: role}, _opts) do
    Catalog.permissions_for_role(role)
  end

  def permissions_for_user(_, _opts), do: MapSet.new()

  # Shared ETS cache → database query
  defp fetch_cached_or_query(user, opts) do
    case Cache.get(user.id) do
      {:ok, %MapSet{} = cached} ->
        cached

      :miss ->
        perms = query_permissions(user, opts)
        Cache.put(user.id, perms)
        perms
    end
  end

  defp query_permissions(user, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:rbac))

    case effective_authority(user, actor) do
      {:ok, %{permissions: %MapSet{} = permissions}} -> permissions
      {:error, _} -> Catalog.permissions_for_role(user.role)
    end
  end

  @doc "Compatibility no-op: RBAC caching is shared ETS only."
  def clear_process_cache, do: :ok

  @spec has_permission?(User.t() | map(), String.t(), keyword()) :: boolean()
  def has_permission?(user, permission, opts \\ []) do
    Catalog.holds?(permissions_for_user(user, opts), permission)
  end

  @spec equivalent_keys(String.t()) :: [String.t()]
  def equivalent_keys(permission), do: Catalog.equivalent_keys(permission)

  @doc """
  Broadcasts a cache invalidation for the given user ID.
  Call this when a user's role or profile changes.
  """
  @spec invalidate_user_cache(String.t()) :: :ok
  def invalidate_user_cache(user_id) when is_binary(user_id) do
    Cache.invalidate(user_id)

    if Process.whereis(ServiceRadar.PubSub) do
      Phoenix.PubSub.broadcast(
        ServiceRadar.PubSub,
        "rbac:cache_invalidation",
        {:rbac_cache_invalidate, user_id}
      )
    end

    :ok
  end

  @doc """
  Broadcasts a full cache invalidation (e.g. when a RoleProfile changes).
  """
  @spec invalidate_all_caches() :: :ok
  def invalidate_all_caches do
    Cache.invalidate_all()

    if Process.whereis(ServiceRadar.PubSub) do
      Phoenix.PubSub.broadcast(
        ServiceRadar.PubSub,
        "rbac:cache_invalidation",
        {:rbac_cache_invalidate_all}
      )
    end

    :ok
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

  @spec effective_authority(User.t(), map()) ::
          {:ok,
           %{
             permissions: MapSet.t(String.t()),
             profile_versions: [%{id: String.t(), updated_at: DateTime.t()}]
           }}
          | {:error, term()}
  def effective_authority(%User{} = user, actor) do
    with {:ok, base} <- strict_base_profile(user, actor),
         {:ok, memberships} <- UserGroupMembership.list_by_user(user.id, actor: actor),
         {:ok, groups} <- load_groups_with_profiles(memberships, actor) do
      profiles =
        [base | Enum.map(groups, & &1.role_profile)]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&to_string(&1.id))

      {:ok,
       %{
         permissions: union_permissions(profiles),
         profile_versions: Enum.map(profiles, &profile_version/1)
       }}
    end
  end

  @spec effective_permissions(User.t(), map()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def effective_permissions(%User{} = user, actor) do
    with {:ok, %{permissions: permissions}} <- effective_authority(user, actor),
         do: {:ok, permissions}
  end

  defp strict_base_profile(user, actor) do
    case effective_profile(user, actor) do
      {:ok, %RoleProfile{} = profile} -> {:ok, profile}
      {:ok, nil} -> {:error, :no_profile}
      {:error, _reason} = error -> error
    end
  end

  defp load_groups_with_profiles([], _actor), do: {:ok, []}

  defp load_groups_with_profiles(memberships, actor) do
    group_ids = memberships |> Enum.map(& &1.group_id) |> Enum.uniq()

    UserGroup
    |> Ash.Query.filter(id in ^group_ids)
    |> Ash.read(actor: actor, load: [:role_profile])
    |> case do
      {:ok, groups} when length(groups) == length(group_ids) -> {:ok, groups}
      {:ok, _groups} -> {:error, :group_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp union_permissions(profiles) do
    Enum.reduce(profiles, MapSet.new(), fn profile, permissions ->
      MapSet.union(permissions, MapSet.new(profile.permissions || []))
    end)
  end

  defp profile_version(profile), do: %{id: to_string(profile.id), updated_at: profile.updated_at}
end

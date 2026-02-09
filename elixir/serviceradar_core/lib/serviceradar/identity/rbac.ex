defmodule ServiceRadar.Identity.RBAC do
  @moduledoc """
  RBAC evaluation helpers for role profiles.

  Uses a two-tier permission cache:
  - **L1**: Process dictionary (fastest, per-process)
  - **L2**: Shared ETS table via `RBAC.Cache` (cross-process, TTL-based)
  - **L3**: Database query via `effective_profile/2` (fallback)

  Permissions are stored as `MapSet.t(String.t())` for O(1) membership checks.
  """

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User

  @spec catalog() :: list()
  def catalog, do: Catalog.catalog()

  @spec permission_keys() :: list(String.t())
  def permission_keys, do: Catalog.permission_keys()

  @spec permissions_for_user(User.t() | map(), keyword()) :: MapSet.t(String.t())
  def permissions_for_user(user, opts \\ [])

  def permissions_for_user(%User{} = user, opts) do
    process_key = {:rbac_permissions, user.id}

    # L1: Process dictionary (fastest)
    case Process.get(process_key) do
      %MapSet{} = permissions ->
        permissions

      nil ->
        permissions = fetch_cached_or_query(user, opts)
        Process.put(process_key, permissions)
        permissions
    end
  end

  # L2: Shared ETS cache → L3: Database query
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

    case effective_profile(user, actor) do
      {:ok, %RoleProfile{permissions: permissions}} -> MapSet.new(permissions)
      {:ok, nil} -> Catalog.permissions_for_role(user.role)
      {:error, _} -> Catalog.permissions_for_role(user.role)
    end
  end

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
    MapSet.member?(permissions_for_user(user, opts), permission)
  end

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
end

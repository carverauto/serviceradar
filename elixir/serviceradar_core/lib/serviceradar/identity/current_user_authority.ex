defmodule ServiceRadar.Identity.CurrentUserAuthority do
  @moduledoc """
  Reconstructs a logged-in human user's current authority from persistence.

  Long-lived browser scopes and websocket processes may outlive a role change,
  account deactivation, or role-profile edit. This module deliberately ignores
  authority cached on those caller-controlled/stale values. The system actor is
  used only to cross the storage policy boundary; it is never returned or used
  as the effective principal.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadar.Identity.User

  @store_actor SystemActor.system(:current_user_authority_store)
  @denied {:error, :current_authority_denied}

  @type authority :: %{
          user: User.t() | map(),
          permissions: MapSet.t(String.t()),
          profile_versions: [%{id: String.t(), updated_at: DateTime.t()}]
        }

  @doc """
  Reloads the initiating human and requires every requested permission.

  A scope-shaped map or a user actor may be supplied. Any cached `permissions`
  field is ignored. Dependency overrides exist only for focused boundary tests.
  """
  @spec authorize(map(), String.t() | [String.t()], keyword()) ::
          {:ok, authority()} | {:error, :current_authority_denied}
  def authorize(scope_or_actor, required_permissions, opts \\ [])

  def authorize(scope_or_actor, required_permissions, opts) when is_list(opts) do
    dependencies = dependencies(opts)

    with {:ok, permissions_required} <- normalize_permissions(required_permissions),
         {:ok, actor_id} <- initiating_actor_id(scope_or_actor),
         {:ok, current_user} <- load_current_user(dependencies, actor_id),
         :ok <- validate_current_user(current_user, actor_id),
         {:ok, authority} <- load_authority(dependencies, current_user),
         true <- Enum.all?(permissions_required, &Catalog.holds?(authority.permissions, &1)) do
      {:ok, Map.put(authority, :user, current_user)}
    else
      _ -> @denied
    end
  rescue
    _ -> @denied
  catch
    _, _ -> @denied
  end

  def authorize(_scope_or_actor, _required_permissions, _opts), do: @denied

  defp dependencies(opts) do
    overrides = Keyword.get(opts, :dependencies, %{})

    Map.merge(
      %{
        load_user: &default_load_user/1,
        load_authority: &default_load_authority/1
      },
      overrides
    )
  end

  defp normalize_permissions(permission) when is_binary(permission) and permission != "",
    do: {:ok, [permission]}

  defp normalize_permissions([]), do: {:ok, []}

  defp normalize_permissions(permissions) when is_list(permissions) do
    if Enum.all?(permissions, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(permissions)}
    else
      @denied
    end
  end

  defp normalize_permissions(_permissions), do: @denied

  defp initiating_actor_id(%{user: user}), do: initiating_actor_id(user)
  defp initiating_actor_id(%{"user" => user}), do: initiating_actor_id(user)
  defp initiating_actor_id(%{role: :system}), do: @denied
  defp initiating_actor_id(%{"role" => "system"}), do: @denied

  defp initiating_actor_id(%{id: id}) when not is_nil(id), do: non_empty_id(id)
  defp initiating_actor_id(%{"id" => id}) when not is_nil(id), do: non_empty_id(id)
  defp initiating_actor_id(_actor), do: @denied

  defp non_empty_id(id) do
    case to_string(id) do
      "" -> @denied
      actor_id -> {:ok, actor_id}
    end
  rescue
    _ -> @denied
  end

  defp load_current_user(dependencies, actor_id) do
    case dependencies.load_user.(actor_id) do
      {:ok, user} when not is_nil(user) -> {:ok, user}
      _ -> @denied
    end
  end

  defp validate_current_user(user, actor_id) do
    cond do
      canonical_id(field(user, :id)) != actor_id -> @denied
      field(user, :status) not in [:active, "active"] -> @denied
      field(user, :role) in [:system, "system"] -> @denied
      true -> :ok
    end
  end

  defp load_authority(dependencies, current_user) do
    case dependencies.load_authority.(current_user) do
      {:ok, %{permissions: %MapSet{} = permissions, profile_versions: profile_versions}}
      when is_list(profile_versions) ->
        {:ok, %{permissions: permissions, profile_versions: profile_versions}}

      _ ->
        @denied
    end
  end

  defp default_load_user(actor_id), do: User.get_by_id(actor_id, actor: @store_actor)

  defp default_load_authority(current_user),
    do: RBAC.effective_authority(current_user, @store_actor)

  defp canonical_id(nil), do: nil

  defp canonical_id(id) do
    to_string(id)
  rescue
    _ -> nil
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end

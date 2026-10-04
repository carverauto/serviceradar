defmodule ServiceRadarWebNGWeb.HomepageRedirect do
  @moduledoc """
  Loads the signed-in user's group memberships and turns the winning homepage
  into an allowlisted path.

  Membership is read here, as a system actor, because a normal user may not
  have `identity.user_groups.view`. Callers run this only after SSO provisioning
  has already synced those memberships on the same request.
  """

  use ServiceRadarWebNGWeb, :verified_routes

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Homepage
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards

  require Ash.Query
  require Logger

  @fallback_notice "Your saved homepage is no longer available, so this sign-in opened the next default."

  @spec resolve(map()) :: {String.t(), String.t() | nil}
  def resolve(user) when is_map(user) do
    groups = memberships(user)

    case Homepage.resolve(user, groups, &allowed?(user, &1)) do
      {:ok, choice} ->
        case path_for(user, choice) do
          path when is_binary(path) -> {path, nil}
          :error -> {~p"/dashboard", @fallback_notice}
        end

      {:fallback, choice, :unavailable} ->
        case path_for(user, choice) do
          path when is_binary(path) -> {path, @fallback_notice}
          :error -> {~p"/dashboard", @fallback_notice}
        end
    end
  rescue
    exception ->
      Logger.warning("homepage redirect failed: #{Exception.message(exception)}")
      {~p"/dashboard", nil}
  end

  defp memberships(%{id: user_id}) when is_binary(user_id) do
    actor = SystemActor.system(:homepage_redirect)

    UserGroupMembership
    |> Ash.Query.for_read(:by_user, %{user_id: user_id})
    |> Ash.Query.load(:group)
    |> Ash.read!(actor: actor)
    |> Enum.flat_map(&membership_group/1)
  rescue
    exception ->
      Logger.warning("homepage membership load failed: #{Exception.message(exception)}")
      []
  end

  defp memberships(_user), do: []

  defp membership_group(%{group: %{name: name} = group, inserted_at: inserted_at}) when is_binary(name) do
    [
      %{
        name: name,
        homepage_kind: Map.get(group, :homepage_kind),
        homepage_target: Map.get(group, :homepage_target),
        assigned_at: inserted_at
      }
    ]
  end

  defp membership_group(_membership), do: []

  defp allowed?(user, %{kind: :authored, target: target}), do: match?({:ok, _}, authored(user, target))
  defp allowed?(user, %{kind: :package, target: target}), do: match?({:ok, _}, package(user, target))
  defp allowed?(_user, _choice), do: false

  defp path_for(_user, %{kind: :platform}), do: ~p"/dashboard"
  defp path_for(_user, %{kind: :dashboards}), do: ~p"/dashboards"

  defp path_for(user, %{kind: :authored, target: target}) do
    case authored(user, target) do
      {:ok, dashboard} -> dashboard_path(Dashboards.authored_dashboard_route_ref(dashboard))
      :error -> :error
    end
  end

  defp path_for(user, %{kind: :package, target: target}) do
    case package(user, target) do
      {:ok, %{route_slug: slug}} -> package_path(slug)
      :error -> :error
    end
  end

  defp path_for(_user, _choice), do: :error

  defp authored(user, target) when is_binary(target) do
    case Dashboards.get_authored_dashboard(scope(user), target, load: []) do
      {:ok, %{status: :active} = dashboard} -> {:ok, dashboard}
      _other -> :error
    end
  end

  defp authored(_user, _target), do: :error

  defp package(user, slug) when is_binary(slug) do
    case Dashboards.get_enabled_instance_by_slug(slug, scope: scope(user)) do
      {:ok, %{enabled: true, route_slug: route} = instance} when is_binary(route) and route != "" ->
        {:ok, instance}

      _other ->
        :error
    end
  end

  defp package(_user, _slug), do: :error

  defp dashboard_path(ref) when is_binary(ref) and ref != "" do
    if Homepage.valid_target?(ref), do: ~p"/dashboard/#{ref}", else: :error
  end

  defp dashboard_path(_ref), do: :error

  defp package_path(slug) when is_binary(slug) do
    if Homepage.valid_target?(slug), do: ~p"/dashboards/#{slug}", else: :error
  end

  defp package_path(_slug), do: :error

  defp scope(user), do: Scope.for_user(user)
end

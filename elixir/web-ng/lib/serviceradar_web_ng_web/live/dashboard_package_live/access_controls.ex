defmodule ServiceRadarWebNGWeb.DashboardPackageLive.AccessControls do
  @moduledoc false

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls, as: AuthoredAccessControls

  def default_user_grant_params, do: AuthoredAccessControls.default_user_grant_params()
  def default_group_grant_params, do: AuthoredAccessControls.default_group_grant_params()
  def access_select_options, do: AuthoredAccessControls.access_select_options()
  def group_select_options(groups), do: AuthoredAccessControls.group_select_options(groups)
  def user_select_options(users), do: AuthoredAccessControls.user_select_options(users)
  def grant_label(grant), do: AuthoredAccessControls.grant_label(grant)

  def can_share_instance?(nil, _scope), do: false

  def can_share_instance?(instance, scope) do
    instance_owner?(instance, scope) or RBAC.can?(scope, "dashboards.packages.share")
  end

  def instance_owner?(%{owner_id: owner_id}, %{user: %{id: user_id}}) when not is_nil(owner_id) and not is_nil(user_id) do
    to_string(owner_id) == to_string(user_id)
  end

  def instance_owner?(_instance, _scope), do: false

  def can_view_groups?(scope), do: RBAC.can?(scope, "identity.user_groups.view")

  def can_view_share_principals?(scope), do: RBAC.can?(scope, "analytics.share_principals.view")

  def can_manage_queries?(scope), do: RBAC.can?(scope, "analytics.manage_queries")

  def authorize_share(socket) do
    if can_share_instance?(socket.assigns[:instance], socket.assigns.current_scope),
      do: :ok,
      else: {:error, :forbidden}
  end

  def load(scope, instance, assigns) do
    if can_share_instance?(instance, scope) do
      %{
        access_grants: Dashboards.list_instance_access_grants(scope, instance.id),
        user_groups: if(assigns.can_view_groups?, do: Dashboards.list_user_groups(scope), else: []),
        users:
          if(assigns.can_view_share_principals?,
            do: Dashboards.list_share_principals(scope),
            else: []
          )
      }
    else
      %{access_grants: [], user_groups: [], users: []}
    end
  end

  def visibility_options do
    [{"Private", "private"}, {"Shared", "shared"}, {"Public", "public"}]
  end
end

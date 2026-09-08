defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls do
  @moduledoc false

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC

  def default_user_grant_params do
    %{"subject_user_id" => "", "access" => "view"}
  end

  def default_group_grant_params do
    %{"subject_group_id" => "", "access" => "view"}
  end

  def load(scope, dashboard, assigns) do
    access_grants =
      if settings_available?(dashboard, Map.put(assigns, :current_scope, scope)) do
        Dashboards.list_authored_access_grants(scope, dashboard.id)
      else
        []
      end

    user_groups =
      if assigns.can_view_groups? do
        Dashboards.list_user_groups(scope)
      else
        []
      end

    users =
      if assigns.can_view_share_principals? do
        Dashboards.list_share_principals(scope)
      else
        []
      end

    %{access_grants: access_grants, user_groups: user_groups, users: users}
  end

  def assigns(assigns) do
    assigns
    |> Map.take([:can_edit?, :can_share?, :can_view_groups?, :can_view_share_principals?])
    |> Map.put_new(:current_scope, Map.get(assigns, :current_scope))
  end

  def settings_available?(nil, _assigns), do: false

  def settings_available?(dashboard, assigns) do
    can_manage?(dashboard, assigns) or can_share_dashboard?(dashboard, assigns) or
      can_schedule_dashboard?(dashboard, assigns)
  end

  def can_manage?(nil, _assigns), do: false

  def can_manage?(dashboard, assigns) do
    dashboard_owner?(dashboard, Map.get(assigns, :current_scope)) or
      Map.get(assigns, :can_edit?, false)
  end

  def can_share_dashboard?(nil, _assigns), do: false

  def can_share_dashboard?(dashboard, assigns) do
    can_manage?(dashboard, assigns) and Map.get(assigns, :can_share?, false)
  end

  def can_schedule_dashboard?(nil, _assigns), do: false

  def can_schedule_dashboard?(dashboard, assigns) do
    Map.get(assigns, :can_schedule_reports?, false) and
      (can_manage?(dashboard, assigns) or public_or_shared?(dashboard))
  end

  defp public_or_shared?(%{visibility: visibility}) when visibility in [:public, :shared, "public", "shared"], do: true

  defp public_or_shared?(_dashboard), do: false

  def dashboard_owner?(%{owner_id: owner_id}, %{user: %{id: user_id}})
      when not is_nil(owner_id) and not is_nil(user_id) do
    to_string(owner_id) == to_string(user_id)
  end

  def dashboard_owner?(_dashboard, _scope), do: false

  def can_edit?(scope), do: RBAC.can?(scope, "analytics.dashboards.edit")
  def can_share?(scope), do: RBAC.can?(scope, "analytics.dashboards.share")
  def can_schedule_reports?(scope), do: RBAC.can?(scope, "analytics.reports.schedule")
  def can_view_groups?(scope), do: RBAC.can?(scope, "identity.user_groups.view")

  def can_view_share_principals?(scope), do: RBAC.can?(scope, "analytics.share_principals.view")

  def authorize_share(socket) do
    if can_share_dashboard?(socket.assigns.dashboard, socket.assigns),
      do: :ok,
      else: {:error, :forbidden}
  end

  def authorize_panel_edit(socket) do
    if can_manage?(socket.assigns.dashboard, socket.assigns),
      do: :ok,
      else: {:error, :forbidden}
  end

  def authorize_report_schedule(socket) do
    if can_schedule_dashboard?(socket.assigns.dashboard, socket.assigns),
      do: :ok,
      else: {:error, :forbidden}
  end

  def access_select_options, do: [{"View", "view"}, {"Edit", "edit"}]

  def group_select_options(groups) do
    Enum.map(groups, &{&1.name, &1.id})
  end

  def user_select_options(users) do
    Enum.map(users, &{user_label(&1), &1.id})
  end

  def grant_label(%{subject_type: :user, subject_user: user}), do: user_label(user)
  def grant_label(%{subject_type: "user", subject_user: user}), do: user_label(user)
  def grant_label(%{subject_type: :group, subject_group: group}), do: group_label(group)
  def grant_label(%{subject_type: "group", subject_group: group}), do: group_label(group)
  def grant_label(_grant), do: "Unknown principal"

  defp group_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp group_label(_group), do: "Unknown group"

  defp user_label(%{display_name: name, email: email}) when is_binary(name) and name != "" do
    "#{name} <#{email}>"
  end

  defp user_label(%{email: %Ash.CiString{} = email}), do: to_string(email)
  defp user_label(%{email: email}) when is_binary(email), do: email
  defp user_label(_user), do: "Unknown user"
end

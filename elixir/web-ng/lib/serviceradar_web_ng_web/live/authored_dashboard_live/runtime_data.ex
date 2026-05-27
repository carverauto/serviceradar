defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.RuntimeData do
  @moduledoc false

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.DashboardVariables

  def load_dashboard(scope, dashboard_id, current_variable_values, access_assigns) do
    with {:ok, %AuthoredDashboard{} = dashboard} <-
           Dashboards.get_authored_dashboard(scope, dashboard_id, load: [:panels, :report_schedules]) do
      panels = panels(dashboard)
      variable_values = DashboardVariables.values(dashboard, current_variable_values)
      results = panel_results(scope, panels, variable_values)
      trends = trend_results(scope, panels, variable_values)
      access = AccessControls.load(scope, dashboard, access_assigns)
      clone_targets = clone_targets(scope, dashboard)

      {:ok, dashboard, panels, results, trends, variable_values, access, clone_targets}
    end
  end

  def panels(dashboard) do
    Enum.sort_by(dashboard.panels || [], &{&1.position, &1.inserted_at})
  end

  def panel_results(scope, panels, variable_values) do
    Map.new(panels, fn panel ->
      {panel.id, preview_panel_query(scope, panel, variable_values)}
    end)
  end

  def trend_results(scope, panels, variable_values) do
    Map.new(panels, fn panel ->
      {panel.id, preview_trend_query(scope, panel, variable_values)}
    end)
  end

  def preview_panel_query(scope, panel, variable_values) do
    query = DashboardVariables.substitute(panel.srql_query, variable_values)
    Dashboards.preview_authored_query(scope, query, limit: 250)
  end

  def preview_trend_query(scope, panel, variable_values) do
    query =
      panel
      |> Map.get(:visual_config, %{})
      |> Map.get("trend_query")

    case query do
      value when is_binary(value) and value != "" ->
        Dashboards.preview_authored_query(scope, DashboardVariables.substitute(value, variable_values), limit: 250)

      _ ->
        nil
    end
  end

  def clone_targets(scope, dashboard) do
    scope
    |> Dashboards.list_authored_dashboards(%{status: [:draft, :active], limit: 200})
    |> Enum.reject(&(&1.id == dashboard.id))
    |> Enum.sort_by(&String.downcase(&1.title || ""))
  end

  def default_clone_target_id([target | _]), do: target.id
  def default_clone_target_id(_targets), do: ""
end

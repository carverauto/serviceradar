defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.RuntimeData do
  @moduledoc false

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.DashboardVariables

  @preview_limit 250
  @aggregate_render_limit 10_000

  def load_dashboard(scope, dashboard_id, current_variable_values, access_assigns) do
    with {:ok, %AuthoredDashboard{} = dashboard} <-
           Dashboards.get_authored_dashboard(scope, dashboard_id, load: [:panels, :report_schedules]) do
      panels = panels(dashboard)
      variables = DashboardVariables.list(dashboard)
      variable_values = DashboardVariables.values(variables, current_variable_values)
      results = panel_results(scope, panels, variable_values, variables)
      trends = trend_results(scope, panels, variable_values, variables)
      access = AccessControls.load(scope, dashboard, access_assigns)
      clone_targets = clone_targets(scope, dashboard)

      {:ok, dashboard, panels, results, trends, variable_values, access, clone_targets}
    end
  end

  def panels(dashboard) do
    Enum.sort_by(dashboard.panels || [], &{&1.position, &1.inserted_at})
  end

  def panel_results(scope, panels, variable_values, variables \\ []) do
    Map.new(panels, fn panel ->
      {panel.id, preview_panel_query(scope, panel, variable_values, variables)}
    end)
  end

  def trend_results(scope, panels, variable_values, variables \\ []) do
    Map.new(panels, fn panel ->
      {panel.id, preview_trend_query(scope, panel, variable_values, variables)}
    end)
  end

  def preview_panel_query(scope, panel, variable_values, variables \\ []) do
    query =
      panel.srql_query
      |> DashboardVariables.substitute(variable_values, variables)
      |> maybe_enable_table_other_rollup(panel)

    limit = panel_render_limit(panel)
    Dashboards.preview_authored_query(scope, query, limit: limit, max_limit: limit)
  end

  def preview_trend_query(scope, panel, variable_values, variables \\ []) do
    query =
      panel
      |> Map.get(:visual_config, %{})
      |> Map.get("trend_query")

    case query do
      value when is_binary(value) and value != "" ->
        Dashboards.preview_authored_query(scope, DashboardVariables.substitute(value, variable_values, variables),
          limit: @preview_limit,
          max_limit: @preview_limit
        )

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

  defp panel_render_limit(%{visual_type: visual_type})
       when visual_type in [:stat, "stat", :count, "count", :pivot, "pivot"], do: @aggregate_render_limit

  defp panel_render_limit(_panel), do: @preview_limit

  defp maybe_enable_table_other_rollup(query, %{visual_type: visual_type})
       when visual_type in [:table, "table"] and is_binary(query) do
    if flow_table_other_rollup_query?(query), do: query <> " other:true", else: query
  end

  defp maybe_enable_table_other_rollup(query, _panel), do: query

  defp flow_table_other_rollup_query?(query) do
    tokens = split_srql_tokens(query)
    lower_query = String.downcase(query)

    flow_query?(tokens) and stats_query?(tokens) and grouped_stats_query?(tokens, lower_query) and
      sorted_query?(tokens) and not other_token?(tokens) and additive_flow_stats?(tokens)
  end

  defp flow_query?(tokens), do: Enum.any?(tokens, &(String.downcase(&1) == "in:flows"))
  defp stats_query?(tokens), do: Enum.any?(tokens, &(&1 |> String.downcase() |> String.starts_with?("stats:")))
  defp sorted_query?(tokens), do: Enum.any?(tokens, &(&1 |> String.downcase() |> String.starts_with?("sort:")))
  defp other_token?(tokens), do: Enum.any?(tokens, &(&1 |> String.downcase() |> String.starts_with?("other:")))

  defp grouped_stats_query?(tokens, lower_query) do
    Enum.any?(tokens, &(String.downcase(&1) == "by")) or String.contains?(lower_query, " by ")
  end

  defp additive_flow_stats?(tokens) do
    tokens
    |> Enum.filter(&(&1 |> String.downcase() |> String.starts_with?("stats:")))
    |> Enum.all?(fn token ->
      stats = String.downcase(token)

      (String.contains?(stats, "sum(") or String.contains?(stats, "count(")) and
        not Regex.match?(~r/(avg|min|max|rate)\s*\(/, stats)
    end)
  end

  defp split_srql_tokens(query) do
    {tokens, current, _quote, _escaped?} =
      query
      |> String.graphemes()
      |> Enum.reduce({[], "", nil, false}, &split_srql_token/2)

    tokens =
      if current == "" do
        tokens
      else
        [current | tokens]
      end

    Enum.reverse(tokens)
  end

  defp split_srql_token(char, {tokens, current, quote, true}) do
    {tokens, current <> char, quote, false}
  end

  defp split_srql_token("\\", {tokens, current, quote, false}) when not is_nil(quote) do
    {tokens, current <> "\\", quote, true}
  end

  defp split_srql_token(char, {tokens, current, quote, false}) when char == quote and not is_nil(quote) do
    {tokens, current <> char, nil, false}
  end

  defp split_srql_token(char, {tokens, current, quote, false}) when not is_nil(quote) do
    {tokens, current <> char, quote, false}
  end

  defp split_srql_token(char, {tokens, current, nil, false}) when char in ["\"", "'"] do
    {tokens, current <> char, char, false}
  end

  defp split_srql_token(char, {tokens, current, nil, false}) when char in [" ", "\n", "\r", "\t"] do
    if current == "" do
      {tokens, "", nil, false}
    else
      {[current | tokens], "", nil, false}
    end
  end

  defp split_srql_token(char, {tokens, current, quote, escaped?}) do
    {tokens, current <> char, quote, escaped?}
  end
end

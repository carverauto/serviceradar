defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.LayoutHelpers do
  @moduledoc false

  def dashboard_panel_entries(nil), do: []

  def dashboard_panel_entries(%{panels: panels}) when is_list(panels) do
    layouts =
      panels
      |> Map.new(&{&1.id, normalized_panel_layout(&1)})
      |> fill_final_orphan_layout(panels)

    Enum.map(panels, fn panel ->
      %{panel: panel, style: panel_grid_style(panel, Map.get(layouts, panel.id))}
    end)
  end

  def dashboard_panel_entries(_dashboard), do: []

  def panel_grid_style(panel, layout_override) do
    layout = layout_override || panel.layout || %{}
    x = layout |> Map.get("x", 0) |> bounded_integer(0, 11)
    width = layout |> Map.get("w", 12) |> bounded_integer(1, 12 - x)
    y = layout |> Map.get("y", 0) |> bounded_integer(0, 1_000)
    height = layout |> Map.get("h", 4) |> bounded_integer(2, 16)
    order = layout |> Map.get("order", panel.position || 0) |> bounded_integer(0, 1_000)

    "--sr-panel-x: #{x + 1}; --sr-panel-y: #{y + 1}; --sr-panel-w: #{width}; --sr-panel-h: #{height}; --sr-panel-order: #{order};"
  end

  def normalized_panel_layout(panel) do
    layout = panel.layout || %{}
    x = layout |> Map.get("x", 0) |> bounded_integer(0, 11)
    width = layout |> Map.get("w", 12) |> bounded_integer(1, 12 - x)
    y = layout |> Map.get("y", 0) |> bounded_integer(0, 1_000)
    height = layout |> Map.get("h", 4) |> bounded_integer(2, 16)
    order = layout |> Map.get("order", panel.position || 0) |> bounded_integer(0, 1_000)

    Map.merge(layout, %{"x" => x, "y" => y, "w" => width, "h" => height, "order" => order})
  end

  def fill_final_orphan_layout(layouts, panels) do
    final_row =
      panels
      |> Enum.map(fn panel -> {panel, Map.get(layouts, panel.id)} end)
      |> Enum.reject(fn {_panel, layout} -> is_nil(layout) end)
      |> Enum.group_by(fn {_panel, layout} -> Map.get(layout, "y", 0) end)
      |> Enum.max_by(fn {y, _row} -> y end, fn -> nil end)

    case final_row do
      {_y, [{panel, layout}]} ->
        width = layout |> Map.get("w", 12) |> bounded_integer(1, 12)

        if width < 12 do
          Map.put(layouts, panel.id, Map.merge(layout, %{"x" => 0, "w" => 12}))
        else
          layouts
        end

      _ ->
        layouts
    end
  end

  def bounded_integer(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  def bounded_integer(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> bounded_integer(integer, min, max)
      _ -> min
    end
  end

  def bounded_integer(value, min, max) when is_float(value), do: value |> round() |> bounded_integer(min, max)
  def bounded_integer(_value, min, _max), do: min
end

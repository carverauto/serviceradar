defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelParams do
  @moduledoc false

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.LayoutHelpers
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueries

  def default do
    %{
      "dataset_key" => "",
      "title" => "",
      "srql_query" => "",
      "visual_type" => "table",
      "value_field" => "",
      "numerator_field" => "",
      "denominator_field" => "",
      "label_field" => "",
      "row_field" => "",
      "column_field" => "",
      "time_field" => "",
      "status_field" => "",
      "aggregate" => "sum",
      "empty_value" => "0",
      "display_label" => "",
      "unit" => "",
      "caption" => "",
      "capacity_forecast_mode" => "",
      "table_columns" => "",
      "trend_mode" => "",
      "trend_lookback_days" => "30",
      "trend_query" => "",
      "layout_x" => "0",
      "layout_y" => "0",
      "layout_w" => "12",
      "layout_h" => "8",
      "refresh_interval_seconds" => "0",
      "position" => "0"
    }
  end

  def from_panel(panel) do
    binding = panel.data_binding || %{}
    display = panel.display_config || %{}
    visual = panel.visual_config || %{}
    layout = panel.layout || %{}

    %{
      "dataset_key" => panel.dataset_key || "primary",
      "title" => panel.title || "",
      "srql_query" => panel.srql_query || "",
      "visual_type" => to_string(panel.visual_type || :table),
      "value_field" => map_value(binding, "value_field"),
      "numerator_field" => map_value(binding, "numerator_field"),
      "denominator_field" => map_value(binding, "denominator_field"),
      "label_field" => map_value(binding, "label_field"),
      "row_field" => map_value(binding, "row_field"),
      "column_field" => map_value(binding, "column_field"),
      "time_field" => map_value(binding, "time_field"),
      "status_field" => map_value(binding, "status_field"),
      "aggregate" => map_value(binding, "aggregate", "sum"),
      "empty_value" => map_value(binding, "empty_value", "0"),
      "display_label" => map_value(display, "label"),
      "unit" => map_value(display, "unit"),
      "caption" => map_value(display, "caption"),
      "capacity_forecast_mode" => capacity_forecast_mode(display),
      "table_columns" => table_columns_text(map_value(display, "table_columns", [])),
      "trend_mode" => map_value(visual, "trend_mode"),
      "trend_lookback_days" => to_string(map_value(visual, "trend_lookback_days", 30)),
      "trend_query" => map_value(visual, "trend_query"),
      "layout_x" => to_string(map_value(layout, "x", 0)),
      "layout_y" => to_string(map_value(layout, "y", 0)),
      "layout_w" => to_string(map_value(layout, "w", 12)),
      "layout_h" => to_string(map_value(layout, "h", 8)),
      "refresh_interval_seconds" => to_string(map_value(panel, :refresh_interval_seconds, 0)),
      "position" => to_string(map_value(panel, :position, 0))
    }
  end

  def attrs(params) do
    dataset_key = dataset_key(params)

    %{
      dataset_key: dataset_key,
      title: params["title"],
      srql_query: params["srql_query"],
      visual_type: params["visual_type"],
      data_binding: data_binding(params, dataset_key),
      display_config: display_config(params),
      visual_config: visual_config(params),
      layout: layout(params),
      refresh_interval_seconds: integer_value(params["refresh_interval_seconds"], 0),
      position: integer_value(params["position"], 0)
    }
  end

  def duplicate_attrs(panel, dashboard) do
    panels = Map.get(dashboard, :panels, []) || []
    position = length(panels)

    %{
      dashboard_id: dashboard.id,
      dataset_key: unique_dataset_key(panel.dataset_key || "panel", panels),
      title: "#{panel.title} Copy",
      srql_query: panel.srql_query,
      builder_state: panel.builder_state || %{},
      visual_type: panel.visual_type,
      data_binding: panel.data_binding || %{},
      display_config: panel.display_config || %{},
      visual_config: panel.visual_config || %{},
      field_metadata: panel.field_metadata || %{},
      layout: next_panel_layout(panel.layout || %{}, position),
      refresh_interval_seconds: panel.refresh_interval_seconds || 0,
      position: position,
      metadata: panel.metadata || %{}
    }
  end

  def selected_visual(value, compatible) do
    compatible = Enum.map(compatible || [:table], &to_string/1)
    value = to_string(value || "table")

    if value in compatible do
      value
    else
      List.first(compatible) || "table"
    end
  end

  def default_binding_params(params, preview, _visual) do
    fields = preview_fields(preview)

    defaults =
      %{}
      |> maybe_default("value_field", SourceQueries.first_field_of_type(fields, :number))
      |> maybe_default("numerator_field", SourceQueries.availability_numerator_field(fields))
      |> maybe_default("denominator_field", SourceQueries.field_named(fields, "total"))
      |> maybe_default(
        "label_field",
        SourceQueries.availability_label_field(fields) || SourceQueries.first_field_of_type(fields, :string)
      )
      |> maybe_default("row_field", SourceQueries.first_field_of_type(fields, :string))
      |> maybe_default(
        "column_field",
        SourceQueries.availability_label_field(fields) ||
          SourceQueries.status_field(fields) || SourceQueries.first_field_of_type(fields, :string)
      )
      |> maybe_default("time_field", SourceQueries.first_field_of_type(fields, :datetime))
      |> maybe_default("status_field", SourceQueries.status_field(fields))
      |> maybe_default("aggregate", "sum")
      |> maybe_default("empty_value", "0")

    Map.merge(params, defaults, fn _key, current, default -> if current in [nil, ""], do: default, else: current end)
  end

  def preview_flash(visual, visual), do: "Panel query preview loaded"

  def preview_flash(requested, fallback) do
    "Panel query preview loaded; switched from #{SourceQueries.humanize_field(requested)} to #{SourceQueries.humanize_field(fallback)} " <>
      "because this query does not support the selected visualization."
  end

  def preview_from_result({:ok, preview}, _panel) when is_map(preview), do: preview
  def preview_from_result(_result, panel), do: preview_from_metadata(panel)

  def compatible_visuals(nil), do: []

  def compatible_visuals(panel) do
    panel
    |> Map.get(:field_metadata, %{})
    |> case do
      %{"compatible_visuals" => visuals} when is_list(visuals) -> Enum.map(visuals, &SourceQueries.visual_atom/1)
      %{compatible_visuals: visuals} when is_list(visuals) -> Enum.map(visuals, &SourceQueries.visual_atom/1)
      _ -> []
    end
  end

  defp preview_from_metadata(nil), do: nil

  defp preview_from_metadata(panel) do
    metadata = panel.field_metadata || %{}

    %{
      fields: metadata_fields(metadata),
      compatible_visuals: compatible_visuals(panel),
      rows: [],
      row_count: 0
    }
  end

  defp dataset_key(params) do
    params["dataset_key"]
    |> to_string()
    |> String.trim()
    |> case do
      "" -> generated_dataset_key(params)
      value -> value
    end
  end

  defp generated_dataset_key(params) do
    seed = Enum.join([params["title"], params["srql_query"], params["visual_type"]], ":")

    hash =
      :sha256
      |> :crypto.hash(seed)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 10)

    "panel_#{hash}"
  end

  defp data_binding(params, dataset_key) do
    [
      "value_field",
      "numerator_field",
      "denominator_field",
      "label_field",
      "row_field",
      "column_field",
      "time_field",
      "status_field",
      "aggregate",
      "empty_value"
    ]
    |> Enum.reduce(%{}, fn key, acc -> put_present(acc, key, params[key]) end)
    |> Map.put("dataset", dataset_key)
  end

  defp display_config(params) do
    %{}
    |> put_present("label", params["display_label"])
    |> put_present("unit", params["unit"])
    |> put_present("caption", params["caption"])
    |> put_capacity_forecast(params["capacity_forecast_mode"])
    |> put_table_columns(params["table_columns"])
  end

  defp visual_config(params) do
    %{}
    |> put_present("trend_mode", params["trend_mode"])
    |> put_present("trend_lookback_days", params["trend_lookback_days"])
    |> put_present("trend_query", params["trend_query"])
  end

  defp layout(params) do
    %{
      "x" => integer_value(params["layout_x"], 0),
      "y" => integer_value(params["layout_y"], 0),
      "w" => integer_value(params["layout_w"], 12),
      "h" => integer_value(params["layout_h"], 8)
    }
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_capacity_forecast(map, value) when value in ["capacity_forecast", "true", true] do
    Map.put(map, "capacity_forecast", true)
  end

  defp put_capacity_forecast(map, _value), do: map

  defp capacity_forecast_mode(%{"capacity_forecast" => value}) when value in [true, "true", "capacity_forecast"] do
    "capacity_forecast"
  end

  defp capacity_forecast_mode(%{capacity_forecast: value}) when value in [true, "true", "capacity_forecast"] do
    "capacity_forecast"
  end

  defp capacity_forecast_mode(_display), do: ""

  defp put_table_columns(map, value) when is_binary(value) do
    columns =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn field ->
        %{"field" => field, "label" => SourceQueries.humanize_field(field), "renderer" => "text", "visible" => true}
      end)

    if columns == [], do: map, else: Map.put(map, "table_columns", columns)
  end

  defp put_table_columns(map, _value), do: map

  defp map_value(map, key, default \\ "")

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  defp map_value(_map, _key, default), do: default

  defp table_columns_text(columns) when is_list(columns) do
    columns
    |> Enum.filter(&is_map/1)
    |> Enum.map(&(Map.get(&1, "field") || Map.get(&1, :field)))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp table_columns_text(_columns), do: ""

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default

  defp unique_dataset_key(base, panels) do
    existing = MapSet.new(Enum.map(panels, &(&1.dataset_key || "")))
    root = base |> to_string() |> String.replace(~r/[^a-zA-Z0-9_]+/, "_") |> String.trim("_")
    root = if root == "", do: "panel", else: root

    1
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "#{root}_copy_#{index}"
      if MapSet.member?(existing, candidate), do: nil, else: candidate
    end)
  end

  defp next_panel_layout(layout, position) do
    width = layout |> Map.get("w", 4) |> LayoutHelpers.bounded_integer(1, 12)
    height = layout |> Map.get("h", 4) |> LayoutHelpers.bounded_integer(2, 16)
    x = rem(position * width, 12)
    y = div(position * width, 12) * height

    %{"x" => x, "y" => y, "w" => width, "h" => height, "order" => position}
  end

  defp maybe_default(map, _key, nil), do: map
  defp maybe_default(map, key, value), do: Map.put(map, key, value)

  defp preview_fields(%{fields: fields}) when is_list(fields), do: fields
  defp preview_fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp preview_fields(_preview), do: []

  defp metadata_fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp metadata_fields(%{fields: fields}) when is_list(fields), do: fields
  defp metadata_fields(_metadata), do: []
end

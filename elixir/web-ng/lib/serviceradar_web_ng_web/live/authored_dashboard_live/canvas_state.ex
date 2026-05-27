defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.CanvasState do
  @moduledoc false

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.LayoutHelpers
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueries

  def visual_options do
    Enum.map(Dashboards.authored_visual_options(), fn option ->
      %{
        type: to_string(option.type),
        label: option.label
      }
    end)
  end

  def panels(nil, _panel_results), do: []

  def panels(%{panels: panels}, panel_results) do
    panels
    |> List.wrap()
    |> Enum.map(fn panel ->
      layout = panel.layout || %{}

      %{
        id: panel.id,
        dataset_key: panel.dataset_key || "primary",
        title: panel.title || "Panel",
        srql_query: panel.srql_query || "",
        visual_type: to_string(panel.visual_type || :table),
        data_binding: panel.data_binding || %{},
        display_config: panel.display_config || %{},
        visual_config: panel.visual_config || %{},
        field_metadata: field_metadata(panel.field_metadata || %{}),
        layout: layout,
        refresh_interval_seconds: panel.refresh_interval_seconds || 0,
        preview: panel_preview(Map.get(panel_results || %{}, panel.id), panel)
      }
    end)
  end

  def panels(_dashboard, _panel_results), do: []

  def selected_panel_id(id, %{panels: panels}) when is_binary(id) and id != "new" do
    if Enum.any?(panels || [], &(&1.id == id)), do: id, else: ""
  end

  def selected_panel_id(_id, _dashboard), do: ""

  def editing_panel(%{panels: panels}, id) when is_binary(id) and id != "new" do
    Enum.find(panels || [], &(&1.id == id))
  end

  def editing_panel(_dashboard, _id), do: nil

  def visual_type(value) do
    supported = MapSet.new(Dashboards.authored_visual_options(), &to_string(&1.type))

    value = to_string(value || "table")
    if MapSet.member?(supported, value), do: value, else: "table"
  end

  def new_panel_layout(visual_type, panels) do
    width = default_width(visual_type)
    height = default_height(visual_type)
    position = length(panels || [])

    %{"w" => width, "h" => height}
    |> next_panel_layout(position)
    |> Map.put("order", position)
  end

  def update_panel_layouts(scope, panels, layouts) do
    layout_index = layout_index(layouts)

    result =
      Enum.reduce_while(panels || [], {:ok, []}, fn panel, {:ok, updated} ->
        case Map.get(layout_index, panel.id) do
          nil ->
            {:cont, {:ok, updated ++ [panel]}}

          %{layout: layout, position: position} ->
            attrs = %{layout: Map.merge(panel.layout || %{}, layout), position: position}

            case Dashboards.update_authored_panel(scope, panel, attrs) do
              {:ok, panel} -> {:cont, {:ok, updated ++ [panel]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)

    case result do
      {:ok, panels} -> {:ok, Enum.sort_by(panels, &{&1.position, &1.inserted_at})}
      error -> error
    end
  end

  def compact_panel_layouts(scope, panels) do
    panels =
      Enum.sort_by(
        panels || [],
        &{&1.position, Map.get(&1.layout || %{}, "y", 0), Map.get(&1.layout || %{}, "x", 0)}
      )

    indexed_panels = Enum.with_index(panels)

    layouts =
      indexed_panels
      |> Map.new(fn {panel, index} -> {panel.id, compact_layout(panel, index)} end)
      |> LayoutHelpers.fill_final_orphan_layout(panels)

    Enum.reduce_while(indexed_panels, {:ok, []}, fn {panel, index}, {:ok, updated} ->
      layout = layouts |> Map.fetch!(panel.id) |> Map.put("order", index)

      case Dashboards.update_authored_panel(scope, panel, %{layout: layout, position: index}) do
        {:ok, panel} -> {:cont, {:ok, updated ++ [panel]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp field_metadata(metadata) do
    %{
      fields: fields(metadata_fields(metadata)),
      compatible_visuals: Enum.map(compatible_visuals(metadata), &to_string/1)
    }
  end

  defp panel_preview({:ok, preview}, _panel) when is_map(preview) do
    %{
      fields: fields(preview_fields(preview)),
      rows: preview |> preview_rows() |> Enum.take(25),
      compatible_visuals: preview |> preview_compatible_visuals() |> Enum.map(&to_string/1)
    }
  end

  defp panel_preview(_result, panel) do
    %{
      fields: fields(metadata_fields(panel.field_metadata || %{})),
      rows: [],
      compatible_visuals: panel.field_metadata |> compatible_visuals() |> Enum.map(&to_string/1)
    }
  end

  defp fields(fields) do
    Enum.map(fields || [], fn field ->
      %{
        name: SourceQueries.field_name(field),
        type: field |> SourceQueries.field_type() |> to_string(),
        sample: field_sample(field)
      }
    end)
  end

  defp preview_rows(%{rows: rows}) when is_list(rows), do: rows
  defp preview_rows(%{"rows" => rows}) when is_list(rows), do: rows
  defp preview_rows(_preview), do: []

  defp preview_fields(%{fields: fields}) when is_list(fields), do: fields
  defp preview_fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp preview_fields(_preview), do: []

  defp preview_compatible_visuals(%{compatible_visuals: visuals}) when is_list(visuals),
    do: Enum.map(visuals, &SourceQueries.visual_atom/1)

  defp preview_compatible_visuals(%{"compatible_visuals" => visuals}) when is_list(visuals),
    do: Enum.map(visuals, &SourceQueries.visual_atom/1)

  defp preview_compatible_visuals(_preview), do: []

  defp field_sample(%{sample: sample}), do: sample
  defp field_sample(%{"sample" => sample}), do: sample
  defp field_sample(_field), do: nil

  defp metadata_fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp metadata_fields(%{fields: fields}) when is_list(fields), do: fields
  defp metadata_fields(_metadata), do: []

  defp compatible_visuals(%{"compatible_visuals" => visuals}) when is_list(visuals),
    do: Enum.map(visuals, &SourceQueries.visual_atom/1)

  defp compatible_visuals(%{compatible_visuals: visuals}) when is_list(visuals),
    do: Enum.map(visuals, &SourceQueries.visual_atom/1)

  defp compatible_visuals(_metadata), do: []

  defp default_width(visual_type) when visual_type in ["table", "pivot", "line", "area"], do: 12
  defp default_width("status_list"), do: 8
  defp default_width(_visual_type), do: 4

  defp default_height(visual_type) when visual_type in ["table", "pivot"], do: 8
  defp default_height(visual_type) when visual_type in ["line", "area", "bar", "category"], do: 6
  defp default_height(_visual_type), do: 4

  defp next_panel_layout(layout, position) do
    row = div(position, 3)
    column = rem(position, 3)

    layout
    |> Map.put_new("x", column * 4)
    |> Map.put_new("y", row * 4)
  end

  defp compact_layout(panel, index) do
    layout = panel.layout || %{}
    width = layout |> Map.get("w", 4) |> LayoutHelpers.bounded_integer(1, 12)
    height = layout |> Map.get("h", 4) |> LayoutHelpers.bounded_integer(2, 16)
    x = rem(index * width, 12)
    y = div(index * width, 12) * height

    Map.merge(layout, %{"x" => x, "y" => y, "w" => width, "h" => height, "order" => index})
  end

  defp layout_index(layouts) do
    layouts
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn layout ->
      %{
        id: to_string(layout["id"] || layout[:id] || ""),
        x: integer_value(layout["x"] || layout[:x], 0),
        y: integer_value(layout["y"] || layout[:y], 0),
        w: integer_value(layout["w"] || layout[:w], 12),
        h: integer_value(layout["h"] || layout[:h], 8)
      }
    end)
    |> Enum.reject(&(&1.id == ""))
    |> Enum.sort_by(&{&1.y, &1.x, &1.id})
    |> Enum.with_index()
    |> Map.new(fn {layout, index} ->
      {
        layout.id,
        %{
          position: index,
          layout: %{
            "x" => LayoutHelpers.bounded_integer(layout.x, 0, 11),
            "y" => LayoutHelpers.bounded_integer(layout.y, 0, 1_000),
            "w" => LayoutHelpers.bounded_integer(layout.w, 1, 12),
            "h" => LayoutHelpers.bounded_integer(layout.h, 2, 16),
            "order" => index
          }
        }
      }
    end)
  end

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default
end

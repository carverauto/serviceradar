defmodule ServiceRadarWebNG.Dashboards.Authored.Visuals do
  @moduledoc false

  alias ServiceRadarWebNG.Dashboards.Authored.VisualOptions

  @spec visual_options() :: [map()]
  def visual_options, do: VisualOptions.all()

  @spec visual_types() :: [atom()]
  def visual_types, do: VisualOptions.types()

  def normalize_rows(results) when is_list(results) do
    Enum.map(results, fn
      row when is_map(row) -> stringify_keys(row)
      value -> %{"value" => value}
    end)
  end

  def normalize_rows(_results), do: []

  @spec compatible_visuals([map()], [map()]) :: [atom()]
  def compatible_visuals(rows, fields) when is_list(rows) and is_list(fields) do
    field_types = MapSet.new(Enum.map(fields, & &1.type))

    [:table]
    |> maybe_add_visual(:stat, stat_compatible?(rows, fields))
    |> maybe_add_visual(:count, stat_compatible?(rows, fields))
    |> maybe_add_visual(:gauge, gauge_compatible?(rows, fields))
    |> maybe_add_visual(:availability, availability_compatible?(rows, fields))
    |> maybe_add_visual(
      :line,
      MapSet.member?(field_types, :datetime) and MapSet.member?(field_types, :number)
    )
    |> maybe_add_visual(
      :area,
      MapSet.member?(field_types, :datetime) and MapSet.member?(field_types, :number)
    )
    |> maybe_add_visual(:bar, MapSet.member?(field_types, :number) and not Enum.empty?(fields))
    |> maybe_add_visual(
      :category,
      MapSet.member?(field_types, :string) and MapSet.member?(field_types, :number)
    )
    |> maybe_add_visual(:status_list, status_compatible?(fields))
    |> maybe_add_visual(:pivot, pivot_compatible?(fields))
  end

  def compatible_visuals(_rows, _fields), do: [:table]

  @spec infer_fields([map()], map() | nil) :: [map()]
  def infer_fields(rows, viz \\ nil)

  def infer_fields(rows, viz) when is_list(rows) do
    viz_fields = fields_from_viz(viz, rows)

    row_fields =
      rows
      |> infer_fields_from_rows()
      |> Enum.reject(fn field -> Enum.any?(viz_fields, &(&1.name == field.name)) end)

    viz_fields ++ row_fields
  end

  def infer_fields(_rows, _viz), do: []

  def grouped_availability_binding?(binding, fields) do
    names = MapSet.new(Enum.map(fields, & &1.name))
    value_field = Map.get(binding, "value_field") || Map.get(binding, :value_field)
    label_field = Map.get(binding, "label_field") || Map.get(binding, :label_field)

    value_field in ["count", "total"] and
      label_field in ["is_available", "available", "availability"] and
      MapSet.member?(names, value_field) and
      MapSet.member?(names, label_field)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp pivot_compatible?(fields) do
    dimension_count = Enum.count(fields, &(&1.type in [:string, :boolean, :datetime]))
    has_numeric? = Enum.any?(fields, &(&1.type == :number))

    dimension_count >= 2 and has_numeric?
  end

  defp infer_fields_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      values = values_for(rows, name)
      type = infer_type(values)

      %{
        id: name,
        name: name,
        type: type,
        sample: Enum.find(values, &present?/1),
        json_paths: json_paths(values),
        aggregate_compatible: type == :number,
        compatible_aggregations: compatible_aggregations(type)
      }
    end)
  end

  defp fields_from_viz(%{"columns" => columns}, rows) when is_list(columns),
    do: Enum.map(columns, &field_from_viz_column(&1, rows))

  defp fields_from_viz(%{columns: columns}, rows) when is_list(columns),
    do: Enum.map(columns, &field_from_viz_column(&1, rows))

  defp fields_from_viz(_viz, _rows), do: []

  defp field_from_viz_column(column, rows) when is_map(column) do
    name = column |> fetch_value([:name, "name"]) |> to_string()
    type = column |> fetch_value([:type, "type"]) |> viz_type()
    values = values_for(rows, name)

    %{
      id: name,
      name: name,
      type: type,
      sample: Enum.find(values, &present?/1),
      json_paths: json_paths(values),
      aggregate_compatible: type == :number,
      compatible_aggregations: compatible_aggregations(type)
    }
  end

  defp viz_type(value) when is_atom(value), do: value |> Atom.to_string() |> viz_type()

  defp viz_type(value) when is_binary(value) do
    case value do
      "bool" -> :boolean
      "boolean" -> :boolean
      "float" -> :number
      "int" -> :number
      "integer" -> :number
      "timestamptz" -> :datetime
      "timestamp" -> :datetime
      "jsonb" -> :object
      "text_array" -> :array
      "int_array" -> :array
      _ -> :string
    end
  end

  defp viz_type(_value), do: :string

  defp json_paths(values) do
    values
    |> Enum.find(&(is_map(&1) and not is_struct(&1)))
    |> case do
      nil ->
        []

      value ->
        value
        |> flatten_json_paths()
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  defp flatten_json_paths(value, prefix \\ "")

  defp flatten_json_paths(value, prefix) when is_map(value) and not is_struct(value) do
    Enum.flat_map(value, fn {key, nested} ->
      path =
        [prefix, to_string(key)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(".")

      case nested do
        nested when is_map(nested) and not is_struct(nested) -> [path | flatten_json_paths(nested, path)]
        _ -> [path]
      end
    end)
  end

  defp flatten_json_paths(_value, _prefix), do: []

  defp compatible_aggregations(:number), do: ["avg", "min", "max", "sum", "count"]
  defp compatible_aggregations(:boolean), do: ["count"]
  defp compatible_aggregations(_type), do: []

  defp values_for(rows, name) do
    Enum.map(rows, fn row -> Map.get(row, name) end)
  end

  defp infer_type(values) do
    cond do
      Enum.any?(values, &datetime?/1) -> :datetime
      Enum.any?(values, &number?/1) -> :number
      Enum.any?(values, &boolean?/1) -> :boolean
      Enum.any?(values, &is_map/1) -> :object
      Enum.any?(values, &is_list/1) -> :list
      true -> :string
    end
  end

  defp datetime?(%DateTime{}), do: true
  defp datetime?(%NaiveDateTime{}), do: true

  defp datetime?(value) when is_binary(value) do
    match?({:ok, _, _}, DateTime.from_iso8601(value)) or
      match?({:ok, _}, NaiveDateTime.from_iso8601(value))
  end

  defp datetime?(_value), do: false

  defp number?(value) when is_integer(value) or is_float(value), do: true

  defp number?(value) when is_binary(value) do
    value = String.trim(value)

    value != "" and
      (match?({_number, ""}, Float.parse(value)) or match?({_number, ""}, Integer.parse(value)))
  end

  defp number?(_value), do: false

  defp boolean?(value) when is_boolean(value), do: true
  defp boolean?(_value), do: false

  defp stat_compatible?([row], fields) when is_map(row) do
    Enum.any?(fields, fn field -> field.type == :number end)
  end

  defp stat_compatible?(_rows, _fields), do: false

  defp status_compatible?(fields) do
    Enum.any?(fields, fn field ->
      field.name in ["status", "state", "health", "result", "severity", "severity_label"]
    end)
  end

  defp availability_compatible?(rows, fields) do
    names = MapSet.new(Enum.map(fields, & &1.name))

    explicit_availability? =
      length(rows) == 1 and
        MapSet.member?(names, "total") and
        (MapSet.member?(names, "ok") or MapSet.member?(names, "available"))

    grouped_availability? =
      MapSet.member?(names, "count") and
        (MapSet.member?(names, "is_available") or MapSet.member?(names, "available"))

    explicit_availability? or grouped_availability?
  end

  defp gauge_compatible?(rows, fields) do
    availability_compatible?(rows, fields) or
      (stat_compatible?(rows, fields) and Enum.any?(fields, &gauge_metric_field?/1))
  end

  defp gauge_metric_field?(%{type: :number, name: name}) when is_binary(name) do
    normalized = String.downcase(name)

    normalized in [
      "value",
      "total",
      "count",
      "current",
      "target",
      "ok",
      "available",
      "error",
      "errors",
      "warning",
      "critical",
      "unknown",
      "availability_pct"
    ] or String.ends_with?(normalized, "_pct") or String.ends_with?(normalized, "_percent")
  end

  defp gauge_metric_field?(_field), do: false

  defp maybe_add_visual(visuals, visual, true), do: visuals ++ [visual]
  defp maybe_add_visual(visuals, _visual, _compatible?), do: visuals

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key)}
      else
        {:cont, nil}
      end
    end)
  end

  defp present?(value), do: value not in [nil, ""]
end

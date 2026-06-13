defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueries do
  @moduledoc """
  Query-first authoring helpers for authored dashboards.

  Source queries are stored in dashboard metadata and referenced by panels
  through the source query id recorded in panel metadata.
  """

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.LayoutHelpers

  @source_key "source_queries"
  @templates_env "SERVICERADAR_DASHBOARD_SOURCE_TEMPLATES_JSON"

  def default_params do
    %{
      "name" => "Source query",
      "srql_query" => "",
      "title" => "",
      "display_label" => "",
      "unit" => "",
      "caption" => "",
      "lookback_days" => "30"
    }
  end

  def templates do
    generic_templates() ++ configured_templates()
  end

  def generic_templates do
    [
      %{
        key: "device_type_count",
        label: "Device count by type",
        query: "in:devices stats:count() as count by type limit:25",
        description: "Stats query for a category or bar panel."
      },
      %{
        key: "device_availability",
        label: "Device availability",
        query: "in:devices stats:count() as count by is_available limit:25",
        description: "Grouped availability query for gauge or availability panels."
      },
      %{
        key: "service_recent",
        label: "Recent service checks",
        query: "in:services time:last_1h sort:timestamp:desc limit:25",
        description: "Table source for current service state."
      },
      %{
        key: "cpu_bucket",
        label: "CPU trend buckets",
        query: "in:cpu time:last_24h bucket:5m stats:avg(usage_percent) as value by time",
        description: "Bucketed trend source for line or area panels."
      },
      %{
        key: "capacity_forecasts",
        label: "Capacity forecasts",
        query: "in:capacity_forecasts status:projected sort:forecasted_at:desc limit:100",
        description: "Projected capacity runway rows for the forecast chart overlay."
      }
    ]
  end

  def template_query(key) do
    templates()
    |> Enum.find(&(&1.key == key || to_string(&1.key) == to_string(key)))
    |> case do
      nil -> nil
      template -> template.query
    end
  end

  def source_queries(%{metadata: metadata, panels: panels}) do
    metadata
    |> source_queries()
    |> Enum.map(&Map.put(&1, :panel_count, source_panel_count(panels, &1.id)))
  end

  def source_queries(%{metadata: metadata}), do: source_queries(metadata)

  def source_queries(metadata) when is_map(metadata) do
    metadata
    |> Map.get(@source_key, [])
    |> case do
      sources when is_list(sources) ->
        sources
        |> Enum.filter(&stored_source?/1)
        |> Enum.map(&source_from_storage/1)

      _not_sources ->
        []
    end
  end

  def source_queries(_metadata), do: []

  def upsert_source_metadata(metadata, source) when is_map(metadata) and is_map(source) do
    sources =
      metadata
      |> source_queries()
      |> Enum.reject(&(&1.id == source.id))
      |> Kernel.++([source])

    Map.put(metadata, @source_key, Enum.map(sources, &source_for_storage/1))
  end

  def persist_source(scope, dashboard, source) do
    metadata = upsert_source_metadata(dashboard.metadata || %{}, source)

    case Dashboards.update_authored_dashboard(scope, dashboard, %{metadata: metadata}) do
      {:ok, updated_dashboard} -> {:ok, %{updated_dashboard | panels: dashboard.panels || []}}
      {:error, reason} -> {:error, reason}
    end
  end

  def find_source(dashboard, source_id) do
    dashboard
    |> source_queries()
    |> Enum.find(&(&1.id == source_id))
  end

  def source_params(nil), do: default_params()

  def source_params(source) do
    Map.merge(default_params(), %{
      "name" => source.name,
      "srql_query" => source.srql_query,
      "title" => "",
      "display_label" => "",
      "unit" => "",
      "caption" => "",
      "lookback_days" => "30"
    })
  end

  def remove_source(scope, dashboard, source_id) do
    metadata = remove_source_metadata(dashboard.metadata || %{}, source_id)

    case Dashboards.update_authored_dashboard(scope, dashboard, %{metadata: metadata}) do
      {:ok, updated_dashboard} -> {:ok, %{updated_dashboard | panels: dashboard.panels || []}}
      {:error, reason} -> {:error, reason}
    end
  end

  def source_from_preview(params, preview) when is_map(params) and is_map(preview) do
    query = params |> Map.get("srql_query", "") |> String.trim()
    name = params |> Map.get("name", "") |> String.trim()

    %{
      id: source_id(query),
      name: if(name == "", do: "Source query", else: name),
      srql_query: query,
      fields: preview_fields(preview),
      sample_rows: preview |> preview_rows() |> Enum.take(10),
      compatible_visuals: preview |> compatible_visuals() |> Enum.map(&to_string/1),
      outputs: outputs_for_preview(preview),
      updated_at: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  def outputs_for_preview(preview) when is_map(preview) do
    fields = preview_fields(preview)

    preview
    |> compatible_visuals()
    |> Enum.reject(&(&1 == :table and Enum.empty?(fields)))
    |> Enum.map(&output_for_visual(&1, fields))
  end

  def outputs_for_preview(_preview), do: []

  def panel_attrs_from_output(dashboard, source, visual_type, params) do
    visual = visual_atom(visual_type)
    fields = Map.get(source, :fields, [])
    position = length(dashboard.panels || [])
    output_id = "#{source.id}:#{visual}"

    %{
      dashboard_id: dashboard.id,
      dataset_key: "source_#{source.id}",
      title: panel_title(source, visual, params),
      srql_query: source.srql_query,
      visual_type: visual,
      data_binding: binding_for_visual(visual, fields),
      display_config: display_config_for_visual(visual, source, params),
      visual_config: visual_config_for_visual(visual, source, params),
      builder_state: %{
        "mode" => "query_first",
        "source_query_id" => source.id,
        "output_id" => output_id,
        "intent" => intent_for_visual(visual)
      },
      metadata: %{
        "source_query_id" => source.id,
        "source_query_name" => source.name,
        "output_id" => output_id,
        "output_intent" => intent_for_visual(visual)
      },
      layout:
        visual
        |> to_string()
        |> default_layout(position),
      position: position
    }
  end

  def field_options(fields) do
    Enum.map(fields || [], &{field_label(&1), field_name(&1)})
  end

  def numeric_field_options(fields) do
    fields
    |> Enum.filter(&(field_type(&1) == :number))
    |> field_options()
  end

  def dimension_field_options(fields) do
    fields
    |> Enum.filter(&(field_type(&1) in [:string, :boolean, :datetime]))
    |> field_options()
  end

  def datetime_field_options(fields) do
    fields
    |> Enum.filter(&(field_type(&1) == :datetime))
    |> field_options()
  end

  def compatible_visual_options(preview, panel) do
    compatible =
      preview
      |> compatible_visuals()
      |> case do
        [] -> panel_compatible_visuals(panel)
        visuals -> visuals
      end

    compatible = if compatible == [], do: [:table], else: compatible

    Dashboards.authored_visual_options()
    |> Enum.filter(&(&1.type in compatible))
    |> Enum.map(&{&1.label, to_string(&1.type)})
  end

  def all_visual_options do
    Enum.map(Dashboards.authored_visual_options(), &{&1.label, to_string(&1.type)})
  end

  def preview_fields(%{fields: fields}) when is_list(fields), do: fields
  def preview_fields(%{"fields" => fields}) when is_list(fields), do: fields
  def preview_fields(_preview), do: []

  def preview_rows(%{rows: rows}) when is_list(rows), do: rows
  def preview_rows(%{"rows" => rows}) when is_list(rows), do: rows
  def preview_rows(_preview), do: []

  def compatible_visuals(%{compatible_visuals: visuals}) when is_list(visuals), do: Enum.map(visuals, &visual_atom/1)

  def compatible_visuals(%{"compatible_visuals" => visuals}) when is_list(visuals), do: Enum.map(visuals, &visual_atom/1)

  def compatible_visuals(_preview), do: []

  def panel_compatible_visuals(nil), do: []

  def panel_compatible_visuals(panel) do
    panel
    |> Map.get(:field_metadata, %{})
    |> case do
      %{"compatible_visuals" => visuals} when is_list(visuals) -> Enum.map(visuals, &visual_atom/1)
      %{compatible_visuals: visuals} when is_list(visuals) -> Enum.map(visuals, &visual_atom/1)
      _ -> []
    end
  end

  def metadata_fields(%{"fields" => fields}) when is_list(fields), do: fields
  def metadata_fields(%{fields: fields}) when is_list(fields), do: fields
  def metadata_fields(_metadata), do: []

  def visual_atom(value) when is_atom(value), do: value
  def visual_atom("table"), do: :table
  def visual_atom("stat"), do: :stat
  def visual_atom("count"), do: :count
  def visual_atom("gauge"), do: :gauge
  def visual_atom("availability"), do: :availability
  def visual_atom("line"), do: :line
  def visual_atom("area"), do: :area
  def visual_atom("bar"), do: :bar
  def visual_atom("category"), do: :category
  def visual_atom("status_list"), do: :status_list
  def visual_atom("pivot"), do: :pivot
  def visual_atom(_value), do: :table

  def field_label(field), do: "#{humanize_field(field_name(field))} (#{field_type(field)})"

  def field_name(%{name: name}), do: to_string(name)
  def field_name(%{"name" => name}), do: to_string(name)
  def field_name(field) when is_binary(field), do: field
  def field_name(_field), do: ""

  def field_type(%{type: type}) when is_atom(type), do: type
  def field_type(%{type: type}) when is_binary(type), do: field_type(type)
  def field_type(%{"type" => type}) when is_binary(type), do: field_type(type)
  def field_type("number"), do: :number
  def field_type("datetime"), do: :datetime
  def field_type("boolean"), do: :boolean
  def field_type("object"), do: :object
  def field_type("array"), do: :array
  def field_type("string"), do: :string
  def field_type(_field), do: :string

  def humanize_field(nil), do: ""

  def humanize_field(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def first_field_of_type(fields, type) do
    fields
    |> Enum.find(&(field_type(&1) == type))
    |> then(&(&1 && field_name(&1)))
  end

  def field_named(fields, name) do
    fields
    |> Enum.find(&(field_name(&1) == name))
    |> then(&(&1 && field_name(&1)))
  end

  def status_field(fields) do
    Enum.find_value(["status", "state", "health", "is_available", "available"], &field_named(fields, &1))
  end

  def availability_label_field(fields) do
    Enum.find_value(["is_available", "available", "availability"], &field_named(fields, &1))
  end

  def availability_numerator_field(fields), do: field_named(fields, "ok") || field_named(fields, "available")

  defp configured_templates do
    @templates_env
    |> System.get_env("")
    |> String.trim()
    |> case do
      "" ->
        []

      encoded ->
        case Jason.decode(encoded) do
          {:ok, templates} when is_list(templates) ->
            templates
            |> Enum.filter(&configured_template?/1)
            |> Enum.map(&template_from_config/1)

          _invalid ->
            []
        end
    end
  end

  defp configured_template?(template) when is_map(template) do
    is_binary(template["key"]) and is_binary(template["label"]) and is_binary(template["query"])
  end

  defp configured_template?(_template), do: false

  defp template_from_config(template) do
    %{
      key: template["key"],
      label: template["label"],
      query: template["query"],
      description: template["description"] || "Configured dashboard source query template."
    }
  end

  defp stored_source?(source) when is_map(source) do
    is_binary(source["id"]) and is_binary(source["name"]) and is_binary(source["srql_query"]) and
      is_list(source["fields"]) and is_list(source["compatible_visuals"]) and is_list(source["outputs"])
  end

  defp stored_source?(_source), do: false

  defp source_from_storage(source) do
    %{
      id: source["id"],
      name: source["name"],
      srql_query: source["srql_query"],
      fields: source["fields"],
      sample_rows: source["sample_rows"] || [],
      compatible_visuals: source["compatible_visuals"],
      outputs: source["outputs"],
      updated_at: source["updated_at"],
      panel_count: 0
    }
  end

  defp source_for_storage(source) do
    %{
      "id" => source.id,
      "name" => source.name,
      "srql_query" => source.srql_query,
      "fields" => source.fields,
      "sample_rows" => source.sample_rows,
      "compatible_visuals" => source.compatible_visuals,
      "outputs" => source.outputs,
      "updated_at" => source.updated_at
    }
  end

  defp remove_source_metadata(metadata, source_id) do
    sources =
      metadata
      |> source_queries()
      |> Enum.reject(&(&1.id == source_id))
      |> Enum.map(&source_for_storage/1)

    Map.put(metadata, @source_key, sources)
  end

  defp source_panel_count(panels, source_id) do
    panels
    |> List.wrap()
    |> Enum.count(fn
      %{metadata: %{"source_query_id" => ^source_id}} -> true
      _panel -> false
    end)
  end

  defp source_id(query) do
    hash =
      :sha256
      |> :crypto.hash(query)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 10)

    "src_#{hash}"
  end

  defp output_for_visual(visual, fields) do
    binding = binding_for_visual(visual, fields)

    %{
      "id" => "output_#{visual}",
      "visual_type" => to_string(visual),
      "intent" => intent_for_visual(visual),
      "label" => output_label(visual),
      "description" => output_description(visual),
      "summary" => output_summary(visual, fields, binding),
      "default_binding" => binding
    }
  end

  defp intent_for_visual(:stat), do: "single_number"
  defp intent_for_visual(:count), do: "single_number"
  defp intent_for_visual(:gauge), do: "bounded_metric"
  defp intent_for_visual(:availability), do: "availability_ratio"
  defp intent_for_visual(:line), do: "trend_over_time"
  defp intent_for_visual(:area), do: "trend_over_time"
  defp intent_for_visual(:bar), do: "ranked_breakdown"
  defp intent_for_visual(:category), do: "category_breakdown"
  defp intent_for_visual(:status_list), do: "status_grid"
  defp intent_for_visual(:pivot), do: "pivot_table"
  defp intent_for_visual(:table), do: "detail_rows"
  defp intent_for_visual(_visual), do: "detail_rows"

  defp output_label(visual) do
    visual
    |> intent_for_visual()
    |> humanize_field()
  end

  defp output_description(:pivot), do: "Cross-tab table using two dimensions and one numeric measure."
  defp output_description(:availability), do: "Availability ratio from explicit or grouped count fields."
  defp output_description(:gauge), do: "Bounded metric with optional lookback comparison."
  defp output_description(:count), do: "Single count or numeric KPI with optional lookback comparison."
  defp output_description(:line), do: "Time-based trend from datetime and numeric fields."
  defp output_description(:area), do: "Filled time-based trend from datetime and numeric fields."
  defp output_description(:bar), do: "Ranked numeric comparison."
  defp output_description(:category), do: "Categorical numeric breakdown."
  defp output_description(:status_list), do: "Operational status rows."
  defp output_description(:stat), do: "Single numeric value."
  defp output_description(:table), do: "Raw rows and columns."
  defp output_description(_visual), do: "Rows and fields from this source query."

  defp output_summary(visual, fields, binding) when visual in [:availability, :gauge] do
    cond do
      binding["value_field"] && binding["label_field"] ->
        "Count grouped by #{summary_field(binding["label_field"])}"

      binding["numerator_field"] && binding["denominator_field"] ->
        "#{summary_field(binding["numerator_field"])} divided by #{summary_field(binding["denominator_field"])}"

      binding["value_field"] ->
        "Value from #{summary_field(binding["value_field"])}"

      true ->
        "#{length(fields)} returned fields"
    end
  end

  defp output_summary(:pivot, _fields, binding) do
    [
      {"Rows", summarize_optional_field(binding["row_field"])},
      {"Columns", summarize_optional_field(binding["column_field"])},
      {"Values", aggregate_summary(binding)}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
    |> Enum.map_join(" | ", fn {label, value} -> "#{label}: #{value}" end)
  end

  defp output_summary(visual, _fields, binding) when visual in [:line, :area] do
    output_binding_summary([
      {"Time", binding["time_field"]},
      {"Value", binding["value_field"]},
      {"Series", binding["label_field"]}
    ])
  end

  defp output_summary(visual, _fields, binding) when visual in [:bar, :category] do
    output_binding_summary([{"Labels", binding["label_field"]}, {"Values", binding["value_field"]}])
  end

  defp output_summary(:status_list, _fields, binding) do
    output_binding_summary([
      {"Labels", binding["label_field"]},
      {"Status", binding["status_field"]},
      {"Values", binding["value_field"]}
    ])
  end

  defp output_summary(visual, fields, binding) when visual in [:stat, :count] do
    if binding["value_field"] do
      "Value from #{summary_field(binding["value_field"])}"
    else
      "#{length(fields)} returned fields"
    end
  end

  defp output_summary(:table, fields, _binding), do: "#{length(fields)} returned fields"
  defp output_summary(_visual, fields, _binding), do: "#{length(fields)} returned fields"

  defp output_binding_summary(parts) do
    parts
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
    |> Enum.map_join(" | ", fn {label, value} -> "#{label}: #{summary_field(value)}" end)
  end

  defp aggregate_summary(binding) do
    value = binding["value_field"]
    aggregate = binding["aggregate"] || "sum"

    if value in [nil, ""] do
      nil
    else
      "#{aggregate} #{summary_field(value)}"
    end
  end

  defp summarize_optional_field(value) when value in [nil, ""], do: nil
  defp summarize_optional_field(value), do: summary_field(value)

  defp summary_field(value), do: value |> humanize_field() |> String.downcase()

  defp binding_for_visual(:availability, fields) do
    if field_named(fields, "count") && availability_label_field(fields) do
      %{
        "value_field" => field_named(fields, "count"),
        "label_field" => availability_label_field(fields),
        "dataset" => "source"
      }
    else
      %{
        "numerator_field" => availability_numerator_field(fields) || first_field_of_type(fields, :number),
        "denominator_field" => field_named(fields, "total"),
        "label_field" => first_field_of_type(fields, :string),
        "dataset" => "source"
      }
    end
  end

  defp binding_for_visual(:gauge, fields) do
    cond do
      field_named(fields, "count") && availability_label_field(fields) ->
        %{
          "value_field" => field_named(fields, "count"),
          "label_field" => availability_label_field(fields),
          "dataset" => "source"
        }

      availability_numerator_field(fields) && field_named(fields, "total") ->
        %{
          "numerator_field" => availability_numerator_field(fields),
          "denominator_field" => field_named(fields, "total"),
          "label_field" => first_field_of_type(fields, :string),
          "dataset" => "source"
        }

      true ->
        %{
          "value_field" => first_field_of_type(fields, :number),
          "label_field" => first_field_of_type(fields, :string),
          "dataset" => "source"
        }
    end
  end

  defp binding_for_visual(:pivot, fields) do
    %{
      "row_field" => first_field_of_type(fields, :string),
      "column_field" => status_field(fields) || second_dimension_field(fields),
      "value_field" => first_field_of_type(fields, :number),
      "aggregate" => "sum",
      "empty_value" => "0",
      "dataset" => "source"
    }
  end

  defp binding_for_visual(visual, fields) when visual in [:line, :area] do
    if capacity_forecast_fields?(fields) do
      %{
        "time_field" => field_named(fields, "forecasted_at"),
        "value_field" => field_named(fields, "projected_value"),
        "label_field" => field_named(fields, "resource_label") || field_named(fields, "metric_name"),
        "dataset" => "source"
      }
    else
      %{
        "time_field" => first_field_of_type(fields, :datetime),
        "value_field" => first_field_of_type(fields, :number),
        "label_field" => first_field_of_type(fields, :string),
        "dataset" => "source"
      }
    end
  end

  defp binding_for_visual(visual, fields) when visual in [:bar, :category, :status_list] do
    %{
      "value_field" => first_field_of_type(fields, :number),
      "label_field" => first_field_of_type(fields, :string),
      "status_field" => status_field(fields),
      "dataset" => "source"
    }
  end

  defp binding_for_visual(_visual, fields) do
    %{
      "value_field" => first_field_of_type(fields, :number),
      "label_field" => first_field_of_type(fields, :string),
      "dataset" => "source"
    }
  end

  defp second_dimension_field(fields) do
    fields
    |> Enum.filter(&(field_type(&1) in [:string, :boolean, :datetime]))
    |> Enum.map(&field_name/1)
    |> Enum.at(1)
  end

  defp display_config_for_visual(visual, source, params) do
    %{}
    |> put_present("label", params["display_label"] || params["title"] || source.name)
    |> put_present("unit", params["unit"] || default_unit(visual))
    |> put_present("caption", params["caption"])
    |> put_capacity_forecast_display(visual, source)
  end

  defp visual_config_for_visual(visual, source, params) when visual in [:stat, :count, :gauge, :availability] do
    lookback = params["lookback_days"] || "30"

    %{
      "trend_mode" => "compare_previous",
      "trend_lookback_days" => lookback,
      "trend_query" => synthesize_trend_query(source.srql_query, lookback)
    }
  end

  defp visual_config_for_visual(_visual, _source, _params), do: %{}

  defp panel_title(source, visual, params) do
    title = params["title"] || ""

    if String.trim(title) == "" do
      "#{source.name} #{output_label(visual)}"
    else
      title
    end
  end

  defp default_unit(visual) when visual in [:gauge, :availability], do: "%"
  defp default_unit(_visual), do: ""

  defp put_capacity_forecast_display(map, visual, source) when visual in [:line, :area] do
    if capacity_forecast_source?(source) do
      Map.put(map, "capacity_forecast", true)
    else
      map
    end
  end

  defp put_capacity_forecast_display(map, _visual, _source), do: map

  defp capacity_forecast_source?(source) do
    fields? =
      source
      |> Map.get(:fields, [])
      |> capacity_forecast_fields?()

    query? =
      source
      |> Map.get(:srql_query, "")
      |> String.downcase()
      |> String.contains?("in:capacity_forecasts")

    fields? or query?
  end

  defp capacity_forecast_fields?(fields) do
    field_named(fields, "forecasted_at") != nil and field_named(fields, "projected_value") != nil and
      field_named(fields, "horizon_ends_at") != nil
  end

  defp default_layout(visual, position) do
    width = if visual in ["table", "pivot", "line", "area"], do: 12, else: 4
    height = if visual in ["table", "pivot"], do: 8, else: 4

    %{"w" => width, "h" => height}
    |> next_panel_layout(position)
    |> Map.put("order", position)
  end

  defp next_panel_layout(layout, position) do
    width = LayoutHelpers.bounded_integer(layout["w"], 1, 12)
    height = LayoutHelpers.bounded_integer(layout["h"], 2, 16)
    x = if width >= 12, do: 0, else: rem(position * width, 12)
    y = div(position * width, 12) * height

    Map.merge(layout, %{"x" => x, "y" => y, "w" => width, "h" => height})
  end

  defp synthesize_trend_query(query, lookback) do
    trend_time = "time:last_#{lookback}d"

    {tokens, replaced?} =
      query
      |> to_string()
      |> split_srql_tokens()
      |> Enum.map_reduce(false, fn
        token, false ->
          if time_token?(token), do: {trend_time, true}, else: {token, false}

        token, true ->
          {token, true}
      end)

    tokens =
      if replaced? do
        tokens
      else
        tokens ++ [trend_time]
      end

    Enum.join(tokens, " ")
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

  defp time_token?(token), do: String.starts_with?(token, "time:")

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:panel, :map, required: true)
  attr(:result, :any, default: nil)
  attr(:trend, :any, default: nil)
  attr(:style, :string, default: nil)
  attr(:expanded_srql?, :boolean, default: false)
  attr(:can_manage?, :boolean, default: false)
  attr(:csv_data_url, :string, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  def panel_result(%{result: {:ok, preview}} = assigns) do
    assigns =
      assigns
      |> assign(:rows, preview.rows)
      |> assign(:fields, preview.fields)

    ~H"""
    <article
      class="sr-authored-dashboard-panel rounded-lg border border-slate-800/80 bg-[#0f172a]/95 text-slate-100 shadow-xl shadow-cyan-950/20 backdrop-blur-md"
      style={@style}
    >
      <div class="flex shrink-0 flex-col gap-2 border-b border-slate-800/80 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="truncate text-sm font-semibold text-slate-100">{@panel.title}</h2>
            <.ui_badge :if={refresh_interval_label(@panel)} size="xs" variant="ghost">
              {refresh_interval_label(@panel)}
            </.ui_badge>
          </div>
          <p class="mt-1 truncate font-mono text-xs text-slate-400">{@panel.srql_query}</p>
        </div>
        <div class="flex shrink-0 flex-wrap items-center gap-1">
          <.ui_badge size="sm" variant="outline" class="border-cyan-500/30 text-cyan-300">
            {@panel.visual_type}
          </.ui_badge>
          <.panel_action_menu
            panel={@panel}
            expanded_srql?={@expanded_srql?}
            can_manage?={@can_manage?}
            csv_data_url={@csv_data_url}
          />
        </div>
      </div>
      <div
        :if={@expanded_srql?}
        class="shrink-0 border-b border-slate-800/80 bg-slate-950/60 px-4 py-3"
      >
        <pre class="overflow-x-auto whitespace-pre-wrap font-mono text-xs"><%= @panel.srql_query %></pre>
      </div>
      <div class="sr-authored-dashboard-panel-body p-4">
        <.render_visual
          panel={@panel}
          rows={@rows}
          fields={@fields}
          trend={@trend}
          timezone={@timezone}
        />
      </div>
    </article>
    """
  end

  def panel_result(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, format_value(reason))

    ~H"""
    <article
      class="sr-authored-dashboard-panel rounded-lg border border-error/30 bg-[#0f172a]/95 text-slate-100"
      style={@style}
    >
      <div class="flex shrink-0 flex-col gap-2 border-b border-error/20 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <h2 class="text-sm font-semibold">{@panel.title}</h2>
        <div class="flex shrink-0 flex-wrap items-center gap-1">
          <.panel_action_menu
            panel={@panel}
            expanded_srql?={@expanded_srql?}
            can_manage?={@can_manage?}
            csv_data_url={@csv_data_url}
          />
        </div>
      </div>
      <div
        :if={@expanded_srql?}
        class="shrink-0 border-b border-slate-800/80 bg-slate-950/60 px-4 py-3"
      >
        <pre class="overflow-x-auto whitespace-pre-wrap font-mono text-xs"><%= @panel.srql_query %></pre>
      </div>
      <div class="sr-authored-dashboard-panel-body p-4 text-sm text-error">
        Could not preview this query: {@message}
      </div>
    </article>
    """
  end

  def panel_result(assigns) do
    ~H"""
    <article
      class="sr-authored-dashboard-panel rounded-lg border border-slate-800/80 bg-[#0f172a]/95 p-4 text-sm text-slate-400"
      style={@style}
    >
      {@panel.title}
    </article>
    """
  end

  attr(:panel, :map, required: true)
  attr(:expanded_srql?, :boolean, default: false)
  attr(:can_manage?, :boolean, default: false)
  attr(:csv_data_url, :string, default: nil)

  def panel_action_menu(assigns) do
    ~H"""
    <.ui_dropdown align="end" menu_class="z-[80] w-52 max-w-52">
      <:trigger>
        <.ui_button
          type="button"
          aria-label={"Actions for #{@panel.title}"}
          title="Panel actions"
          size="xs"
          variant="ghost"
        >
          <.icon name="hero-ellipsis-vertical" class="size-4" />
        </.ui_button>
      </:trigger>
      <:item>
        <button type="button" phx-click="refresh_panel" phx-value-id={@panel.id}>
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </button>
      </:item>
      <:item>
        <button type="button" phx-click="toggle_panel_srql" phx-value-id={@panel.id}>
          <.icon name="hero-code-bracket-square" class="size-4" />
          {if @expanded_srql?, do: "Hide SRQL", else: "View SRQL"}
        </button>
      </:item>
      <:item :if={@can_manage?}>
        <button type="button" phx-click="edit_panel" phx-value-id={@panel.id}>
          <.icon name="hero-pencil-square" class="size-4" /> Open in Builder
        </button>
      </:item>
      <:item :if={@can_manage?}>
        <button type="button" phx-click="duplicate_panel" phx-value-id={@panel.id}>
          <.icon name="hero-document-duplicate" class="size-4" /> Duplicate
        </button>
      </:item>
      <:item :if={@csv_data_url}>
        <a href={@csv_data_url} download={"#{safe_filename(@panel.title)}.csv"}>
          <.icon name="hero-arrow-down-tray" class="size-4" /> Export CSV
        </a>
      </:item>
      <:item :if={@can_manage?}>
        <button
          type="button"
          class="text-error"
          phx-click="delete_panel"
          phx-value-id={@panel.id}
          data-confirm={"Delete panel \"#{@panel.title}\"?"}
        >
          <.icon name="hero-trash" class="size-4" /> Delete
        </button>
      </:item>
    </.ui_dropdown>
    """
  end

  attr(:panel, :map, required: true)
  attr(:rows, :list, default: [])
  attr(:fields, :list, default: [])
  attr(:trend, :any, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  def render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:stat, "stat", :count, "count"] do
    value =
      stat_value(assigns.rows, assigns.fields, assigns.panel)

    assigns =
      assigns
      |> assign(:raw_value, value)
      |> assign(:value, format_value(value))
      |> assign(
        :label,
        visual_label(assigns.panel, first_numeric_field(assigns.fields) || "value")
      )
      |> assign(:unit, display_value(assigns.panel, "unit", ""))
      |> assign(:trend_summary, trend_summary(assigns[:trend], assigns.panel))

    ~H"""
    <div
      class="flex h-full min-h-0 items-center"
      role="group"
      aria-labelledby={"authored-dashboard-panel-#{@panel.id}-stat-label authored-dashboard-panel-#{@panel.id}-stat-value"}
    >
      <div>
        <div
          id={"authored-dashboard-panel-#{@panel.id}-stat-value"}
          class="text-4xl font-semibold tracking-normal text-slate-100"
        >
          <.user_time
            :if={timestamp_value?(@raw_value)}
            id={"authored-dashboard-panel-#{@panel.id}-stat-time"}
            value={@raw_value}
            timezone={@timezone}
            style={:compact}
          />
          <span :if={not timestamp_value?(@raw_value)}>{@value}</span><span class="text-xl text-slate-400">{@unit}</span>
        </div>
        <div
          id={"authored-dashboard-panel-#{@panel.id}-stat-label"}
          class="mt-2 text-sm text-slate-400"
        >
          {@label}
        </div>
        <div :if={@trend_summary} class="mt-2 text-xs text-slate-500">
          {trend_summary_text(@trend_summary)}
        </div>
      </div>
    </div>
    """
  end

  def render_visual(%{panel: %{visual_type: type}} = assigns)
      when type in [:gauge, "gauge", :availability, "availability"] do
    assigns =
      assigns
      |> assign(:chart_panel, chart_panel(assigns.panel))
      |> assign(:chart_rows, chart_rows(assigns.rows))
      |> assign(:chart_fields, chart_fields(assigns.fields))
      |> assign(:trend_summary, trend_summary(assigns[:trend], assigns.panel))

    ~H"""
    <div class="flex h-full min-h-0 flex-col gap-2">
      <.dashboard_panel_chart
        id={"dashboard-panel-chart-#{@panel.id}"}
        panel={@chart_panel}
        rows={@chart_rows}
        fields={@chart_fields}
        trend={@trend_summary}
        timezone={@timezone}
      />
    </div>
    """
  end

  def render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:pivot, "pivot"] do
    assigns = assign(assigns, :pivot, pivot_data(assigns.rows, assigns.panel, assigns.fields))

    ~H"""
    <div class="flex h-full min-h-0 flex-col gap-2">
      <div class="shrink-0 text-sm font-medium text-slate-100">Pivot Table</div>
      <div class="min-h-0 flex-1 overflow-auto rounded-lg border border-slate-800/80">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr>
              <th>{@pivot.row_label}</th>
              <th :for={column <- @pivot.columns}>
                <.table_cell
                  value={column.value}
                  type={@pivot.column_type}
                  renderer="text"
                  id={"authored-dashboard-pivot-#{safe_dom_id(@panel.id)}-column-#{column.index}"}
                  timezone={@timezone}
                />
              </th>
              <th :if={@pivot.show_totals?}>Total</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @pivot.rows}>
              <th>
                <.table_cell
                  value={row.value}
                  type={@pivot.row_type}
                  renderer="text"
                  id={"authored-dashboard-pivot-#{safe_dom_id(@panel.id)}-row-#{row.index}"}
                  timezone={@timezone}
                />
              </th>
              <td :for={column <- @pivot.columns}>
                {Map.get(row.values, column.key, @pivot.empty_value)}
              </td>
              <td :if={@pivot.show_totals?}>{row.total}</td>
            </tr>
          </tbody>
        </table>
        <.empty_rows :if={@pivot.rows == []} />
      </div>
    </div>
    """
  end

  def render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:bar, "bar", :category, "category"] do
    assigns =
      assigns
      |> assign(:chart_panel, chart_panel(assigns.panel))
      |> assign(:chart_rows, chart_rows(assigns.rows))
      |> assign(:chart_fields, chart_fields(assigns.fields))

    ~H"""
    <.dashboard_panel_chart
      id={"dashboard-panel-chart-#{@panel.id}"}
      panel={@chart_panel}
      rows={@chart_rows}
      fields={@chart_fields}
      timezone={@timezone}
    />
    """
  end

  def render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:line, "line", :area, "area"] do
    assigns =
      assigns
      |> assign(:chart_panel, chart_panel(assigns.panel))
      |> assign(:chart_rows, chart_rows(assigns.rows))
      |> assign(:chart_fields, chart_fields(assigns.fields))

    ~H"""
    <.dashboard_panel_chart
      id={"dashboard-panel-chart-#{@panel.id}"}
      panel={@chart_panel}
      rows={@chart_rows}
      fields={@chart_fields}
      timezone={@timezone}
    />
    """
  end

  def render_visual(assigns) do
    assigns = assign(assigns, :columns, table_columns(assigns.panel, assigns.fields))

    ~H"""
    <div class="h-full min-h-0 overflow-auto rounded-lg border border-slate-800/80">
      <table class={ui_table_class(size: "sm")}>
        <thead>
          <tr>
            <th :for={column <- @columns}>{column.label}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{row, row_index} <- Enum.with_index(Enum.take(@rows, 100))}>
            <td :for={column <- @columns} class="max-w-64 truncate">
              <.table_cell
                id={"authored-dashboard-panel-#{@panel.id}-row-#{stable_row_id(row, row_index)}-#{safe_dom_id(column.field)}"}
                value={table_value(row, column)}
                type={column.type}
                renderer={column.renderer}
                timezone={@timezone}
              />
            </td>
          </tr>
        </tbody>
      </table>
      <.empty_rows :if={@rows == []} />
    </div>
    """
  end

  defp chart_panel(panel) do
    %{
      id: panel.id,
      title: panel.title || "Panel",
      srql_query: panel.srql_query || "",
      visual_type: to_string(panel.visual_type || :line),
      data_binding: panel.data_binding || %{},
      display_config: panel.display_config || %{},
      visual_config: panel.visual_config || %{}
    }
  end

  defp chart_rows(rows) do
    rows
    |> List.wrap()
    |> Enum.take(250)
    |> Enum.map(&chart_row/1)
  end

  defp chart_row(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {to_string(key), chart_value(value)} end)
  end

  defp chart_row(_row), do: %{}

  defp chart_fields(fields), do: Enum.map(fields, &canvas_field/1)

  defp chart_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp chart_value(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp chart_value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp chart_value(value) when is_list(value), do: Enum.map(value, &chart_value/1)

  defp chart_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), chart_value(nested_value)} end)
  end

  defp chart_value(value), do: format_value(value)

  defp canvas_field(field) do
    %{
      name: field_name(field),
      type: field_type(field),
      sample: Map.get(field, :sample) || Map.get(field, "sample")
    }
  end

  defp safe_filename(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "dashboard-panel"
      filename -> filename
    end
  end

  defp refresh_interval_label(%{refresh_interval_seconds: seconds}) when is_integer(seconds) and seconds > 0 do
    "Refresh #{format_duration(seconds)}"
  end

  defp refresh_interval_label(_panel), do: nil

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3_600)}h"

  defp empty_rows(assigns) do
    ~H"""
    <div class="flex min-h-24 items-center justify-center text-sm text-sr-muted">
      No rows returned.
    </div>
    """
  end

  attr(:value, :any, default: nil)
  attr(:type, :atom, default: :string)
  attr(:renderer, :string, default: "text")
  attr(:id, :string, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  defp table_cell(assigns) do
    assigns = assign(assigns, :cell, table_cell_value(assigns.value, assigns.renderer))

    ~H"""
    <.user_time
      :if={timestamp_value?(@value, @type)}
      id={@id}
      value={@value}
      timezone={@timezone}
      style={:compact}
    />
    <%= if not timestamp_value?(@value, @type) do %>
      <%= case @cell do %>
        <% {:status, text, tone} -> %>
          <.ui_badge size="sm" variant={status_badge_variant(tone)} title={text}>
            <.icon name={status_icon(tone)} class="size-3" /> {text}
          </.ui_badge>
        <% {:boolean, true} -> %>
          <.ui_badge size="sm" variant="success" title="true">
            <.icon name="hero-check" class="size-3" /> true
          </.ui_badge>
        <% {:boolean, false} -> %>
          <.ui_badge size="sm" variant="error" title="false">
            <.icon name="hero-x-mark" class="size-3" /> false
          </.ui_badge>
        <% {:sparkline, points, title} -> %>
          <svg
            viewBox="0 0 100 24"
            preserveAspectRatio="none"
            class="h-6 w-28 text-sr-brand"
            role="img"
            aria-label="sparkline"
          >
            <polyline points={points} fill="none" stroke="currentColor" stroke-width="2" />
          </svg>
          <span class="sr-only">{title}</span>
        <% {:json, summary, title} -> %>
          <span class="font-mono text-[11px]" title={title}>{summary}</span>
        <% {:text, text, title} -> %>
          <span title={title}>{text}</span>
      <% end %>
    <% end %>
    """
  end

  defp table_cell_value(value, renderer) when renderer in ["status", "status_icon", "icon"] do
    text = format_value(value)
    {:status, text, status_tone(value)}
  end

  defp table_cell_value(value, "sparkline") do
    case table_sparkline_points(value) do
      "" -> {:text, format_value(value), format_value(value)}
      points -> {:sparkline, points, format_value(value)}
    end
  end

  defp table_cell_value(value, "boolean_icon") when is_boolean(value), do: {:boolean, value}
  defp table_cell_value(value, _renderer) when is_boolean(value), do: {:boolean, value}

  defp table_cell_value(value, "json_summary") when is_map(value) or is_list(value) do
    {:json, json_summary(value), json_title(value)}
  end

  defp table_cell_value(value, _renderer) when is_map(value) or is_list(value) do
    {:json, json_summary(value), json_title(value)}
  end

  defp table_cell_value(value, _renderer) when is_binary(value) do
    case decode_json_cell(value) do
      {:ok, decoded} -> {:json, json_summary(decoded), json_title(decoded)}
      :error -> text_cell(value)
    end
  end

  defp table_cell_value(value, _renderer) do
    value |> format_value() |> text_cell()
  end

  defp text_cell(text), do: {:text, text, text}

  defp decode_json_cell(value) do
    value = String.trim(value)

    if String.starts_with?(value, ["{", "["]) do
      case Jason.decode(value) do
        {:ok, decoded} when is_map(decoded) or is_list(decoded) -> {:ok, decoded}
        _ -> :error
      end
    else
      :error
    end
  end

  defp json_summary(value) when is_map(value) do
    keys = value |> Map.keys() |> Enum.map(&to_string/1)

    case keys do
      [] ->
        "0 fields"

      keys ->
        visible = keys |> Enum.take(3) |> Enum.join(", ")
        extra = max(length(keys) - 3, 0)
        suffix = if extra > 0, do: " +#{extra}", else: ""
        "#{length(keys)} #{plural_label("field", length(keys))}: #{visible}#{suffix}"
    end
  end

  defp json_summary(value) when is_list(value), do: "#{length(value)} #{plural_label("item", length(value))}"

  defp plural_label(label, 1), do: label
  defp plural_label(label, _count), do: label <> "s"

  defp json_title(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      _ -> inspect(value)
    end
  end

  defp default_renderer(%{type: :boolean}), do: "boolean_icon"
  defp default_renderer(%{name: name}) when name in ["status", "state", "health", "availability"], do: "status"
  defp default_renderer(%{sample: sample}) when is_map(sample) or is_list(sample), do: "json_summary"
  defp default_renderer(_field), do: "text"

  defp table_columns(panel, fields) do
    configured =
      panel
      |> Map.get(:display_config, %{})
      |> Map.get("table_columns", [])

    columns =
      configured
      |> Enum.filter(&is_map/1)
      |> Enum.reject(&(&1["visible"] == false))
      |> Enum.map(fn column ->
        field = column["field"] || column[:field]

        %{
          field: field,
          path: column["path"] || column[:path],
          label: column["label"] || humanize_field(field),
          renderer: column["renderer"] || "text",
          type: field_type_for(fields, field)
        }
      end)
      |> Enum.reject(&is_nil(&1.field))

    case columns do
      [] ->
        Enum.map(fields, fn field ->
          %{
            field: field_name(field),
            path: nil,
            label: humanize_field(field_name(field)),
            renderer: default_renderer(canvas_field(field)),
            type: field_type(field)
          }
        end)

      columns ->
        columns
    end
  end

  defp table_value(row, %{field: field, path: path}) do
    value = Map.get(row, field)

    case path do
      path when is_binary(path) and path != "" -> value_at_path(value, path)
      _ -> value
    end
  end

  defp value_at_path(value, path) when is_map(value) and is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(value, fn key, acc ->
      case acc do
        map when is_map(map) -> Map.get(map, key)
        _ -> nil
      end
    end)
  rescue
    ArgumentError -> nil
  end

  defp value_at_path(value, _path), do: value

  defp stat_value(rows, _fields, panel) when is_list(rows) do
    binding = panel.data_binding || %{}
    value_field = binding["value_field"]
    aggregate = binding["aggregate"] || default_stat_aggregate(panel)

    values =
      rows
      |> Enum.map(fn row -> numeric(Map.get(row, value_field)) end)
      |> Enum.reject(&is_nil/1)

    cond do
      value_field in [nil, ""] -> first_numeric_value(rows)
      aggregate == "count" -> length(rows)
      values == [] -> first_numeric_value(rows)
      true -> aggregate_values(values, aggregate)
    end
  end

  defp stat_value(_rows, _fields, _panel), do: "No data"

  defp first_numeric_value([row | rows]) do
    row
    |> Map.values()
    |> Enum.find_value(fn value -> numeric(value) end)
    |> case do
      nil -> first_numeric_value(rows)
      value -> value
    end
  end

  defp first_numeric_value(_rows), do: nil

  defp default_stat_aggregate(%{visual_type: type}) when type in [:count, "count"], do: "count"
  defp default_stat_aggregate(_panel), do: "sum"

  defp pivot_data(rows, panel, fields) do
    binding = panel.data_binding || %{}
    row_field = binding["row_field"] || first_string_field(fields)
    column_field = binding["column_field"] || status_field(fields) || first_string_field(fields)
    value_field = binding["value_field"] || first_numeric_field(fields)
    aggregate = binding["aggregate"] || "sum"
    empty_value = binding["empty_value"] || "0"

    grouped = Enum.reduce(rows, %{}, &add_pivot_value(&1, &2, row_field, column_field, value_field))

    columns =
      grouped
      |> Map.values()
      |> Enum.reduce(%{}, fn row_group, acc ->
        Map.merge(acc, row_group.columns, fn _key, existing, _duplicate -> existing end)
      end)
      |> Enum.sort_by(fn {key, _column} -> key end)
      |> Enum.with_index()
      |> Enum.map(fn {{key, column}, index} ->
        %{key: key, value: column.value, index: index}
      end)

    pivot_rows =
      grouped
      |> Enum.sort_by(fn {key, _row_group} -> key end)
      |> Enum.with_index()
      |> Enum.map(fn {{_key, row_group}, index} ->
        values =
          Map.new(columns, fn column ->
            values = get_in(row_group, [:columns, column.key, :values]) || []
            {column.key, aggregate_values(values, aggregate)}
          end)

        %{
          value: row_group.value,
          index: index,
          values: values,
          total: aggregate_values(Map.values(values), "sum")
        }
      end)

    %{
      row_label: humanize_field(row_field || "row"),
      row_type: field_type_for(fields, row_field),
      column_type: field_type_for(fields, column_field),
      columns: columns,
      rows: pivot_rows,
      empty_value: empty_value,
      show_totals?: true
    }
  end

  defp add_pivot_value(row, acc, row_field, column_field, value_field) do
    row_value = Map.get(row, row_field)
    column_value = Map.get(row, column_field)
    row_key = format_value(row_value)
    column_key = format_value(column_value)
    value = numeric(Map.get(row, value_field)) || 0

    Map.update(
      acc,
      row_key,
      %{value: row_value, columns: %{column_key => %{value: column_value, values: [value]}}},
      fn row_group ->
        columns =
          Map.update(
            row_group.columns,
            column_key,
            %{value: column_value, values: [value]},
            &Map.update!(&1, :values, fn values -> [value | values] end)
          )

        %{row_group | columns: columns}
      end
    )
  end

  defp aggregate_values([], _aggregate), do: 0
  defp aggregate_values(values, "count"), do: length(values)
  defp aggregate_values(values, "avg"), do: Enum.sum(values) / max(length(values), 1)
  defp aggregate_values(values, "max"), do: Enum.max(values, fn -> 0 end)
  defp aggregate_values(values, "min"), do: Enum.min(values, fn -> 0 end)
  defp aggregate_values(values, _aggregate), do: Enum.sum(values)

  defp trend_summary({:ok, %{rows: rows, fields: fields}}, panel) do
    value_key = trend_value_field(fields)
    lookback_days = trend_lookback_days(panel)

    values =
      rows
      |> trend_ordered_rows(fields)
      |> Enum.map(fn row -> numeric(Map.get(row, value_key)) end)
      |> Enum.reject(&is_nil/1)

    case values do
      [first | rest] when rest != [] ->
        last = List.last(rest)
        delta = last - first
        percent_delta = if first == 0, do: nil, else: delta / first * 100

        %{
          "text" => "#{format_value(first)} -> #{format_value(last)} (#{signed_number(delta)})",
          "delta" => delta,
          "percent_delta" => percent_delta,
          "direction" => trend_direction(delta),
          "label" => trend_period_label(lookback_days)
        }

      [single] ->
        %{
          "text" => format_value(single),
          "delta" => 0,
          "percent_delta" => nil,
          "direction" => "flat",
          "label" => trend_period_label(lookback_days)
        }

      _ ->
        nil
    end
  end

  defp trend_summary(_trend, _panel), do: nil

  defp trend_ordered_rows(rows, fields) do
    case trend_time_field(fields) do
      nil -> rows
      time_key -> Enum.sort_by(rows, &datetime_sort_key(Map.get(&1, time_key)))
    end
  end

  defp trend_time_field(fields) do
    first_field_of_type(fields, :datetime) ||
      Enum.find_value(fields, fn field ->
        name = field_name(field)
        type = field_type(field)

        if trend_time_field_name?(name) and type in [:number, :integer, :datetime, :string] do
          name
        end
      end)
  end

  defp trend_value_field(fields) do
    Enum.find_value(fields, fn field ->
      name = field_name(field)
      if field_type(field) == :number and not trend_time_field_name?(name), do: name
    end) || first_numeric_field(fields)
  end

  defp trend_time_field_name?(name) when is_binary(name) do
    name in ["time", "timestamp", "bucket", "time_bucket", "bucket_start", "bucket_end"]
  end

  defp datetime_sort_key(%DateTime{} = value), do: {0, DateTime.to_unix(value, :microsecond)}
  defp datetime_sort_key(%NaiveDateTime{} = value), do: {0, NaiveDateTime.to_gregorian_seconds(value)}
  defp datetime_sort_key(%Date{} = value), do: {0, Date.to_gregorian_days(value)}
  defp datetime_sort_key(value) when is_number(value), do: {0, value}

  defp datetime_sort_key(value) when is_binary(value) do
    with {:error, _reason} <- DateTime.from_iso8601(value),
         {:error, _reason} <- NaiveDateTime.from_iso8601(value),
         {:ok, date} <- Date.from_iso8601(value) do
      datetime_sort_key(date)
    else
      {:ok, datetime, _offset} -> datetime_sort_key(datetime)
      {:ok, naive_datetime} -> datetime_sort_key(naive_datetime)
      {:error, _reason} -> {1, 0}
    end
  end

  defp datetime_sort_key(_value), do: {1, 0}

  defp trend_summary_text(%{"percent_delta" => percent_delta, "label" => label, "text" => text})
       when is_number(percent_delta) do
    "#{signed_percent(percent_delta)} #{label} (#{text})"
  end

  defp trend_summary_text(%{"label" => label, "text" => text}), do: "#{text} #{label}"
  defp trend_summary_text(value) when is_binary(value), do: value
  defp trend_summary_text(_value), do: nil

  defp signed_number(value) when is_number(value) and value >= 0, do: "+#{format_value(value)}"
  defp signed_number(value), do: format_value(value)

  defp signed_percent(value) when is_number(value) and value >= 0, do: "+#{format_percent(value)}"
  defp signed_percent(value), do: format_percent(value)

  defp format_percent(value) when is_float(value), do: "#{:erlang.float_to_binary(value, decimals: 1)}%"
  defp format_percent(value) when is_integer(value), do: "#{value}%"

  defp trend_direction(value) when is_number(value) and value > 0, do: "up"
  defp trend_direction(value) when is_number(value) and value < 0, do: "down"
  defp trend_direction(_value), do: "flat"

  defp trend_lookback_days(panel) do
    panel
    |> Map.get(:visual_config, %{})
    |> map_value("trend_lookback_days", 30)
    |> integer_value(30)
    |> bounded_integer(1, 365)
  end

  defp trend_period_label(1), do: "Compared to yesterday"
  defp trend_period_label(days), do: "Compared to #{days} days ago"

  defp visual_label(panel, fallback) do
    display_value(panel, "label", panel.title || fallback)
  end

  defp display_value(panel, key, fallback) do
    case panel.display_config || %{} do
      %{^key => value} when is_binary(value) and value != "" -> value
      _ -> fallback
    end
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key), default)
  rescue
    ArgumentError -> default
  end

  defp map_value(_map, _key, default), do: default

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default

  defp bounded_integer(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  defp bounded_integer(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> bounded_integer(integer, min, max)
      _ -> min
    end
  end

  defp bounded_integer(value, min, max) when is_float(value), do: value |> round() |> bounded_integer(min, max)
  defp bounded_integer(_value, min, _max), do: min

  defp humanize_field(nil), do: ""

  defp humanize_field(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp table_sparkline_points(values) when is_list(values) do
    values =
      values
      |> Enum.map(&numeric/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(40)

    case values do
      [] ->
        ""

      [_single] ->
        "0,12 100,12"

      values ->
        min_value = Enum.min(values)
        max_value = Enum.max(values)
        spread = max(max_value - min_value, 1.0)
        last_index = max(length(values) - 1, 1)

        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {value, index} ->
          x = index / last_index * 100
          y = 24 - (value - min_value) / spread * 20 - 2
          "#{Float.round(x, 2)},#{Float.round(y, 2)}"
        end)
    end
  end

  defp table_sparkline_points(_value), do: ""

  defp status_tone(value) do
    value =
      value
      |> format_value()
      |> String.downcase()

    cond do
      value in ["ok", "up", "true", "healthy", "online", "available", "ready", "success"] -> :success
      value in ["warn", "warning", "degraded", "partial"] -> :warning
      value in ["fail", "failed", "false", "down", "critical", "error", "offline", "unavailable"] -> :error
      true -> :neutral
    end
  end

  defp status_badge_variant(:success), do: "success"
  defp status_badge_variant(:warning), do: "warning"
  defp status_badge_variant(:error), do: "error"
  defp status_badge_variant(_tone), do: "outline"

  defp status_icon(:success), do: "hero-check-circle"
  defp status_icon(:warning), do: "hero-exclamation-triangle"
  defp status_icon(:error), do: "hero-x-circle"
  defp status_icon(_tone), do: "hero-question-mark-circle"

  defp status_field(fields) do
    Enum.find_value(fields, fn field ->
      name = field_name(field)
      if name in ["status", "state", "health", "result", "severity", "severity_label"], do: name
    end)
  end

  defp first_numeric_field(fields), do: first_field_of_type(fields, :number)
  defp first_string_field(fields), do: first_field_of_type(fields, :string)

  defp first_field_of_type(fields, type) do
    Enum.find_value(fields, fn field ->
      if field_type(field) == type, do: field_name(field)
    end)
  end

  defp field_name(%{name: name}), do: to_string(name)
  defp field_name(%{"name" => name}), do: to_string(name)
  defp field_name(field) when is_binary(field), do: field
  defp field_name(_field), do: ""

  defp field_type(%{type: type}) when is_atom(type), do: type
  defp field_type(%{type: type}) when is_binary(type), do: field_type(type)
  defp field_type(%{"type" => type}) when is_binary(type), do: field_type(type)
  defp field_type("number"), do: :number
  defp field_type("integer"), do: :integer
  defp field_type("datetime"), do: :datetime
  defp field_type("boolean"), do: :boolean
  defp field_type("string"), do: :string
  defp field_type(_field), do: :string

  defp field_type_for(fields, name) do
    fields
    |> Enum.find(&(field_name(&1) == to_string(name)))
    |> field_type()
  end

  defp numeric(value) when is_integer(value), do: value * 1.0
  defp numeric(value) when is_float(value), do: value

  defp numeric(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp numeric(_value), do: nil

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(nil), do: ""
  defp format_value(value), do: inspect(value)

  defp timestamp_value?(%DateTime{}), do: true
  defp timestamp_value?(%NaiveDateTime{}), do: true
  defp timestamp_value?(_value), do: false

  defp timestamp_value?(%DateTime{}, _type), do: true
  defp timestamp_value?(%NaiveDateTime{}, _type), do: true

  defp timestamp_value?(value, :datetime) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp timestamp_value?(_value, _type), do: false

  defp stable_row_id(row, index) when is_map(row) do
    row
    |> first_present_row_identity()
    |> case do
      nil -> Integer.to_string(index)
      identity -> safe_dom_id(identity)
    end
  end

  defp stable_row_id(_row, index), do: Integer.to_string(index)

  defp first_present_row_identity(row) do
    Enum.find_value(["id", :id, "uid", :uid, "uuid", :uuid, "key", :key], fn key ->
      case Map.get(row, key) do
        value when value not in [nil, ""] -> value
        _value -> nil
      end
    end)
  end

  defp safe_dom_id(value) do
    value = to_string(value)

    cond do
      value == "" -> "value"
      Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, value) -> "s-#{value}"
      true -> "e-#{Base.url_encode64(value, padding: false)}"
    end
  end
end

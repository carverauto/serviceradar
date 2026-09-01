defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  import ServiceRadarWebNGWeb.CoreComponents, only: [user_time: 1]
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.ChartCard
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.CombinedChartCard
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Focus
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Spec
  alias ServiceRadarWebNGWeb.SRQL.Viz

  @impl true
  def id, do: "timeseries"

  @impl true
  def title, do: "Timeseries"

  @impl true
  def supports?(%{"viz" => %{"suggestions" => suggestions}}) when is_list(suggestions) do
    Enum.any?(suggestions, fn
      %{"kind" => "timeseries"} -> true
      _ -> false
    end)
  end

  def supports?(%{"results" => results}) when is_list(results) do
    match?({:timeseries, _}, Viz.infer(results))
  end

  def supports?(_), do: false

  @impl true
  def build(%{"results" => results, "viz" => viz} = _srql_response) when is_list(results) and is_map(viz) do
    with {:ok, spec} <- Spec.parse_timeseries_spec(viz),
         {:ok, series_points, series_units, series_metadata} <- Spec.extract_series_points(results, spec) do
      spec =
        spec
        |> Map.put(:series_units, series_units)
        |> Map.put(:series_metadata, series_metadata)

      {:ok, %{spec: spec, series_points: series_points}}
    end
  end

  def build(%{"results" => results} = _srql_response) when is_list(results) do
    case Spec.infer_timeseries_spec(results) do
      {:ok, spec} ->
        with {:ok, series_points, series_units, series_metadata} <- Spec.extract_series_points(results, spec) do
          spec =
            spec
            |> Map.put(:series_units, series_units)
            |> Map.put(:series_metadata, series_metadata)

          {:ok, %{spec: spec, series_points: series_points}}
        end

      _ ->
        {:error, :invalid_response}
    end
  end

  def build(_), do: {:error, :invalid_response}

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    compact = Map.get(panel_assigns || %{}, :compact, false)
    max_speed = Map.get(panel_assigns || %{}, :max_speed_bytes_per_sec)
    chart_mode = Map.get(panel_assigns || %{}, :chart_mode, :single)
    combine_all_series = Map.get(panel_assigns || %{}, :combine_all_series, false)
    combined_title = Map.get(panel_assigns || %{}, :combined_title)
    compact_title = Map.get(panel_assigns || %{}, :compact_title)
    rate_mode = Map.get(panel_assigns || %{}, :rate_mode, :none)
    timezone = Spec.fetch_panel_value(panel_assigns, :timezone, "Etc/UTC") || "Etc/UTC"

    y_scale =
      panel_assigns
      |> Spec.fetch_panel_value(:y_scale, Spec.fetch_panel_value(panel_assigns, :scale_mode, :linear))
      |> Points.scale_mode()

    series_points = series_points_from_assigns(assigns, panel_assigns)
    spec = Spec.fetch_panel_value(panel_assigns, :spec, Map.get(assigns, :spec))

    series_points =
      case rate_mode do
        :counter ->
          series_points
          |> attach_series_metadata(series_metadata_from_assigns(panel_assigns, spec))
          |> Metrics.counter_rates(max_speed)

        _ ->
          series_points
      end

    socket =
      socket
      |> assign(Map.delete(assigns, :panel_assigns))
      |> assign(panel_assigns)
      |> assign(:compact, compact)
      |> assign(:series_points, series_points)
      |> assign(:spec, spec)
      |> assign(:max_speed_bytes_per_sec, max_speed)
      |> assign(:chart_mode, chart_mode)
      |> assign(:combine_all_series, combine_all_series)
      |> assign(:combined_title, combined_title)
      |> assign(:compact_title, compact_title)
      |> assign(:rate_mode, rate_mode)
      |> assign(:timezone, timezone)
      |> assign(:y_scale, y_scale)
      |> assign(:chart_width, Paths.chart_width())
      |> assign(:chart_height, Paths.chart_height())
      |> assign(:chart_left_pad, Paths.chart_left_pad())
      |> assign(:chart_right_pad, Paths.chart_right_pad())
      |> assign(:chart_top_pad, Paths.chart_top_pad())
      |> assign(:chart_bottom_pad, Paths.chart_bottom_pad())

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    compact = Map.get(assigns, :compact, false)
    series_points = assigns.series_points || []
    max_speed = Map.get(assigns, :max_speed_bytes_per_sec)
    chart_mode = Map.get(assigns, :chart_mode, :single)
    combine_all_series = Map.get(assigns, :combine_all_series, false)
    combined_title = Map.get(assigns, :combined_title, "Combined")
    chart_focus = assigns |> Spec.fetch_panel_value(:chart_focus) |> Focus.normalize()
    reference_lines = reference_lines_from_assigns(assigns)
    chart_overlays = chart_overlays_from_assigns(assigns)
    y_scale = Points.scale_mode(Map.get(assigns, :y_scale, :linear))

    {series_points, focus_annotation} = Focus.apply(series_points, chart_focus)
    annotations = annotations_from_assigns(assigns, focus_annotation)

    series_data =
      SeriesData.build_series_data(
        series_points,
        spec: Map.get(assigns, :spec),
        rate_mode: Map.get(assigns, :rate_mode, :none),
        compact: compact,
        max_speed: max_speed,
        annotations: annotations,
        reference_lines: reference_lines,
        y_scale: y_scale,
        chart_overlays: chart_overlays
      )

    {combined_charts, individual_series} =
      SeriesData.resolve_chart_groups(
        series_data,
        combine_all_series,
        chart_mode,
        max_speed,
        compact,
        combined_title,
        y_scale
      )

    empty_state =
      empty_state_from_assigns(
        assigns,
        combined_charts == [] and individual_series == []
      )

    assigns =
      assigns
      |> assign(:compact, compact)
      |> assign(:series_count, length(series_points))
      |> assign(:series_data, individual_series)
      |> assign(:combined_charts, combined_charts)
      |> assign(:empty_state, empty_state)
      |> assign(:first_dt, Points.first_dt(series_points))
      |> assign(:last_dt, Points.last_dt(series_points))

    render_chart(assigns, compact)
  end

  defp series_points_from_assigns(assigns, panel_assigns) do
    cond do
      is_map(panel_assigns) and Spec.fetch_panel_value(panel_assigns, :series_points) != nil ->
        Spec.fetch_panel_value(panel_assigns, :series_points) || []

      is_map(panel_assigns) and Spec.fetch_panel_value(panel_assigns, :series) != nil ->
        Spec.series_to_points(Spec.fetch_panel_value(panel_assigns, :series))

      true ->
        Map.get(assigns, :series_points, [])
    end
  end

  defp series_metadata_from_assigns(panel_assigns, spec) do
    %{}
    |> Map.merge(spec_series_metadata(spec))
    |> Map.merge(normalize_series_metadata(Spec.fetch_panel_value(panel_assigns, :series_metadata, %{})))
    |> Map.merge(Spec.series_metadata(Spec.fetch_panel_value(panel_assigns, :series, [])))
  end

  defp attach_series_metadata(series_points, metadata_by_series) when is_list(series_points) do
    Enum.map(series_points, fn
      {series, points, metadata} ->
        {series, points, metadata}

      {series, points} ->
        case series_metadata(metadata_by_series, series) do
          metadata when is_map(metadata) and metadata != %{} -> {series, points, metadata}
          _ -> {series, points}
        end

      entry ->
        entry
    end)
  end

  defp attach_series_metadata(series_points, _metadata_by_series), do: series_points

  defp spec_series_metadata(%{series_metadata: metadata}) when is_map(metadata), do: metadata
  defp spec_series_metadata(%{"series_metadata" => metadata}) when is_map(metadata), do: metadata
  defp spec_series_metadata(_), do: %{}

  defp normalize_series_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_series_metadata(_), do: %{}

  defp series_metadata(metadata_by_series, series) when is_map(metadata_by_series) do
    Map.get(metadata_by_series, series) || Map.get(metadata_by_series, to_string(series || ""))
  end

  defp annotations_from_assigns(assigns, focus_annotation) do
    annotations =
      assigns
      |> Spec.fetch_panel_value(:annotations, [])
      |> normalize_annotations()

    case focus_annotation do
      %{dt: %DateTime{}} = annotation -> normalize_annotations(annotations ++ [annotation])
      _ -> annotations
    end
  end

  defp normalize_annotations(annotations) when is_list(annotations) do
    annotations
    |> Enum.map(&normalize_annotation/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn annotation -> DateTime.to_unix(annotation.dt, :millisecond) end)
  end

  defp normalize_annotations(_annotations), do: []

  defp normalize_annotation(%{} = annotation) do
    dt_value =
      first_present([
        Map.get(annotation, :dt),
        Map.get(annotation, "dt"),
        Map.get(annotation, :time),
        Map.get(annotation, "time"),
        Map.get(annotation, :timestamp),
        Map.get(annotation, "timestamp")
      ])

    case parse_annotation_datetime(dt_value) do
      {:ok, dt} ->
        %{
          dt: dt,
          label: annotation_label(annotation),
          severity: annotation_severity(annotation),
          series: annotation_series(annotation)
        }

      _ ->
        nil
    end
  end

  defp normalize_annotation(_annotation), do: nil

  defp annotation_label(annotation) do
    annotation
    |> annotation_value([:label, "label", :title, "title"])
    |> safe_to_string()
    |> String.trim()
    |> case do
      "" -> "Finding"
      value -> value
    end
  end

  defp annotation_severity(annotation) do
    annotation
    |> annotation_value([:severity, "severity", :severity_text, "severity_text"])
    |> safe_to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "critical" -> :critical
      "error" -> :critical
      "high" -> :high
      "warning" -> :warning
      "warn" -> :warning
      "medium" -> :warning
      "low" -> :info
      "info" -> :info
      "informational" -> :info
      _ -> :info
    end
  end

  defp annotation_series(annotation) do
    annotation
    |> annotation_value([:series, "series", :series_key, "series_key"])
    |> case do
      nil ->
        nil

      value ->
        value
        |> safe_to_string()
        |> String.trim()
        |> case do
          "" -> nil
          series -> series
        end
    end
  end

  defp annotation_value(annotation, keys), do: Enum.find_value(keys, &Map.get(annotation, &1))

  defp chart_overlays_from_assigns(assigns) do
    assigns
    |> Spec.fetch_panel_value(:chart_overlays, [])
    |> normalize_chart_overlays()
  end

  defp normalize_chart_overlays(overlays) when is_list(overlays) do
    overlays
    |> Enum.map(&normalize_chart_overlay/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_chart_overlays(_overlays), do: []

  defp normalize_chart_overlay(%{} = overlay) do
    case overlay_kind(overlay) do
      :anomaly -> normalize_anomaly_overlay(overlay)
      :capacity -> normalize_capacity_overlay(overlay)
      _ -> nil
    end
  end

  defp normalize_chart_overlay(_overlay), do: nil

  defp normalize_anomaly_overlay(overlay) do
    dt_value =
      first_present([
        Map.get(overlay, :dt),
        Map.get(overlay, "dt"),
        Map.get(overlay, :time),
        Map.get(overlay, "time"),
        Map.get(overlay, :timestamp),
        Map.get(overlay, "timestamp")
      ])

    case parse_annotation_datetime(dt_value) do
      {:ok, dt} ->
        %{
          kind: :anomaly,
          dt: dt,
          window_started_at: overlay_datetime(overlay, [:window_started_at, "window_started_at"]),
          window_ended_at: overlay_datetime(overlay, [:window_ended_at, "window_ended_at"]),
          value: overlay_number(overlay, [:value, "value", :peak_value, "peak_value", :metric_value, "metric_value"]),
          threshold_value: overlay_number(overlay, [:threshold_value, "threshold_value", :threshold, "threshold"]),
          score: overlay_number(overlay, [:score, "score"]),
          label: overlay_label(overlay),
          severity: overlay_severity(overlay),
          series: annotation_series(overlay),
          selected: truthy?(annotation_value(overlay, [:selected, "selected"])),
          disposition: overlay_string(overlay, [:disposition, "disposition"]),
          reason: overlay_string(overlay, [:reason, "reason"])
        }

      _ ->
        nil
    end
  end

  defp normalize_capacity_overlay(overlay) do
    dt = overlay_datetime(overlay, [:dt, "dt", :projected_exhaustion_at, "projected_exhaustion_at"])

    if is_struct(dt, DateTime) do
      %{
        kind: :capacity,
        dt: dt,
        forecasted_at: overlay_datetime(overlay, [:forecasted_at, "forecasted_at"]),
        current_value: overlay_number(overlay, [:current_value, "current_value"]),
        projected_value: overlay_number(overlay, [:projected_value, "projected_value"]),
        threshold_value:
          overlay_number(overlay, [:threshold_value, "threshold_value", :exhaustion_threshold, "exhaustion_threshold"]),
        lower_bound: overlay_number(overlay, [:lower_bound, "lower_bound"]),
        upper_bound: overlay_number(overlay, [:upper_bound, "upper_bound"]),
        confidence: overlay_number(overlay, [:confidence, "confidence"]),
        label: overlay_label(overlay),
        severity: overlay_severity(overlay),
        series: annotation_series(overlay),
        status: overlay_string(overlay, [:status, "status"])
      }
    end
  end

  defp overlay_kind(overlay) do
    overlay
    |> annotation_value([:kind, "kind", :type, "type"])
    |> safe_to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "anomaly" -> :anomaly
      "capacity" -> :capacity
      "capacity_forecast" -> :capacity
      "capacity-forecast" -> :capacity
      _ -> nil
    end
  end

  defp overlay_label(overlay) do
    overlay
    |> annotation_value([:label, "label", :title, "title", :name, "name"])
    |> safe_to_string()
    |> String.trim()
    |> case do
      "" -> "Overlay"
      value -> value
    end
  end

  defp overlay_severity(overlay) do
    overlay
    |> annotation_value([
      :effective_severity,
      "effective_severity",
      :severity,
      "severity",
      :severity_text,
      "severity_text"
    ])
    |> safe_to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "critical" -> :critical
      "error" -> :critical
      "high" -> :high
      "warning" -> :warning
      "warn" -> :warning
      "medium" -> :warning
      "low" -> :info
      "info" -> :info
      "informational" -> :info
      _ -> :info
    end
  end

  defp overlay_datetime(overlay, keys) do
    overlay
    |> annotation_value(keys)
    |> parse_annotation_datetime()
    |> case do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp overlay_number(overlay, keys) do
    overlay
    |> annotation_value(keys)
    |> parse_number()
  end

  defp overlay_string(overlay, keys) do
    overlay
    |> annotation_value(keys)
    |> safe_to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp reference_lines_from_assigns(assigns) do
    assigns
    |> Spec.fetch_panel_value(:reference_lines, [])
    |> normalize_reference_lines()
  end

  defp normalize_reference_lines(reference_lines) when is_list(reference_lines) do
    reference_lines
    |> Enum.map(&normalize_reference_line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn reference_line -> {reference_line.value, reference_line.label} end)
  end

  defp normalize_reference_lines(_reference_lines), do: []

  defp normalize_reference_line(%{} = reference_line) do
    case parse_number(reference_line_value(reference_line)) do
      value when is_number(value) ->
        %{
          value: value,
          label: reference_line_label(reference_line),
          severity: reference_line_severity(reference_line),
          series: reference_line_series(reference_line)
        }

      _ ->
        nil
    end
  end

  defp normalize_reference_line(_reference_line), do: nil

  defp reference_line_value(reference_line) do
    reference_line_value(reference_line, [:value, "value", :threshold, "threshold", :y, "y"])
  end

  defp reference_line_value(reference_line, keys), do: Enum.find_value(keys, &Map.get(reference_line, &1))

  defp reference_line_label(reference_line) do
    reference_line
    |> reference_line_value([:label, "label", :title, "title", :name, "name"])
    |> safe_to_string()
    |> String.trim()
    |> case do
      "" -> "Threshold"
      value -> value
    end
  end

  defp reference_line_severity(reference_line) do
    reference_line
    |> reference_line_value([:severity, "severity", :severity_text, "severity_text"])
    |> safe_to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "critical" -> :critical
      "error" -> :critical
      "high" -> :high
      "warning" -> :warning
      "warn" -> :warning
      "medium" -> :warning
      "low" -> :info
      "info" -> :info
      "informational" -> :info
      _ -> :info
    end
  end

  defp reference_line_series(reference_line) do
    reference_line
    |> reference_line_value([:series, "series", :series_key, "series_key", :metric, "metric"])
    |> case do
      nil ->
        nil

      value ->
        value
        |> safe_to_string()
        |> String.trim()
        |> case do
          "" -> nil
          series -> series
        end
    end
  end

  defp first_present(values) do
    Enum.find(values, fn
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end)
  end

  defp parse_annotation_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_annotation_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_annotation_datetime(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_annotation_datetime(_value), do: {:error, :not_datetime}

  defp parse_number(value) when is_integer(value) or is_float(value), do: value * 1.0

  defp parse_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_number(_value), do: nil

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp render_chart(assigns, true), do: render_compact(assigns)
  defp render_chart(assigns, false), do: render_full(assigns)

  defp empty_state_from_assigns(_assigns, false), do: nil

  defp empty_state_from_assigns(assigns, true) do
    case normalize_empty_state(Spec.fetch_panel_value(assigns, :empty_state, :no_data)) do
      :query_error ->
        %{
          title: "Chart query failed",
          detail:
            Spec.fetch_panel_value(
              assigns,
              :empty_detail,
              "The chart query failed before returning usable data."
            ),
          class: "border-error bg-error/5 text-error"
        }

      :disabled ->
        %{
          title: "Metrics collection disabled",
          detail:
            Spec.fetch_panel_value(
              assigns,
              :empty_detail,
              "Enable the relevant SNMP or polling configuration."
            ),
          class: "border-warning bg-warning/5 text-warning",
          href: Spec.fetch_panel_value(assigns, :empty_config_href),
          label: Spec.fetch_panel_value(assigns, :empty_config_label, "Configure metrics")
        }

      _ ->
        %{
          title: "No chart data",
          detail: Spec.fetch_panel_value(assigns, :empty_detail, "No samples matched this chart."),
          class: "border-sr-line bg-sr-subtle/40 text-sr-ink"
        }
    end
  end

  defp normalize_empty_state(value) when is_atom(value), do: value

  defp normalize_empty_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "query_error" -> :query_error
      "query-error" -> :query_error
      "error" -> :query_error
      "disabled" -> :disabled
      _ -> :no_data
    end
  end

  defp normalize_empty_state(_value), do: :no_data

  defp empty_state_box(assigns) do
    ~H"""
    <div
      :if={@empty_state}
      class={[
        "rounded-lg border px-4 py-5",
        @empty_state.class
      ]}
    >
      <div class={["font-semibold", @compact && "text-xs", not @compact && "text-sm"]}>
        {@empty_state.title}
      </div>
      <div class={["mt-1 opacity-80", @compact && "text-[10px]", not @compact && "text-xs"]}>
        {@empty_state.detail}
      </div>
      <a
        :if={Map.get(@empty_state, :href)}
        href={@empty_state.href}
        class={[
          "link mt-3 inline-flex",
          @compact && "text-[10px]",
          not @compact && "text-xs"
        ]}
      >
        {Map.get(@empty_state, :label, "Configure metrics")}
      </a>
    </div>
    """
  end

  defp render_compact(assigns) do
    ~H"""
    <div id={"panel-#{@id}"} class="p-4" data-timezone={@timezone}>
      <.empty_state_box empty_state={@empty_state} compact={@compact} />

      <div
        :if={is_binary(@compact_title) and @series_data != []}
        class="mb-3 text-sm font-semibold text-sr-ink"
      >
        {@compact_title}
      </div>

      <%= for combined <- @combined_charts do %>
        <CombinedChartCard.combined_chart_card
          id={@id}
          data={combined}
          chart_width={@chart_width}
          chart_height={@chart_height}
          chart_left_pad={@chart_left_pad}
          chart_right_pad={@chart_right_pad}
          chart_top_pad={@chart_top_pad}
          chart_bottom_pad={@chart_bottom_pad}
          compact={true}
          timezone={@timezone}
        />
      <% end %>

      <div
        :if={@series_data != []}
        class={[
          "grid gap-3",
          length(@series_data) > 1 && "grid-cols-1 lg:grid-cols-2 xl:grid-cols-3",
          length(@series_data) == 1 && "grid-cols-1",
          @combined_charts != [] && "mt-3"
        ]}
      >
        <%= for data <- @series_data do %>
          <ChartCard.chart_card
            id={@id}
            data={data}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_left_pad={@chart_left_pad}
            chart_right_pad={@chart_right_pad}
            chart_top_pad={@chart_top_pad}
            chart_bottom_pad={@chart_bottom_pad}
            compact={true}
            timezone={@timezone}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp render_full(assigns) do
    ~H"""
    <div id={"panel-#{@id}"} data-timezone={@timezone}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">{@title || "Timeseries"}</div>
          </div>
          <div class="text-xs text-sr-muted font-mono">
            <.user_time
              :if={is_struct(@first_dt, DateTime)}
              id={"timeseries-#{@id}-first-time"}
              value={@first_dt}
              timezone={@timezone}
              style={:compact}
            />
            <span class="px-1">→</span>
            <.user_time
              :if={is_struct(@last_dt, DateTime)}
              id={"timeseries-#{@id}-last-time"}
              value={@last_dt}
              timezone={@timezone}
              style={:compact}
            />
          </div>
        </:header>

        <.empty_state_box empty_state={@empty_state} compact={@compact} />

        <%= for combined <- @combined_charts do %>
          <CombinedChartCard.combined_chart_card
            id={@id}
            data={combined}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_left_pad={@chart_left_pad}
            chart_right_pad={@chart_right_pad}
            chart_top_pad={@chart_top_pad}
            chart_bottom_pad={@chart_bottom_pad}
            compact={false}
            timezone={@timezone}
          />
        <% end %>

        <div
          :if={@series_data != []}
          class={[
            "grid gap-4",
            length(@series_data) > 1 && "grid-cols-1 md:grid-cols-2",
            length(@series_data) <= 1 && "grid-cols-1"
          ]}
        >
          <%= for data <- @series_data do %>
            <ChartCard.chart_card
              id={@id}
              data={data}
              chart_width={@chart_width}
              chart_height={@chart_height}
              chart_left_pad={@chart_left_pad}
              chart_right_pad={@chart_right_pad}
              chart_top_pad={@chart_top_pad}
              chart_bottom_pad={@chart_bottom_pad}
              compact={false}
              timezone={@timezone}
            />
          <% end %>
        </div>
      </.ui_panel>
    </div>
    """
  end
end

defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.ChartCard
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.CombinedChartCard
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Spec
  alias ServiceRadarWebNGWeb.SRQL.Viz

  @chart_width 800
  @chart_height 140
  @chart_pad 8

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
    rate_mode = Map.get(panel_assigns || %{}, :rate_mode, :none)
    y_scale = Points.scale_mode(Spec.fetch_panel_value(panel_assigns, :y_scale, :linear))
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
      |> assign(:rate_mode, rate_mode)
      |> assign(:y_scale, y_scale)
      |> assign(:chart_width, @chart_width)
      |> assign(:chart_height, @chart_height)
      |> assign(:chart_pad, @chart_pad)

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
    annotations = annotations_from_assigns(assigns)
    y_scale = Points.scale_mode(Map.get(assigns, :y_scale, :linear))

    series_data =
      SeriesData.build_series_data(
        series_points,
        Map.get(assigns, :spec),
        Map.get(assigns, :rate_mode, :none),
        compact,
        max_speed,
        annotations,
        y_scale
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

    assigns =
      assigns
      |> assign(:compact, compact)
      |> assign(:series_count, length(series_points))
      |> assign(:series_data, individual_series)
      |> assign(:combined_charts, combined_charts)
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

  defp series_metadata(_metadata_by_series, _series), do: nil

  defp annotations_from_assigns(assigns) do
    assigns
    |> Spec.fetch_panel_value(:annotations, [])
    |> normalize_annotations()
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

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp render_chart(assigns, true), do: render_compact(assigns)
  defp render_chart(assigns, false), do: render_full(assigns)

  defp render_compact(assigns) do
    ~H"""
    <div id={"panel-#{@id}"} class="p-4">
      <div class={[
        "grid gap-3",
        @series_count > 1 && "grid-cols-1 lg:grid-cols-2 xl:grid-cols-3",
        @series_count == 1 && "grid-cols-1"
      ]}>
        <%= for combined <- @combined_charts do %>
          <CombinedChartCard.combined_chart_card
            id={@id}
            data={combined}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={true}
          />
        <% end %>
        <%= for data <- @series_data do %>
          <ChartCard.chart_card
            id={@id}
            data={data}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={true}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp render_full(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">{@title || "Timeseries"}</div>
          </div>
          <div class="text-xs text-base-content/50 font-mono">
            <span :if={is_struct(@first_dt, DateTime)}>{Points.dt_label(@first_dt)}</span>
            <span class="px-1">→</span>
            <span :if={is_struct(@last_dt, DateTime)}>{Points.dt_label(@last_dt)}</span>
          </div>
        </:header>

        <%= for combined <- @combined_charts do %>
          <CombinedChartCard.combined_chart_card
            id={@id}
            data={combined}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={false}
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
              chart_pad={@chart_pad}
              compact={false}
            />
          <% end %>
        </div>
      </.ui_panel>
    </div>
    """
  end
end

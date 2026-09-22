defmodule ServiceRadarWebNGWeb.DashboardLive.Index.EventsPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DashboardLive.Index.Common

  alias ServiceRadarWebNGWeb.DashboardLive.EventRange
  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common
  alias ServiceRadarWebNGWeb.ObservabilityPaths

  @event_layers [:low, :medium, :high, :critical]

  attr(:dashboard, :map, required: true)
  attr(:embedded, :boolean, default: false)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(%{dashboard: dashboard} = assigns) do
    assigns =
      assigns
      |> Map.merge(dashboard)
      |> Map.put_new(:security_trend, [])
      |> Map.put_new(:security_trend_max, 0)
      |> Map.put_new(:time_window_label, "")
      |> put_range_buckets()

    ~H"""
    <Common.panel :if={!@embedded} title="Events Over Time">
      <:actions>
        <span class="sr-ops-select">{@time_window_label}</span>
      </:actions>
      <.events_body
        security_trend={@security_trend}
        security_trend_max={@security_trend_max}
        range_buckets_json={@range_buckets_json}
        timezone={@timezone}
      />
    </Common.panel>

    <.events_body
      :if={@embedded}
      security_trend={@security_trend}
      security_trend_max={@security_trend_max}
      range_buckets_json={@range_buckets_json}
      timezone={@timezone}
    />
    """
  end

  attr(:security_trend, :list, required: true)
  attr(:security_trend_max, :any, required: true)
  attr(:range_buckets_json, :string, default: nil)
  attr(:timezone, :string, required: true)

  defp events_body(assigns) do
    ~H"""
    <div class="sr-ops-events-range-shell">
      <%!-- Keep this as one conditional branch so connected async hydration replaces the
      disconnected empty state instead of leaving stale sibling DOM behind. --%>
      <%= if is_nil(@range_buckets_json) do %>
        <div class="sr-ops-empty-chart" data-testid="security-events-empty">
          <.icon name="hero-chart-bar" class="size-8 text-slate-500" />
          <p>No event trend data</p>
          <span>OCSF events will populate this chart when recent records exist.</span>
        </div>
      <% else %>
        <div
          id="dashboard-events-range-selector"
          phx-hook="ChartRangeSelection"
          class="sr-ops-security-chart sr-ops-events-range-selector"
          tabindex="0"
          role="group"
          aria-label="Select an Events Over Time range"
          aria-describedby="dashboard-events-range-instructions"
          data-range-buckets={@range_buckets_json}
          data-range-event="select_events_range"
          data-timezone={@timezone}
          data-chart-width="640"
          data-chart-left-pad="36"
          data-chart-right-pad="24"
          data-testid="security-events-chart"
        >
          <svg
            data-range-svg
            class="sr-ops-events-area-chart"
            viewBox="0 0 640 220"
            preserveAspectRatio="none"
            role="img"
            aria-label="Events over time severity trend"
          >
            <g class="sr-ops-events-grid">
              <line
                :for={label <- event_axis_labels(@security_trend)}
                class="sr-ops-events-x-grid"
                x1={label.x}
                x2={label.x}
                y1="26"
                y2="180"
              />
              <line
                :for={tick <- event_y_axis_ticks(@security_trend_max)}
                x1="36"
                x2="616"
                y1={tick.y}
                y2={tick.y}
              />
              <line class="sr-ops-events-baseline" x1="36" x2="616" y1="180" y2="180" />
            </g>
            <path
              class="sr-ops-events-area-low"
              d={event_area_path(@security_trend, @security_trend_max, :low)}
            />
            <path
              class="sr-ops-events-area-medium"
              d={event_area_path(@security_trend, @security_trend_max, :medium)}
            />
            <path
              class="sr-ops-events-area-high"
              d={event_area_path(@security_trend, @security_trend_max, :high)}
            />
            <path
              class="sr-ops-events-area-critical"
              d={event_area_path(@security_trend, @security_trend_max, :critical)}
            />
            <polyline
              class="sr-ops-events-line"
              points={event_line_points(@security_trend, @security_trend_max)}
            />
            <g class="sr-ops-events-axis">
              <text
                :for={tick <- event_y_axis_ticks(@security_trend_max)}
                class="sr-ops-events-y-label"
                x="30"
                y={tick.y + 4}
              >
                {tick.text}
              </text>
              <text
                :for={label <- event_axis_labels(@security_trend)}
                id={label.id}
                x={label.x}
                y="204"
                phx-hook="UserTime"
                data-user-time-iso={label.iso}
                data-user-time-zone={@timezone}
                data-user-time-style={event_axis_style(@security_trend)}
                data-user-time-fallback={label.iso}
                title={"#{label.iso} (UTC); display zone #{@timezone}"}
                aria-label={"#{label.iso} UTC; display zone #{@timezone}"}
              >
                {label.iso}
              </text>
            </g>
            <rect
              data-range-overlay
              class="sr-ops-events-range-overlay hidden"
              x="36"
              y="26"
              width="0"
              height="154"
            />
          </svg>
          <div class="sr-ops-events-legend">
            <span><i class="sr-ops-events-dot critical"></i>Critical</span>
            <span><i class="sr-ops-events-dot high"></i>High</span>
            <span><i class="sr-ops-events-dot medium"></i>Medium</span>
            <span><i class="sr-ops-events-dot low"></i>Low</span>
          </div>
          <div class="sr-ops-events-range-footer">
            <p id="dashboard-events-range-instructions" class="sr-ops-events-range-instructions">
              Drag across the plot, or use Shift + arrow keys and press Enter, to inspect a time range.
            </p>
            <span data-range-status class="sr-ops-events-range-status" aria-live="polite"></span>
          </div>
        </div>
      <% end %>

      <div class="sr-ops-events-range-actions">
        <.link
          id="dashboard-events-view-all"
          navigate={ObservabilityPaths.path("events")}
          class="sr-ops-events-view-all"
        >
          View all events
        </.link>
      </div>
    </div>
    """
  end

  defp put_range_buckets(assigns) do
    range_buckets_json =
      with true <- event_trend_renderable?(assigns.security_trend, assigns.security_trend_max),
           {:ok, buckets} <- EventRange.buckets(assigns.security_trend) do
        Jason.encode!(buckets)
      else
        _ -> nil
      end

    Map.put(assigns, :range_buckets_json, range_buckets_json)
  end

  defp event_trend_renderable?(points, max_total)
       when is_list(points) and points != [] and is_integer(max_total) and max_total >= 0 do
    Enum.all?(points, &event_point_renderable?/1)
  end

  defp event_trend_renderable?(_points, _max_total), do: false

  defp event_point_renderable?(%{bucket: bucket, total: total} = point) when is_number(total) and total >= 0 do
    not is_nil(canonical_bucket(bucket)) and
      Enum.all?(@event_layers, fn layer -> non_negative_number?(Map.get(point, layer, 0)) end)
  end

  defp event_point_renderable?(_point), do: false

  defp non_negative_number?(value), do: is_number(value) and value >= 0

  defp event_area_path(points, max_total, layer), do: event_layer_path(points, max_total, event_layer_index(layer))

  defp event_line_points(points, max_total) do
    points
    |> Enum.with_index()
    |> Enum.map(fn {point, idx} -> event_xy(idx, length(points), point.total, max_total) end)
    |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
  end

  defp event_axis_labels(points) do
    count = length(points)
    step = max(div(count, 5), 1)

    points
    |> Enum.with_index()
    |> Enum.filter(fn {_point, idx} -> event_axis_tick?(idx, count, step) end)
    |> Enum.map(fn {point, idx} ->
      {x, _y} = event_xy(idx, count, 0, 1)
      canonical = canonical_bucket(point.bucket)

      %{
        x: x,
        id: "dashboard-events-axis-#{DateTime.to_unix(canonical)}",
        iso: DateTime.to_iso8601(canonical)
      }
    end)
  end

  # The first and last points are always labelled, plus every `step`-th between.
  # When the count is not a multiple of the step, the last regular tick lands
  # right beside the final point and the two labels overlap, so a regular tick
  # less than a full step from the end gives way to it. Measured on a 29-point
  # week, a tick 0.6 of a step from the end still overlapped its neighbour.
  defp event_axis_tick?(idx, count, step) do
    last = count - 1

    cond do
      idx == 0 or idx == last -> true
      rem(idx, step) != 0 -> false
      true -> last - idx >= step
    end
  end

  # A clock time can only tell ticks apart within a day. Past that, the buckets
  # are hours or days wide and every tick lands on the same time of day, so a
  # 90-day chart read "07:00 PM" six times over.
  defp event_axis_style(points) do
    buckets = points |> Enum.map(&canonical_bucket(&1.bucket)) |> Enum.reject(&is_nil/1)

    case buckets do
      [first | _] = all ->
        span = DateTime.diff(List.last(all), first, :second)

        cond do
          span <= 86_400 -> "axis"
          span <= 7 * 86_400 -> "axisDayTime"
          true -> "axisDate"
        end

      [] ->
        "axis"
    end
  end

  defp canonical_bucket(%DateTime{} = bucket), do: DateTime.truncate(bucket, :second)

  defp canonical_bucket(%NaiveDateTime{} = bucket) do
    bucket
    |> NaiveDateTime.truncate(:second)
    |> DateTime.from_naive!("Etc/UTC")
  end

  defp canonical_bucket(_bucket), do: nil

  defp event_y_axis_ticks(max_total) do
    max_total = max(to_int(max_total), 0)

    max_total
    |> event_tick_values()
    |> Enum.map(fn value ->
      {_x, y} = event_xy(0, 1, value, max(max_total, 1))
      %{y: y, text: event_tick_label(value)}
    end)
  end

  defp event_tick_values(0), do: [0]

  defp event_tick_values(max_total) do
    Enum.uniq([
      max_total,
      round(max_total * 0.75),
      round(max_total * 0.5),
      round(max_total * 0.25),
      0
    ])
  end

  # The labels sit in a 36-unit left margin and are clipped at the chart's edge,
  # so they have to stay short: "812.4K" lost its first character and read as
  # "12.4K". Three significant figures is as much as a tick needs.
  defp event_tick_label(value) when value >= 1_000_000_000, do: "#{event_tick_scaled(value / 1_000_000_000)}B"
  defp event_tick_label(value) when value >= 1_000_000, do: "#{event_tick_scaled(value / 1_000_000)}M"
  defp event_tick_label(value) when value >= 1_000, do: "#{event_tick_scaled(value / 1_000)}K"
  defp event_tick_label(value), do: Integer.to_string(value)

  defp event_tick_scaled(value) when value >= 100, do: value |> round() |> Integer.to_string()

  defp event_tick_scaled(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  defp event_layer_index(:low), do: 0
  defp event_layer_index(:medium), do: 1
  defp event_layer_index(:high), do: 2
  defp event_layer_index(:critical), do: 3

  defp event_layer_path(points, max_total, layer_index) when points != [] and max_total > 0 do
    count = length(points)

    top =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, idx} ->
        event_xy(idx, count, event_cumulative(point, layer_index), max_total)
      end)

    bottom =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, idx} ->
        event_xy(idx, count, event_cumulative(point, layer_index - 1), max_total)
      end)
      |> Enum.reverse()

    [first | rest] = top ++ bottom
    {x, y} = first
    "M #{x} #{y} " <> Enum.map_join(rest, " ", fn {px, py} -> "L #{px} #{py}" end) <> " Z"
  end

  defp event_layer_path(_points, _max_total, _layer_index), do: ""

  defp event_cumulative(point, layer_index) do
    @event_layers
    |> Enum.take(layer_index + 1)
    |> Enum.map(&Map.get(point, &1, 0))
    |> Enum.sum()
  end

  defp event_xy(idx, count, value, max_total) do
    top = 26
    height = 154
    x = EventRange.x(idx, count)
    y = top + height - round(height * value / max(max_total, 1))
    {x, y}
  end
end

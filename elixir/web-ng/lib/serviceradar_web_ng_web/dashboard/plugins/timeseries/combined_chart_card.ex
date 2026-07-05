defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.CombinedChartCard do
  @moduledoc false

  use Phoenix.Component

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.ChartCard
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics

  attr :id, :string, required: true
  attr :data, :map, required: true
  attr :chart_width, :integer, required: true
  attr :chart_height, :integer, required: true
  attr :chart_left_pad, :integer, required: true
  attr :chart_right_pad, :integer, required: true
  attr :chart_top_pad, :integer, required: true
  attr :chart_bottom_pad, :integer, required: true
  attr :compact, :boolean, default: false

  def combined_chart_card(assigns) do
    series_tooltip_data =
      (assigns.data.series || [])
      |> Enum.map(fn series ->
        %{
          label: series.series,
          color: series.stroke,
          unit: Metrics.unit_to_string(series.unit),
          points: series.point_data
        }
      end)
      |> Jason.encode!()

    assigns =
      assigns
      |> assign(:series_tooltip_data, series_tooltip_data)
      |> assign(:effective_chart_left_pad, Map.get(assigns.data, :chart_left_pad, assigns.chart_left_pad))
      |> assign(:annotation_window_notice, ChartCard.annotation_window_notice(Map.get(assigns.data, :annotations, [])))

    ~H"""
    <div
      id={"combined-chart-#{@id}"}
      class={[
        "rounded-lg border border-base-200 bg-base-100 relative",
        @compact && "p-3",
        not @compact && "p-4"
      ]}
      phx-hook="TimeseriesCombinedChart"
      data-series={@series_tooltip_data}
      data-y-min={@data.chart_min}
      data-y-max={@data.chart_max}
      data-y-scale={@data.y_scale}
      data-chart-width={@chart_width}
      data-chart-left-pad={@effective_chart_left_pad}
      data-chart-right-pad={@chart_right_pad}
    >
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="flex items-center gap-2 min-w-0">
          <span class={["font-medium", @compact && "text-xs", not @compact && "text-sm"]}>
            {@data.title}
          </span>
          <span
            :if={Map.get(@data, :overlays, []) != []}
            class="badge badge-xs badge-outline"
            title={"#{length(@data.overlays)} chart overlays"}
          >
            {length(@data.overlays)}
          </span>
        </div>
        <div class="flex items-center gap-3">
          <%= for series <- @data.series do %>
            <div class="flex items-center gap-1">
              <ChartCard.series_marker
                color={series.stroke}
                encoding={ChartCard.series_encoding(series.idx)}
                class="size-3"
              />
              <span class={[
                "text-base-content/70",
                @compact && "text-[10px]",
                not @compact && "text-xs"
              ]}>
                {series.series}
                <span :if={series.utilization} class="text-base-content/50">
                  ({series.utilization}%)
                </span>
              </span>
            </div>
          <% end %>
        </div>
      </div>

      <div class="relative">
        <svg
          viewBox={"0 0 #{@chart_width} #{@chart_height}"}
          class={["w-full", @compact && "h-24", not @compact && "h-40"]}
          preserveAspectRatio="none"
          data-chart-svg
        >
          <defs>
            <%= for series <- @data.series do %>
              <linearGradient id={"combined-fill-#{@id}-#{series.idx}"} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stop-color={series.stroke} stop-opacity="0.2" />
                <stop offset="100%" stop-color={series.stroke} stop-opacity="0.02" />
              </linearGradient>
            <% end %>
          </defs>

          <g stroke="currentColor" class="text-base-content/10" stroke-dasharray="3 4">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@effective_chart_left_pad} x2={@chart_width - @chart_right_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_top_pad} y2={@chart_height - @chart_bottom_pad} />
            <% end %>
          </g>

          <g stroke="currentColor" class="text-base-content/40">
            <line
              x1={@effective_chart_left_pad}
              x2={@effective_chart_left_pad}
              y1={@chart_top_pad}
              y2={@chart_height - @chart_bottom_pad}
            />
            <line
              x1={@effective_chart_left_pad}
              x2={@chart_width - @chart_right_pad}
              y1={@chart_height - @chart_bottom_pad}
              y2={@chart_height - @chart_bottom_pad}
            />
          </g>

          <g stroke="currentColor" class="text-base-content/40">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@effective_chart_left_pad - 3} x2={@effective_chart_left_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line
                x1={x}
                x2={x}
                y1={@chart_height - @chart_bottom_pad}
                y2={@chart_height - @chart_bottom_pad + 3}
              />
            <% end %>
          </g>

          <g class="text-[12px] fill-base-content/70 font-mono">
            <%= for {y, label} <- @data.y_ticks do %>
              <text x={@effective_chart_left_pad - 10} y={y + 4} text-anchor="end">{label}</text>
            <% end %>
          </g>

          <g class="text-[11px] fill-base-content/70 font-mono">
            <%= for {x, label} <- @data.x_ticks do %>
              <text x={x} y={@chart_height - 4} text-anchor="middle">{label}</text>
            <% end %>
          </g>

          <ChartCard.annotation_markers_svg
            annotations={@data.annotations}
            chart_top_pad={@chart_top_pad}
            chart_bottom_pad={@chart_bottom_pad}
            chart_height={@chart_height}
            compact={@compact}
          />

          <ChartCard.chart_overlays_svg
            overlays={Map.get(@data, :overlays, [])}
            chart_left_pad={@effective_chart_left_pad}
            chart_right_pad={@chart_right_pad}
            chart_top_pad={@chart_top_pad}
            chart_bottom_pad={@chart_bottom_pad}
            chart_width={@chart_width}
            chart_height={@chart_height}
            compact={@compact}
          />

          <ChartCard.reference_lines_svg
            reference_lines={@data.reference_lines}
            chart_left_pad={@effective_chart_left_pad}
            chart_right_pad={@chart_right_pad}
            chart_width={@chart_width}
          />

          <%= for series <- @data.series do %>
            <path d={series.paths.area} fill={"url(#combined-fill-#{@id}-#{series.idx})"} />
            <path
              d={series.paths.line}
              fill="none"
              stroke={series.stroke}
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              data-series-shape={ChartCard.series_encoding(series.idx).shape}
            />
          <% end %>
        </svg>

        <div
          class="absolute hidden pointer-events-none bg-base-300 text-base-content text-xs px-2 py-1 rounded shadow-lg z-10 font-mono whitespace-normal"
          data-tooltip
        >
        </div>
        <div
          class="absolute hidden pointer-events-none w-px bg-base-content/30 top-0 bottom-0"
          data-hover-line
        >
        </div>
      </div>

      <div
        :if={@annotation_window_notice}
        data-testid="timeseries-marker-window-note"
        class="mt-1 text-[10px] leading-snug text-base-content/60"
      >
        {@annotation_window_notice}
      </div>

      <div class={[
        "flex items-center justify-between text-base-content/50 mt-1 gap-4",
        @compact && "text-[10px]",
        not @compact && "text-xs"
      ]}>
        <%= for series <- @data.series do %>
          <div class="flex items-center gap-1">
            <ChartCard.series_marker
              color={series.stroke}
              encoding={ChartCard.series_encoding(series.idx)}
              class="size-2.5"
            />
            <span class="font-mono">{Metrics.format_value(series.paths.avg, series.unit)}</span>
          </div>
        <% end %>
        <span :if={@data.max_speed} class="text-base-content/40 ml-auto">
          interface rate:
          <span class="font-mono">{Metrics.format_value(@data.max_speed, :bytes_per_sec)}</span>
        </span>
      </div>

      <div class={[
        "flex items-center justify-between text-base-content/40 mt-1 font-mono",
        @compact && "text-[9px]",
        not @compact && "text-[10px]"
      ]}>
        <span>{@data.first_dt}</span>
        <span>{@data.last_dt}</span>
      </div>
    </div>
    """
  end
end

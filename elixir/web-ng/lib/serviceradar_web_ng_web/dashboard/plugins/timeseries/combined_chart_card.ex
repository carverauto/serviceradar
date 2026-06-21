defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.CombinedChartCard do
  @moduledoc false

  use Phoenix.Component

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics

  attr :id, :string, required: true
  attr :data, :map, required: true
  attr :chart_width, :integer, required: true
  attr :chart_height, :integer, required: true
  attr :chart_pad, :integer, required: true
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

    assigns = assign(assigns, :series_tooltip_data, series_tooltip_data)

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
    >
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="flex items-center gap-2 min-w-0">
          <span class={["font-medium", @compact && "text-xs", not @compact && "text-sm"]}>
            {@data.title}
          </span>
        </div>
        <div class="flex items-center gap-3">
          <%= for series <- @data.series do %>
            <div class="flex items-center gap-1">
              <span
                class="inline-block size-2 rounded-full shrink-0"
                style={"background-color: #{series.stroke}"}
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
              <line x1={@chart_pad} x2={@chart_width - @chart_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_pad} y2={@chart_height - @chart_pad} />
            <% end %>
          </g>

          <g stroke="currentColor" class="text-base-content/40">
            <line x1={@chart_pad} x2={@chart_pad} y1={@chart_pad} y2={@chart_height - @chart_pad} />
            <line
              x1={@chart_pad}
              x2={@chart_width - @chart_pad}
              y1={@chart_height - @chart_pad}
              y2={@chart_height - @chart_pad}
            />
          </g>

          <g stroke="currentColor" class="text-base-content/40">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@chart_pad - 3} x2={@chart_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_height - @chart_pad} y2={@chart_height - @chart_pad + 3} />
            <% end %>
          </g>

          <g class="text-[8px] fill-base-content/70 font-mono">
            <%= for {y, label} <- @data.y_ticks do %>
              <text x={@chart_pad - 4} y={y + 3} text-anchor="end">{label}</text>
            <% end %>
          </g>

          <g class="text-[8px] fill-base-content/70 font-mono">
            <%= for {x, label} <- @data.x_ticks do %>
              <text x={x} y={@chart_height - 2} text-anchor="middle">{label}</text>
            <% end %>
          </g>

          <%= for series <- @data.series do %>
            <path d={series.paths.area} fill={"url(#combined-fill-#{@id}-#{series.idx})"} />
            <path
              d={series.paths.line}
              fill="none"
              stroke={series.stroke}
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
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

      <div class={[
        "flex items-center justify-between text-base-content/50 mt-1 gap-4",
        @compact && "text-[10px]",
        not @compact && "text-xs"
      ]}>
        <%= for series <- @data.series do %>
          <div class="flex items-center gap-1">
            <span
              class="inline-block size-1.5 rounded-full"
              style={"background-color: #{series.stroke}"}
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

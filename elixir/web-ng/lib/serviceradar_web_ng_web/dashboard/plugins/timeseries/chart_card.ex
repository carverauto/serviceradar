defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.ChartCard do
  @moduledoc false

  use Phoenix.Component

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics

  @series_encodings [
    %{shape: :circle, label: "Circle", dasharray: nil},
    %{shape: :square, label: "Square", dasharray: "6 4"},
    %{shape: :triangle, label: "Triangle", dasharray: "2 3"},
    %{shape: :diamond, label: "Diamond", dasharray: "8 3 2 3"},
    %{shape: :line, label: "Line", dasharray: "10 4"},
    %{shape: :cross, label: "Cross", dasharray: "3 2 1 2"}
  ]

  def series_encoding(idx) when is_integer(idx) do
    Enum.at(@series_encodings, Integer.mod(idx, length(@series_encodings)))
  end

  def series_encoding(_idx), do: series_encoding(0)

  attr :color, :string, required: true
  attr :encoding, :map, required: true
  attr :class, :any, default: "size-3"

  def series_marker(assigns) do
    ~H"""
    <svg
      class={["shrink-0", @class]}
      viewBox="0 0 12 12"
      role="img"
      aria-label={"#{@encoding.label} series marker"}
      data-testid="timeseries-series-marker"
      data-series-shape={@encoding.shape}
    >
      <title>{@encoding.label} series marker</title>
      <circle :if={@encoding.shape == :circle} cx="6" cy="6" r="4" fill={@color} />
      <rect :if={@encoding.shape == :square} x="2" y="2" width="8" height="8" rx="1" fill={@color} />
      <path :if={@encoding.shape == :triangle} d="M6 1.8 11 10.2H1Z" fill={@color} />
      <path :if={@encoding.shape == :diamond} d="M6 1.5 10.5 6 6 10.5 1.5 6Z" fill={@color} />
      <line
        :if={@encoding.shape == :line}
        x1="1"
        y1="6"
        x2="11"
        y2="6"
        stroke={@color}
        stroke-width="2.5"
        stroke-linecap="round"
      />
      <g
        :if={@encoding.shape == :cross}
        stroke={@color}
        stroke-width="2.2"
        stroke-linecap="round"
      >
        <line x1="3" y1="3" x2="9" y2="9" />
        <line x1="9" y1="3" x2="3" y2="9" />
      </g>
    </svg>
    """
  end

  attr :annotations, :list, required: true
  attr :chart_top_pad, :integer, required: true
  attr :chart_bottom_pad, :integer, required: true
  attr :chart_height, :integer, required: true
  attr :compact, :boolean, default: false

  def annotation_markers_svg(assigns) do
    ~H"""
    <g
      :if={@annotations != []}
      data-testid="timeseries-annotations"
      stroke-linecap="round"
    >
      <%= for annotation <- @annotations do %>
        <line
          data-testid="timeseries-annotation"
          data-annotation-label={annotation.label}
          data-annotation-severity={annotation.severity}
          x1={annotation.x}
          x2={annotation.x}
          y1={@chart_top_pad}
          y2={@chart_height - @chart_bottom_pad}
          stroke={annotation.color}
          stroke-width="1.5"
          stroke-dasharray="4 3"
          opacity="0.85"
        >
          <title>{annotation.title}</title>
        </line>
        <circle
          cx={annotation.x}
          cy={@chart_top_pad + 4}
          r={if @compact, do: 2.5, else: 3.5}
          fill={annotation.color}
          opacity="0.95"
        >
          <title>{annotation.title}</title>
        </circle>
      <% end %>
    </g>
    """
  end

  attr :reference_lines, :list, required: true
  attr :chart_left_pad, :integer, required: true
  attr :chart_right_pad, :integer, required: true
  attr :chart_width, :integer, required: true

  def reference_lines_svg(assigns) do
    ~H"""
    <g
      :if={@reference_lines != []}
      data-testid="timeseries-reference-lines"
      stroke-linecap="round"
    >
      <%= for reference_line <- @reference_lines do %>
        <line
          data-testid="timeseries-reference-line"
          data-reference-label={reference_line.label}
          data-reference-severity={reference_line.severity}
          data-reference-series={reference_line.series}
          x1={@chart_left_pad}
          x2={@chart_width - @chart_right_pad}
          y1={reference_line.y}
          y2={reference_line.y}
          stroke={reference_line.color}
          stroke-width="1.5"
          stroke-dasharray="6 3"
          opacity="0.9"
        >
          <title>{reference_line.title}</title>
        </line>
      <% end %>
    </g>
    """
  end

  attr :id, :string, required: true
  attr :data, :map, required: true
  attr :chart_width, :integer, required: true
  attr :chart_height, :integer, required: true
  attr :chart_left_pad, :integer, required: true
  attr :chart_right_pad, :integer, required: true
  attr :chart_top_pad, :integer, required: true
  attr :chart_bottom_pad, :integer, required: true
  attr :compact, :boolean, default: false

  def chart_card(assigns) do
    assigns = assign(assigns, :encoding, series_encoding(assigns.data.idx))

    ~H"""
    <div
      id={"chart-#{@id}-#{@data.idx}"}
      class={[
        "rounded-lg border border-base-200 bg-base-100 relative group",
        @compact && "p-3",
        not @compact && "p-4"
      ]}
      phx-hook="TimeseriesChart"
      data-points={Jason.encode!(@data.point_data)}
      data-unit={Metrics.unit_to_string(@data.unit)}
      data-y-min={@data.chart_min}
      data-y-max={@data.chart_max}
      data-y-scale={@data.y_scale}
      data-chart-width={@chart_width}
      data-chart-left-pad={@chart_left_pad}
      data-chart-right-pad={@chart_right_pad}
    >
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="flex items-center gap-2 min-w-0">
          <.series_marker color={@data.stroke} encoding={@encoding} />
          <span class={["font-medium truncate", @compact && "text-xs", not @compact && "text-sm"]}>
            {@data.series}
          </span>
          <span
            :if={@data.utilization}
            class={["badge badge-xs font-mono", Metrics.utilization_badge_class(@data.utilization)]}
            title={"#{@data.utilization}% of interface capacity"}
          >
            {@data.utilization}%
          </span>
        </div>
        <div class={[
          "text-base-content/60 font-mono shrink-0",
          @compact && "text-[10px]",
          not @compact && "text-xs"
        ]}>
          <span style={"color: #{@data.stroke}"}>
            {Metrics.format_value(@data.paths.latest, @data.unit)}
          </span>
        </div>
      </div>

      <div class="relative">
        <svg
          viewBox={"0 0 #{@chart_width} #{@chart_height}"}
          class={["w-full", @compact && "h-24", not @compact && "h-32"]}
          preserveAspectRatio="none"
        >
          <defs>
            <linearGradient id={"series-fill-#{@id}-#{@data.idx}"} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stop-color={@data.stroke} stop-opacity="0.3" />
              <stop offset="100%" stop-color={@data.stroke} stop-opacity="0.05" />
            </linearGradient>
          </defs>

          <g stroke="currentColor" class="text-base-content/10" stroke-dasharray="3 4">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@chart_left_pad} x2={@chart_width - @chart_right_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_top_pad} y2={@chart_height - @chart_bottom_pad} />
            <% end %>
          </g>

          <g stroke="currentColor" class="text-base-content/40">
            <line
              x1={@chart_left_pad}
              x2={@chart_left_pad}
              y1={@chart_top_pad}
              y2={@chart_height - @chart_bottom_pad}
            />
            <line
              x1={@chart_left_pad}
              x2={@chart_width - @chart_right_pad}
              y1={@chart_height - @chart_bottom_pad}
              y2={@chart_height - @chart_bottom_pad}
            />
          </g>

          <g stroke="currentColor" class="text-base-content/40">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@chart_left_pad - 3} x2={@chart_left_pad} y1={y} y2={y} />
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

          <g class="text-[8px] fill-base-content/70 font-mono">
            <%= for {y, label} <- @data.y_ticks do %>
              <text x={@chart_left_pad - 8} y={y + 3} text-anchor="end">{label}</text>
            <% end %>
          </g>

          <g class="text-[8px] fill-base-content/70 font-mono">
            <%= for {x, label} <- @data.x_ticks do %>
              <text x={x} y={@chart_height - 2} text-anchor="middle">{label}</text>
            <% end %>
          </g>

          <.annotation_markers_svg
            annotations={@data.annotations}
            chart_top_pad={@chart_top_pad}
            chart_bottom_pad={@chart_bottom_pad}
            chart_height={@chart_height}
            compact={@compact}
          />

          <.reference_lines_svg
            reference_lines={@data.reference_lines}
            chart_left_pad={@chart_left_pad}
            chart_right_pad={@chart_right_pad}
            chart_width={@chart_width}
          />

          <path d={@data.paths.area} fill={"url(#series-fill-#{@id}-#{@data.idx})"} />
          <path
            d={@data.paths.line}
            fill="none"
            stroke={@data.stroke}
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-dasharray={@encoding.dasharray}
            data-series-shape={@encoding.shape}
          />
        </svg>

        <div
          class="absolute hidden pointer-events-none bg-base-300 text-base-content text-xs px-2 py-1 rounded shadow-lg z-10 font-mono whitespace-nowrap"
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
        "flex items-center justify-between text-base-content/50 mt-1",
        @compact && "text-[10px]",
        not @compact && "text-xs"
      ]}>
        <span>
          avg: <span class="font-mono">{Metrics.format_value(@data.paths.avg, @data.unit)}</span>
        </span>
        <span :if={@data.max_speed} class="text-base-content/40">
          interface rate:
          <span class="font-mono">{Metrics.format_value(@data.max_speed, :bytes_per_sec)}</span>
        </span>
        <span>
          peak: <span class="font-mono">{Metrics.format_value(@data.paths.max, @data.unit)}</span>
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

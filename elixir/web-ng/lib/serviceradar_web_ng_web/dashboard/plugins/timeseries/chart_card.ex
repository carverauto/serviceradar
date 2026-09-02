defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.ChartCard do
  @moduledoc false

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [user_time: 1]
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics

  @series_encodings [
    %{shape: :circle, label: "Circle"},
    %{shape: :square, label: "Square"},
    %{shape: :triangle, label: "Triangle"},
    %{shape: :diamond, label: "Diamond"},
    %{shape: :line, label: "Line"},
    %{shape: :cross, label: "Cross"}
  ]

  def series_encoding(idx) when is_integer(idx) do
    Enum.at(@series_encodings, Integer.mod(idx, length(@series_encodings)))
  end

  def series_encoding(_idx), do: series_encoding(0)

  def annotation_window_notice(annotations) when is_list(annotations) do
    Enum.find_value(annotations, fn
      %{window_position: :before_window, label: label} ->
        "#{label} is before this chart window; the marker is clamped to the left edge."

      %{window_position: :after_window, label: label} ->
        "#{label} is after this chart window; the marker is clamped to the right edge."

      _annotation ->
        nil
    end)
  end

  def annotation_window_notice(_annotations), do: nil

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
      <%= for annotation <- @annotations, is_number(Map.get(annotation, :window_x1)) and is_number(Map.get(annotation, :window_x2)) do %>
        <rect
          data-testid="timeseries-annotation-window"
          data-annotation-label={annotation.label}
          data-annotation-severity={annotation.severity}
          data-time-title-iso={Map.get(annotation, :time_iso)}
          x={annotation.window_x1}
          y={@chart_top_pad}
          width={max(annotation.window_x2 - annotation.window_x1, 1)}
          height={@chart_height - @chart_top_pad - @chart_bottom_pad}
          fill={annotation.color}
          opacity="0.12"
        >
          <title>{annotation.title}</title>
        </rect>
      <% end %>
      <%= for annotation <- @annotations do %>
        <line
          data-testid="timeseries-annotation"
          data-annotation-label={annotation.label}
          data-annotation-severity={annotation.severity}
          data-annotation-window-position={Map.get(annotation, :window_position, :in_window)}
          data-time-title-iso={Map.get(annotation, :time_iso)}
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
          data-time-title-iso={Map.get(annotation, :time_iso)}
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

  attr :overlays, :list, required: true
  attr :chart_left_pad, :integer, required: true
  attr :chart_right_pad, :integer, required: true
  attr :chart_top_pad, :integer, required: true
  attr :chart_bottom_pad, :integer, required: true
  attr :chart_width, :integer, required: true
  attr :chart_height, :integer, required: true
  attr :compact, :boolean, default: false

  def chart_overlays_svg(assigns) do
    ~H"""
    <g
      :if={@overlays != []}
      data-testid="timeseries-chart-overlays"
      pointer-events="none"
      stroke-linecap="round"
    >
      <%= for overlay <- @overlays do %>
        <rect
          :if={is_number(Map.get(overlay, :window_x1)) and is_number(Map.get(overlay, :window_x2))}
          data-testid="timeseries-anomaly-window"
          data-overlay-label={overlay.label}
          data-overlay-severity={overlay.severity}
          data-time-title-iso={Map.get(overlay, :time_iso)}
          x={overlay.window_x1}
          y={@chart_top_pad}
          width={max(overlay.window_x2 - overlay.window_x1, 1)}
          height={@chart_height - @chart_top_pad - @chart_bottom_pad}
          fill={overlay.color}
          opacity={if Map.get(overlay, :selected), do: "0.18", else: "0.1"}
        >
          <title>{overlay.title}</title>
        </rect>

        <rect
          :if={is_map(Map.get(overlay, :confidence))}
          data-testid="timeseries-capacity-confidence"
          data-overlay-label={overlay.label}
          data-time-title-iso={Map.get(overlay, :time_iso)}
          x={@chart_left_pad}
          y={overlay.confidence.y}
          width={@chart_width - @chart_left_pad - @chart_right_pad}
          height={overlay.confidence.height}
          fill={overlay.color}
          opacity="0.08"
        >
          <title>{overlay.title}</title>
        </rect>

        <line
          :if={is_map(Map.get(overlay, :runway))}
          data-testid="timeseries-capacity-runway"
          data-overlay-label={overlay.label}
          data-overlay-severity={overlay.severity}
          data-time-title-iso={Map.get(overlay, :time_iso)}
          x1={overlay.runway.x1}
          y1={overlay.runway.y1}
          x2={overlay.runway.x2}
          y2={overlay.runway.y2}
          stroke={overlay.color}
          stroke-width={if @compact, do: "1.5", else: "2"}
          stroke-dasharray="2 4"
          opacity="0.95"
        >
          <title>{overlay.title}</title>
        </line>

        <line
          :if={is_number(Map.get(overlay, :x))}
          data-testid="timeseries-overlay-marker"
          data-overlay-kind={overlay.kind}
          data-overlay-label={overlay.label}
          data-overlay-severity={overlay.severity}
          data-time-title-iso={Map.get(overlay, :time_iso)}
          x1={overlay.x}
          x2={overlay.x}
          y1={@chart_top_pad}
          y2={@chart_height - @chart_bottom_pad}
          stroke={overlay.color}
          stroke-width={if Map.get(overlay, :selected), do: "2.5", else: "1.5"}
          stroke-dasharray={if overlay.kind == :capacity, do: "8 4", else: "4 3"}
          opacity="0.9"
        >
          <title>{overlay.title}</title>
        </line>

        <circle
          :if={is_number(Map.get(overlay, :x)) and is_number(Map.get(overlay, :value_y))}
          data-testid="timeseries-overlay-value"
          data-overlay-label={overlay.label}
          data-time-title-iso={Map.get(overlay, :time_iso)}
          cx={overlay.x}
          cy={overlay.value_y}
          r={if Map.get(overlay, :selected), do: 4.5, else: 3.5}
          fill={overlay.color}
          stroke="currentColor"
          class="text-sr-surface"
          stroke-width="1"
          opacity="0.98"
        >
          <title>{overlay.title}</title>
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
  attr :timezone, :string, default: "Etc/UTC"

  def chart_card(assigns) do
    assigns =
      assigns
      |> assign(:encoding, series_encoding(assigns.data.idx))
      |> assign(:effective_chart_left_pad, Map.get(assigns.data, :chart_left_pad, assigns.chart_left_pad))
      |> assign(:annotation_window_notice, annotation_window_notice(Map.get(assigns.data, :annotations, [])))

    ~H"""
    <div
      id={"chart-#{@id}-#{@data.idx}"}
      class={[
        "rounded-lg border border-sr-line bg-sr-surface relative group",
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
      data-chart-left-pad={@effective_chart_left_pad}
      data-chart-right-pad={@chart_right_pad}
      data-timezone={@timezone}
    >
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="flex items-center gap-2 min-w-0">
          <.series_marker color={@data.stroke} encoding={@encoding} />
          <span class={["font-medium truncate", @compact && "text-xs", not @compact && "text-sm"]}>
            {@data.series}
          </span>
          <.ui_badge
            :if={@data.utilization}
            size="xs"
            variant={Metrics.utilization_badge_variant(@data.utilization)}
            class="font-mono"
            title={"#{@data.utilization}% of interface capacity"}
          >
            {@data.utilization}%
          </.ui_badge>
          <.ui_badge
            :if={Map.get(@data, :overlays, []) != []}
            size="xs"
            variant="outline"
            title={"#{length(@data.overlays)} chart overlays"}
          >
            {length(@data.overlays)}
          </.ui_badge>
        </div>
        <div class={[
          "text-sr-muted font-mono shrink-0",
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
          data-chart-svg
        >
          <defs>
            <linearGradient id={"series-fill-#{@id}-#{@data.idx}"} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stop-color={@data.stroke} stop-opacity="0.3" />
              <stop offset="100%" stop-color={@data.stroke} stop-opacity="0.05" />
            </linearGradient>
          </defs>

          <g stroke="currentColor" class="text-sr-ink/10" stroke-dasharray="3 4">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@effective_chart_left_pad} x2={@chart_width - @chart_right_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_top_pad} y2={@chart_height - @chart_bottom_pad} />
            <% end %>
          </g>

          <g stroke="currentColor" class="text-sr-muted">
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

          <g stroke="currentColor" class="text-sr-muted">
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

          <g class="text-[12px] fill-sr-muted font-mono">
            <%= for {y, label} <- @data.y_ticks do %>
              <text x={@effective_chart_left_pad - 10} y={y + 4} text-anchor="end">{label}</text>
            <% end %>
          </g>

          <g class="text-[11px] fill-sr-muted font-mono">
            <%= for {x, instant} <- @data.x_ticks do %>
              <text
                x={x}
                y={@chart_height - 4}
                text-anchor="middle"
                data-time-axis-iso={instant}
              >
                {instant}
              </text>
            <% end %>
          </g>

          <.annotation_markers_svg
            annotations={@data.annotations}
            chart_top_pad={@chart_top_pad}
            chart_bottom_pad={@chart_bottom_pad}
            chart_height={@chart_height}
            compact={@compact}
          />

          <.chart_overlays_svg
            overlays={Map.get(@data, :overlays, [])}
            chart_left_pad={@effective_chart_left_pad}
            chart_right_pad={@chart_right_pad}
            chart_top_pad={@chart_top_pad}
            chart_bottom_pad={@chart_bottom_pad}
            chart_width={@chart_width}
            chart_height={@chart_height}
            compact={@compact}
          />

          <.reference_lines_svg
            reference_lines={@data.reference_lines}
            chart_left_pad={@effective_chart_left_pad}
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
            data-series-shape={@encoding.shape}
          />
        </svg>

        <div
          class="absolute hidden pointer-events-none bg-sr-control text-sr-ink text-xs px-2 py-1 rounded shadow-lg z-10 font-mono whitespace-nowrap"
          data-tooltip
        >
        </div>
        <div
          class="absolute hidden pointer-events-none w-px bg-sr-muted/30 top-0 bottom-0"
          data-hover-line
        >
        </div>
      </div>

      <div
        :if={@annotation_window_notice}
        data-testid="timeseries-marker-window-note"
        class="mt-1 text-[10px] leading-snug text-sr-muted"
      >
        {@annotation_window_notice}
      </div>

      <div class={[
        "flex items-center justify-between text-sr-muted mt-1",
        @compact && "text-[10px]",
        not @compact && "text-xs"
      ]}>
        <span>
          avg: <span class="font-mono">{Metrics.format_value(@data.paths.avg, @data.unit)}</span>
        </span>
        <span :if={@data.max_speed} class="text-sr-muted">
          interface rate:
          <span class="font-mono">{Metrics.format_value(@data.max_speed, :bytes_per_sec)}</span>
        </span>
        <span>
          peak: <span class="font-mono">{Metrics.format_value(@data.paths.max, @data.unit)}</span>
        </span>
      </div>
      <div class={[
        "flex items-center justify-between text-sr-muted mt-1 font-mono",
        @compact && "text-[9px]",
        not @compact && "text-[10px]"
      ]}>
        <.user_time
          id={"timeseries-#{@id}-series-#{series_dom_id(@data)}-first-time"}
          value={@data.first_dt}
          timezone={@timezone}
          style={:compact}
        />
        <.user_time
          id={"timeseries-#{@id}-series-#{series_dom_id(@data)}-last-time"}
          value={@data.last_dt}
          timezone={@timezone}
          style={:compact}
        />
      </div>
    </div>
    """
  end

  defp series_dom_id(data) do
    series =
      data
      |> Map.get(:raw_series, Map.get(data, :series, "series"))
      |> to_string()

    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, series) do
      "s-#{series}"
    else
      "e-#{Base.url_encode64(series, padding: false)}"
    end
  end
end

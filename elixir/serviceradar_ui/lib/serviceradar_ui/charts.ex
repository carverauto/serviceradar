defmodule ServiceRadarUI.Charts do
  @moduledoc """
  Charts rendered as SVG on the server: sparkline, area (time series), bar,
  donut and gauge.

  They are plain HEEx and need no JavaScript. Each chart sizes itself with SVG
  `viewBox`, `width` and `height` attributes and is coloured by classes from
  `priv/css/components.css`, so the output is safe under `style-src 'self'`.

  Colours come from a `tone` (`"brand"`, `"success"`, `"warning"`, `"danger"`,
  `"info"`, `"neutral"`) or, for multi-series charts, from the six-colour
  `--sr-color-chart-*` palette.

  Two charts have client-side behaviour through the hooks bundle:

    * `area/1` with `interactive` attaches `SrTimeseries`, which adds a hover
      line and tooltip and shows axis times in the viewer's time zone.
    * `live_sparkline/1` attaches `SrSparkline`, which redraws when you send
      new points with `ServiceRadarUI.push_update/3`.
  """

  use Phoenix.Component

  alias ServiceRadarUI.Charts.Format
  alias ServiceRadarUI.Charts.Geometry

  @tones ~w(brand success warning danger info neutral)

  @doc "The tone names charts accept."
  def tones, do: @tones

  ## Sparkline

  @doc """
  Renders a small trend line.

  `values` is a list of numbers, `%{value: n}` / `%{v: n}` maps or
  `{time, value}` tuples, spaced evenly. `nil` values leave a gap.

      <.sparkline values={[3, 5, 4, 8, 6]} tone="success" label="Latency, last hour" />
  """
  attr :values, :list, default: []
  attr :tone, :string, default: "brand", values: @tones
  attr :smooth, :boolean, default: true
  attr :fill, :boolean, default: true
  attr :min, :any, default: nil, doc: "fixed lower bound for the y axis"
  attr :max, :any, default: nil, doc: "fixed upper bound for the y axis"
  attr :label, :string, default: nil, doc: "accessible title; the chart is decorative without one"
  attr :width, :any, default: nil, doc: "rendered width attribute"
  attr :height, :any, default: nil, doc: "rendered height attribute"
  attr :class, :any, default: nil
  attr :rest, :global

  def sparkline(assigns) do
    assigns = assign(assigns, sparkline_paths(assigns.values, assigns))

    ~H"""
    <svg
      class={["sr-chart", "sr-chart-sparkline", "sr-tone-#{@tone}", @class]}
      viewBox="0 0 100 32"
      preserveAspectRatio="none"
      width={@width}
      height={@height}
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={is_nil(@label) && "true"}
      focusable="false"
      {@rest}
    >
      <title :if={@label}>{@label}</title>
      <line
        :if={@line_path == ""}
        class="sr-chart-baseline"
        x1="0"
        x2="100"
        y1="28"
        y2="28"
        vector-effect="non-scaling-stroke"
        data-sr-baseline
      />
      <path :if={@fill} class="sr-chart-area-fill" d={@area_path} data-sr-area />
      <path class="sr-chart-line" d={@line_path} vector-effect="non-scaling-stroke" data-sr-line />
    </svg>
    """
  end

  @doc false
  def sparkline_paths(values, opts) do
    numbers = Geometry.numbers(values)
    domain = Geometry.domain(numbers, opts[:min], opts[:max])
    count = length(List.wrap(values))
    x = fn i -> if count > 1, do: i * 100 / (count - 1), else: 50.0 end
    y = fn v -> Geometry.scale(v, domain, {28.0, 4.0}) end
    segments = Geometry.segments(values, x, y)
    smooth? = Map.get(Map.new(opts), :smooth, true)

    %{
      line_path:
        if(smooth?, do: Geometry.smooth_path(segments), else: Geometry.line_path(segments)),
      area_path: Geometry.area_path(segments, 32.0, smooth?)
    }
  end

  @doc """
  Renders a sparkline that the `SrSparkline` hook redraws when the server
  pushes new points with `ServiceRadarUI.push_update/3`:

      <.live_sparkline id="ingest-rate" values={@initial} tone="info" />

      socket |> ServiceRadarUI.push_update("ingest-rate", %{values: values})

  The first render is the same server-side SVG `sparkline/1` produces, so it
  shows data before the hook connects.
  """
  attr :id, :string, required: true
  attr :values, :list, default: []
  attr :tone, :string, default: "brand", values: @tones
  attr :smooth, :boolean, default: true
  attr :fill, :boolean, default: true
  attr :min, :any, default: nil
  attr :max, :any, default: nil
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def live_sparkline(assigns) do
    assigns = assign(assigns, :json, Jason.encode!(Geometry.numbers_with_gaps(assigns.values)))

    ~H"""
    <div
      id={@id}
      class={["sr-chart-live", @class]}
      phx-hook="SrSparkline"
      data-values={@json}
      data-smooth={to_string(@smooth)}
      data-min={@min}
      data-max={@max}
      {@rest}
    >
      <.sparkline
        values={@values}
        tone={@tone}
        smooth={@smooth}
        fill={@fill}
        min={@min}
        max={@max}
        label={@label}
      />
    </div>
    """
  end

  ## Area / time series

  @doc """
  Renders a time-series chart with axes and an area or line per series.

  Give either `points` for one series or `series` for several. Points are
  `{time, value}` tuples or `%{t: time, v: value}` maps, where `time` is a
  `DateTime`, `NaiveDateTime` (UTC), Unix milliseconds or an ISO 8601 string.

      <.area id="cpu" points={@cpu} unit="percent" min={0} max={100} label="CPU" />

      <.area
        id="traffic"
        interactive
        unit="bits_per_sec"
        timezone={@user_timezone}
        series={[
          %{name: "In", points: @rx},
          %{name: "Out", points: @tx}
        ]}
      />

  Axis labels are rendered in UTC. With `interactive`, the `SrTimeseries`
  hook relabels them in `timezone` (an IANA name; the browser's own zone
  when nil) using `time_format`, and adds a hover line and tooltip.
  """
  attr :id, :string, required: true
  attr :points, :list, default: nil
  attr :series, :list, default: nil, doc: "list of %{name:, points:, tone: (optional)}"
  attr :unit, :string, default: "number", values: Format.units()
  attr :tone, :string, default: "brand", values: @tones, doc: "colour of a single series"
  attr :fill, :boolean, default: true
  attr :smooth, :boolean, default: false
  attr :min, :any, default: nil
  attr :max, :any, default: nil
  attr :interactive, :boolean, default: false
  attr :timezone, :string, default: nil, doc: "IANA zone used by the hook for labels and tooltips"
  attr :time_format, :string, default: "auto", values: ~w(auto time datetime date)

  attr :locale, :string,
    default: nil,
    doc: "BCP 47 locale used by the hook; browser default when nil"

  attr :label, :string, default: nil

  attr :height, :integer,
    default: 240,
    doc: "viewBox height; the width is 800 and the chart scales uniformly"

  attr :legend, :boolean, default: nil, doc: "show a legend; defaults to true for several series"
  attr :class, :any, default: nil
  attr :rest, :global

  @area_width 800
  @area_pad %{left: 64, right: 16, top: 12, bottom: 28}

  def area(assigns) do
    assigns = assign(assigns, area_model(assigns))

    ~H"""
    <figure
      id={@id}
      class={["sr-chart", "sr-chart-area", @class]}
      phx-hook={@interactive && "SrTimeseries"}
      data-points={@interactive && @hover_json}
      data-unit={@unit}
      data-timezone={@timezone}
      data-time-format={@time_format}
      data-locale={@locale}
      data-chart-width={@width}
      data-chart-left-pad={@pad.left}
      data-chart-right-pad={@pad.right}
      {@rest}
    >
      <div class="sr-chart-frame">
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          width="100%"
          role="img"
          aria-label={@label || "Time series"}
          focusable="false"
          data-chart-svg
        >
          <title>{@label || "Time series"}</title>
          <g class="sr-chart-grid" aria-hidden="true">
            <line
              :for={tick <- @y_ticks}
              x1={@pad.left}
              x2={@width - @pad.right}
              y1={tick.y}
              y2={tick.y}
            />
          </g>
          <g class="sr-chart-axis" aria-hidden="true">
            <text
              :for={tick <- @y_ticks}
              x={@pad.left - 8}
              y={tick.y}
              class="sr-chart-axis-label"
              text-anchor="end"
              dominant-baseline="middle"
            >
              {tick.label}
            </text>
            <text
              :for={tick <- @x_ticks}
              x={tick.x}
              y={@height - 8}
              class="sr-chart-axis-label"
              text-anchor={tick.anchor}
              data-sr-time={tick.iso}
            >
              {tick.label}
            </text>
          </g>
          <g :for={s <- @series_paths} class={["sr-chart-series", s.class]}>
            <path :if={@fill} class="sr-chart-area-fill" d={s.area} />
            <path class="sr-chart-line" d={s.line} />
          </g>
          <line
            :if={@interactive}
            class="sr-chart-hover-line"
            x1="0"
            x2="0"
            y1={@pad.top}
            y2={@height - @pad.bottom}
            visibility="hidden"
            data-hover-line
          />
        </svg>
        <div :if={@interactive} class="sr-chart-tooltip" role="status" hidden data-tooltip></div>
      </div>
      <figcaption :if={@show_legend} class="sr-chart-legend">
        <span :for={s <- @series_paths} class={["sr-chart-legend-item", s.class]}>
          <span class="sr-chart-legend-swatch" aria-hidden="true"></span>{s.name}
        </span>
      </figcaption>
    </figure>
    """
  end

  defp area_model(assigns) do
    series = normalize_series(assigns)
    pad = @area_pad
    all_points = Enum.flat_map(series, & &1.points)
    times = Enum.map(all_points, &elem(&1, 0))
    values = all_points |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    {t0, t1} = time_domain(times)

    {lo, hi} =
      case Geometry.domain(values, assigns.min, assigns.max) do
        domain when is_number(assigns.min) and is_number(assigns.max) -> domain
        domain -> Geometry.nice_domain(domain)
      end

    x = fn t -> Geometry.scale(t, {t0, t1}, {pad.left, @area_width - pad.right}) end
    y = fn v -> Geometry.scale(v, {lo, hi}, {assigns.height - pad.bottom, pad.top}) end
    baseline = y.(max(lo, min(hi, 0.0)))

    series_paths =
      series
      |> Enum.with_index(1)
      |> Enum.map(fn {s, idx} ->
        segments = time_segments(s.points, x, y)

        %{
          name: s.name,
          class: series_class(s, idx, length(series), assigns.tone),
          line:
            if(assigns.smooth,
              do: Geometry.smooth_path(segments),
              else: Geometry.line_path(segments)
            ),
          area: Geometry.area_path(segments, baseline, assigns.smooth)
        }
      end)

    %{
      width: @area_width,
      pad: pad,
      series_paths: series_paths,
      show_legend: if(is_nil(assigns.legend), do: length(series) > 1, else: assigns.legend),
      y_ticks:
        {lo, hi}
        |> Geometry.nice_ticks(4)
        |> Enum.map(&%{y: Geometry.fmt(y.(&1)), label: Format.value(&1, assigns.unit)}),
      x_ticks: x_ticks({t0, t1}, x),
      hover_json: hover_json(series, x)
    }
  end

  defp normalize_series(%{series: series}) when is_list(series) and series != [] do
    series
    |> Enum.with_index(1)
    |> Enum.map(fn {s, idx} ->
      s = Map.new(s)

      %{
        name: to_string(s[:name] || s[:label] || "Series #{idx}"),
        tone: s[:tone],
        points: normalize_points(s[:points] || [])
      }
    end)
  end

  defp normalize_series(%{points: points}) when is_list(points),
    do: [%{name: "Value", tone: nil, points: normalize_points(points)}]

  defp normalize_series(_assigns), do: []

  defp normalize_points(points) do
    points
    |> Enum.map(fn
      {t, v} -> {Format.to_datetime(t), Geometry.value(v)}
      %{} = p -> {Format.to_datetime(p[:t] || p[:time] || p["t"]), Geometry.value(p)}
      _other -> {nil, nil}
    end)
    |> Enum.reject(fn {t, _v} -> is_nil(t) end)
    |> Enum.sort_by(fn {t, _v} -> DateTime.to_unix(t, :millisecond) end)
    |> Enum.map(fn {t, v} -> {DateTime.to_unix(t, :millisecond), v} end)
  end

  defp time_domain([]), do: {0, 1}
  defp time_domain(times), do: Enum.min_max(times)

  defp time_segments(points, x, y) do
    points
    |> Enum.chunk_by(fn {_t, v} -> is_nil(v) end)
    |> Enum.reject(fn [{_t, v} | _] -> is_nil(v) end)
    |> Enum.map(fn chunk -> Enum.map(chunk, fn {t, v} -> {x.(t), y.(v)} end) end)
  end

  defp series_class(%{tone: tone}, _idx, _count, _default) when tone in @tones,
    do: "sr-tone-#{tone}"

  defp series_class(_s, _idx, 1, default), do: "sr-tone-#{default}"
  defp series_class(_s, idx, _count, _default), do: "sr-series-#{rem(idx - 1, 6) + 1}"

  defp x_ticks({t0, t1}, _x) when t1 <= t0, do: []

  defp x_ticks({t0, t1}, x) do
    span = t1 - t0

    Enum.map(0..4, fn i ->
      t = round(t0 + span * i / 4)
      dt = DateTime.from_unix!(t, :millisecond)

      %{
        x: Geometry.fmt(x.(t)),
        iso: DateTime.to_iso8601(dt),
        label: Format.axis_time(dt, span),
        anchor:
          case i do
            0 -> "start"
            4 -> "end"
            _ -> "middle"
          end
      }
    end)
  end

  defp hover_json(series, x) do
    series
    |> Enum.flat_map(fn s -> Enum.map(s.points, fn {t, _v} -> t end) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn t ->
      %{
        x: Float.round(x.(t) * 1.0, 2),
        t: t |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
        v: Enum.map(series, fn s -> series_value_at(s.points, t) end)
      }
    end)
    |> then(&%{series: Enum.map(series, fn s -> s.name end), points: &1})
    |> Jason.encode!()
  end

  defp series_value_at(points, t) do
    Enum.find_value(points, fn
      {^t, v} -> v
      _other -> nil
    end)
  end

  ## Bar

  @doc """
  Renders a bar chart of labelled values.

      <.bar data={[%{label: "eth0", value: 120}, %{label: "eth1", value: 80}]} unit="bits_per_sec" />
      <.bar orientation="horizontal" data={@top_talkers} label="Top talkers" />

  Each item may set a `tone`; otherwise bars use the chart `tone`.
  """
  attr :data, :list, required: true, doc: "list of %{label:, value:, tone: (optional)}"
  attr :orientation, :string, default: "vertical", values: ~w(vertical horizontal)
  attr :unit, :string, default: "number", values: Format.units()
  attr :tone, :string, default: "brand", values: @tones
  attr :max, :any, default: nil, doc: "fixed upper bound"
  attr :show_values, :boolean, default: true
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def bar(assigns) do
    assigns = assign(assigns, bar_model(assigns))

    ~H"""
    <svg
      class={["sr-chart", "sr-chart-bar", "sr-chart-bar-#{@orientation}", @class]}
      viewBox={"0 0 #{@vb_width} #{@vb_height}"}
      width="100%"
      role="img"
      aria-label={@label || "Bar chart"}
      focusable="false"
      {@rest}
    >
      <title>{@label || "Bar chart"}</title>
      <g :for={bar <- @bars} class={["sr-chart-bar-item", "sr-tone-#{bar.tone}"]}>
        <title>{bar.label}: {bar.display}</title>
        <rect
          class="sr-chart-bar-track"
          x={bar.track_x}
          y={bar.track_y}
          width={bar.track_w}
          height={bar.track_h}
          rx="3"
        />
        <rect class="sr-chart-bar-value" x={bar.x} y={bar.y} width={bar.w} height={bar.h} rx="3" />
        <text
          class="sr-chart-axis-label"
          x={bar.label_x}
          y={bar.label_y}
          text-anchor={bar.label_anchor}
          dominant-baseline="middle"
        >
          {bar.label}
        </text>
        <text
          :if={@show_values}
          class="sr-chart-value-label"
          x={bar.value_x}
          y={bar.value_y}
          text-anchor={bar.value_anchor}
          dominant-baseline="middle"
        >
          {bar.display}
        </text>
      </g>
    </svg>
    """
  end

  defp bar_model(%{orientation: "horizontal"} = assigns) do
    items = bar_items(assigns)
    max_value = bar_max(items, assigns.max)
    row = 28
    label_w = 120
    value_w = if assigns.show_values, do: 80, else: 0
    width = 480
    plot = width - label_w - value_w - 8
    height = max(length(items), 1) * row

    bars =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, i} ->
        cy = i * row + row / 2

        w =
          Geometry.scale(
            min(max(item.value, 0.0), max_value),
            {0.0, max_value},
            {0.0, plot * 1.0}
          )

        Map.merge(item, %{
          track_x: label_w,
          track_y: Geometry.fmt(cy - 7.0),
          track_w: plot,
          track_h: 14,
          x: label_w,
          y: Geometry.fmt(cy - 7.0),
          w: Geometry.fmt(w),
          h: 14,
          label_x: label_w - 8,
          label_y: Geometry.fmt(cy),
          label_anchor: "end",
          value_x: label_w + plot + 8,
          value_y: Geometry.fmt(cy),
          value_anchor: "start"
        })
      end)

    %{bars: bars, vb_width: width, vb_height: height}
  end

  defp bar_model(assigns) do
    items = bar_items(assigns)
    max_value = bar_max(items, assigns.max)
    count = max(length(items), 1)
    slot = 48
    width = count * slot
    top = if assigns.show_values, do: 16, else: 4
    plot = 120
    height = top + plot + 20

    bars =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, i} ->
        cx = i * slot + slot / 2

        h =
          Geometry.scale(
            min(max(item.value, 0.0), max_value),
            {0.0, max_value},
            {0.0, plot * 1.0}
          )

        Map.merge(item, %{
          track_x: Geometry.fmt(cx - 14.0),
          track_y: top,
          track_w: 28,
          track_h: plot,
          x: Geometry.fmt(cx - 14.0),
          y: Geometry.fmt(top + plot - h),
          w: 28,
          h: Geometry.fmt(h),
          label_x: Geometry.fmt(cx),
          label_y: top + plot + 11,
          label_anchor: "middle",
          value_x: Geometry.fmt(cx),
          value_y: Geometry.fmt(max(top + plot - h - 8, 6.0)),
          value_anchor: "middle"
        })
      end)

    %{bars: bars, vb_width: width, vb_height: height}
  end

  defp bar_items(assigns) do
    Enum.map(assigns.data, fn item ->
      item = Map.new(item)
      value = Geometry.value(item) || 0.0

      %{
        label: to_string(item[:label] || ""),
        value: value,
        display: Format.value(value, assigns.unit),
        tone: if(item[:tone] in @tones, do: item[:tone], else: assigns.tone)
      }
    end)
  end

  defp bar_max(_items, max) when is_number(max) and max > 0, do: max * 1.0

  defp bar_max(items, _max) do
    case items |> Enum.map(& &1.value) |> Enum.max(fn -> 0.0 end) do
      v when v > 0 -> v
      _ -> 1.0
    end
  end

  ## Donut

  @doc """
  Renders a donut chart with an optional centre value and a legend.

      <.donut
        label="Devices by status"
        data={[%{label: "Up", value: 120, tone: "success"}, %{label: "Down", value: 4, tone: "danger"}]}
        center_value="124"
        center_label="devices"
      />

  Items without a `tone` take colours from the chart palette in order.
  """
  attr :data, :list, required: true, doc: "list of %{label:, value:, tone: (optional)}"
  attr :unit, :string, default: "number", values: Format.units()
  attr :thickness, :integer, default: 14
  attr :center_value, :string, default: nil
  attr :center_label, :string, default: nil
  attr :legend, :boolean, default: true
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def donut(assigns) do
    assigns = assign(assigns, :segments, donut_segments(assigns))

    ~H"""
    <figure class={["sr-chart", "sr-chart-donut", @class]} {@rest}>
      <svg
        viewBox="0 0 100 100"
        width="100%"
        role="img"
        aria-label={@label || "Donut chart"}
        focusable="false"
      >
        <title>{@label || "Donut chart"}</title>
        <circle
          class="sr-chart-donut-track"
          cx="50"
          cy="50"
          r={50 - @thickness / 2}
          stroke-width={@thickness}
          fill="none"
        />
        <g :for={seg <- @segments} class={["sr-chart-donut-segment", seg.class]}>
          <title>{seg.label}: {seg.display}</title>
          <path :if={seg.path} d={seg.path} />
          <circle
            :if={seg.full}
            cx="50"
            cy="50"
            r={50 - @thickness / 2}
            stroke-width={@thickness}
            fill="none"
          />
        </g>
        <text
          :if={@center_value}
          class="sr-chart-donut-value"
          x="50"
          y={if @center_label, do: "48", else: "52"}
          text-anchor="middle"
          dominant-baseline="middle"
        >
          {@center_value}
        </text>
        <text
          :if={@center_label}
          class="sr-chart-donut-caption"
          x="50"
          y="62"
          text-anchor="middle"
          dominant-baseline="middle"
        >
          {@center_label}
        </text>
      </svg>
      <figcaption :if={@legend and @segments != []} class="sr-chart-legend">
        <span :for={seg <- @segments} class={["sr-chart-legend-item", seg.class]}>
          <span class="sr-chart-legend-swatch" aria-hidden="true"></span>{seg.label}
          <span class="sr-chart-legend-value">{seg.display}</span>
        </span>
      </figcaption>
    </figure>
    """
  end

  defp donut_segments(assigns) do
    items =
      assigns.data
      |> Enum.map(&Map.new/1)
      |> Enum.map(fn item -> Map.put(item, :num, max(Geometry.value(item) || 0.0, 0.0)) end)

    total = items |> Enum.map(& &1.num) |> Enum.sum()
    outer = 50.0
    inner = outer - assigns.thickness
    tau = 2 * :math.pi()

    {segments, _angle} =
      items
      |> Enum.with_index(1)
      |> Enum.map_reduce(0.0, fn {item, idx}, angle ->
        sweep = if total > 0, do: item.num / total * tau, else: 0.0

        segment = %{
          label: to_string(item[:label] || ""),
          display: Format.value(item.num, assigns.unit),
          class:
            if(item[:tone] in @tones,
              do: "sr-tone-#{item[:tone]}",
              else: "sr-series-#{rem(idx - 1, 6) + 1}"
            ),
          full: sweep >= tau - 1.0e-6,
          path:
            if(sweep > 0 and sweep < tau - 1.0e-6,
              do: Geometry.arc_path({50.0, 50.0}, outer, inner, angle, angle + sweep)
            )
        }

        {segment, angle + sweep}
      end)

    segments
  end

  ## Gauge

  @doc """
  Renders a half-circle gauge.

  The tone follows `warn` and `crit` thresholds when given (higher is worse;
  set `invert` when lower is worse), otherwise `tone`.

      <.gauge value={72.5} max={100} unit="percent" warn={70} crit={90} label="Disk" />
  """
  attr :value, :any, required: true
  attr :min, :any, default: 0
  attr :max, :any, default: 100
  attr :unit, :string, default: "number", values: Format.units()
  attr :warn, :any, default: nil
  attr :crit, :any, default: nil
  attr :invert, :boolean, default: false
  attr :tone, :string, default: "brand", values: @tones
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def gauge(assigns) do
    assigns = assign(assigns, gauge_model(assigns))

    ~H"""
    <svg
      class={["sr-chart", "sr-chart-gauge", "sr-tone-#{@resolved_tone}", @class]}
      viewBox="0 0 120 72"
      width="100%"
      role="meter"
      aria-label={@label || "Gauge"}
      aria-valuemin={@min}
      aria-valuemax={@max}
      aria-valuenow={@num}
      aria-valuetext={@display}
      focusable="false"
      {@rest}
    >
      <title>{@label || "Gauge"}: {@display}</title>
      <path class="sr-chart-gauge-track" d={@track_path} />
      <path :if={@value_path} class="sr-chart-gauge-value" d={@value_path} />
      <text class="sr-chart-gauge-display" x="60" y="56" text-anchor="middle">{@display}</text>
      <text :if={@label} class="sr-chart-gauge-label" x="60" y="69" text-anchor="middle">
        {@label}
      </text>
    </svg>
    """
  end

  defp gauge_model(assigns) do
    lo = Geometry.value(assigns.min) || 0.0
    hi = Geometry.value(assigns.max) || 100.0
    hi = if hi > lo, do: hi, else: lo + 1.0
    num = Geometry.value(assigns.value)
    clamped = if num, do: min(max(num, lo), hi), else: lo
    start = -:math.pi() / 2
    sweep = Geometry.scale(clamped, {lo, hi}, {0.0, :math.pi()})
    center = {60.0, 60.0}

    %{
      num: num,
      display: Format.value(num, assigns.unit),
      resolved_tone: gauge_tone(num, assigns),
      track_path: Geometry.arc_path(center, 52.0, 40.0, start, start + :math.pi()),
      value_path:
        if(sweep > 0.001, do: Geometry.arc_path(center, 52.0, 40.0, start, start + sweep))
    }
  end

  defp gauge_tone(nil, _assigns), do: "neutral"

  defp gauge_tone(num, %{warn: warn, crit: crit, invert: invert, tone: tone}) do
    past? = fn threshold ->
      is_number(threshold) and if(invert, do: num <= threshold, else: num >= threshold)
    end

    cond do
      past?.(crit) -> "danger"
      past?.(warn) -> "warning"
      is_number(warn) or is_number(crit) -> "success"
      true -> tone
    end
  end
end

defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Sparkline do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr(:spark, :map, required: true)

  def icmp_sparkline(assigns) do
    points = Map.get(assigns.spark, :points, [])
    {stroke_path, area_path} = sparkline_smooth_paths(points)

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:latest_ms, Map.get(assigns.spark, :latest_ms, 0.0))
      |> assign(:tone, Map.get(assigns.spark, :tone, "success"))
      |> assign(:title, Map.get(assigns.spark, :title))
      |> assign(:stroke_path, stroke_path)
      |> assign(:area_path, area_path)
      |> assign(:stroke_color, tone_stroke(Map.get(assigns.spark, :tone, "success")))
      |> assign(:spark_id, "spark-#{:erlang.phash2(Map.get(assigns.spark, :title, ""))}")

    ~H"""
    <div class="flex items-center gap-2">
      <div class="h-8 w-20 rounded-md bg-sr-subtle/30 px-1 py-0.5 overflow-hidden">
        <svg viewBox="0 0 400 120" class="w-full h-full" preserveAspectRatio="none">
          <title>{@title || "ICMP latency"}</title>
          <defs>
            <linearGradient id={@spark_id} x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stop-color={@stroke_color} stop-opacity="0.5" />
              <stop offset="95%" stop-color={@stroke_color} stop-opacity="0.05" />
            </linearGradient>
          </defs>
          <path d={@area_path} fill={"url(##{@spark_id})"} />
          <path
            d={@stroke_path}
            fill="none"
            stroke={@stroke_color}
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </div>
      <div class="tabular-nums text-[11px] font-bold text-sr-ink">
        {format_ms(@latest_ms)}
      </div>
    </div>
    """
  end

  defp tone_stroke("error"), do: "#EF4444"
  defp tone_stroke("warning"), do: "#F59E0B"
  defp tone_stroke("success"), do: "#22C55E"
  defp tone_stroke(_), do: "#64748B"

  defp format_ms(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1) <> "ms"
  end

  defp format_ms(value) when is_integer(value), do: Integer.to_string(value) <> "ms"
  defp format_ms(_), do: "—"

  # Generate smooth SVG paths using monotone cubic interpolation (Catmull-Rom spline)
  defp sparkline_smooth_paths(values) when is_list(values) do
    values = Enum.filter(values, &is_number/1)

    case {values, Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)} do
      {[], _, _} ->
        {"", ""}

      {[_single], _, _} ->
        # Single point - just draw a small line
        {"M 200,60 L 200,60", ""}

      {_values, min_v, max_v} ->
        # Normalize values to coordinates
        range = if max_v == min_v, do: 1.0, else: max_v - min_v
        len = length(values)

        coords =
          values
          |> Enum.with_index()
          |> Enum.map(fn {v, idx} ->
            x = idx_to_x(idx, len)
            y = 110.0 - (v - min_v) / range * 100.0
            {x * 1.0, y}
          end)

        stroke_path = monotone_curve_path(coords)
        area_path = monotone_area_path(coords)
        {stroke_path, area_path}
    end
  end

  defp sparkline_smooth_paths(_), do: {"", ""}

  # Monotone cubic interpolation for smooth curves that don't overshoot
  defp monotone_curve_path([]), do: ""
  defp monotone_curve_path([{x, y}]), do: "M #{fmt(x)},#{fmt(y)}"

  defp monotone_curve_path(coords) do
    [{x0, y0} | _rest] = coords
    tangents = compute_tangents(coords)

    # Start with first point
    segments = ["M #{fmt(x0)},#{fmt(y0)}"]

    # Build cubic bezier segments
    curve_segments =
      [coords, tl(coords), tangents, tl(tangents)]
      |> Enum.zip()
      |> Enum.map(fn {{x0, y0}, {x1, y1}, t0, t1} ->
        dx = (x1 - x0) / 3.0
        cp1x = x0 + dx
        cp1y = y0 + t0 * dx
        cp2x = x1 - dx
        cp2y = y1 - t1 * dx
        "C #{fmt(cp1x)},#{fmt(cp1y)} #{fmt(cp2x)},#{fmt(cp2y)} #{fmt(x1)},#{fmt(y1)}"
      end)

    Enum.join(segments ++ curve_segments, " ")
  end

  defp monotone_area_path([]), do: ""
  defp monotone_area_path([_]), do: ""

  defp monotone_area_path(coords) do
    [{first_x, _} | _] = coords
    {last_x, _} = List.last(coords)
    baseline = 115.0

    stroke = monotone_curve_path(coords)
    "#{stroke} L #{fmt(last_x)},#{fmt(baseline)} L #{fmt(first_x)},#{fmt(baseline)} Z"
  end

  # Compute tangents for monotone interpolation
  defp compute_tangents(coords) when length(coords) < 2, do: []

  defp compute_tangents(coords) do
    # Compute slopes between consecutive points
    slopes =
      coords
      |> Enum.zip(tl(coords))
      |> Enum.map(fn {{x0, y0}, {x1, y1}} ->
        dx = x1 - x0
        if dx == 0, do: 0.0, else: (y1 - y0) / dx
      end)

    # Compute tangents using monotone method
    n = length(coords)

    Enum.map(0..(n - 1), fn i ->
      tangent_for_index(i, n, slopes)
    end)
  end

  defp tangent_for_index(0, _n, slopes), do: Enum.at(slopes, 0) || 0.0
  defp tangent_for_index(i, n, slopes) when i == n - 1, do: List.last(slopes) || 0.0

  defp tangent_for_index(i, _n, slopes) do
    s0 = Enum.at(slopes, i - 1) || 0.0
    s1 = Enum.at(slopes, i) || 0.0

    if s0 * s1 <= 0 do
      0.0
    else
      2.0 * s0 * s1 / (s0 + s1)
    end
  end

  defp fmt(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp fmt(num) when is_integer(num), do: Integer.to_string(num)

  defp idx_to_x(_idx, 0), do: 0
  defp idx_to_x(0, _len), do: 0

  defp idx_to_x(idx, len) when len > 1 do
    round(idx / (len - 1) * 400)
  end
end

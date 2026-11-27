defmodule ServiceRadarUI.Charts.Geometry do
  @moduledoc false
  # Pure path and scale helpers shared by the SVG charts. Coordinates are in
  # the chart's viewBox units. Kept public (but undocumented) so it can be
  # tested directly.

  @doc "Coerces chart input to a number, or nil for a gap."
  def value(%{value: v}), do: value(v)
  def value(%{v: v}), do: value(v)
  def value(%{"value" => v}), do: value(v)
  def value(%{"v" => v}), do: value(v)
  def value({_t, v}), do: value(v)
  def value(v) when is_integer(v), do: v * 1.0
  def value(v) when is_float(v), do: v
  def value(_v), do: nil

  @doc "Each chart input as a number, keeping nil for gaps."
  def numbers_with_gaps(values), do: values |> List.wrap() |> Enum.map(&value/1)

  @doc "The finite numbers in a list of chart inputs."
  def numbers(values), do: values |> List.wrap() |> Enum.map(&value/1) |> Enum.reject(&is_nil/1)

  @doc """
  Returns `{min, max}` for the values, widened so a flat series still has a
  non-zero range. Explicit bounds win.
  """
  def domain(numbers, min \\ nil, max \\ nil)

  def domain([], min, max), do: {min || 0.0, max || 1.0}

  def domain(numbers, min, max) do
    lo = if is_number(min), do: min * 1.0, else: Enum.min(numbers)
    hi = if is_number(max), do: max * 1.0, else: Enum.max(numbers)

    if hi > lo, do: {lo, hi}, else: {lo - 0.5, hi + 0.5}
  end

  @doc "Linear map of `v` from `{d0, d1}` to `{r0, r1}`."
  def scale(v, {d0, d1}, {r0, r1}) when d1 != d0, do: r0 + (v - d0) / (d1 - d0) * (r1 - r0)
  def scale(_v, _domain, {r0, r1}), do: (r0 + r1) / 2

  @doc """
  Splits indexed chart inputs into contiguous segments of `{x, y}` points,
  breaking at gaps (nil values). `x_fun` maps an index to x and `y_fun` maps a
  number to y.
  """
  def segments(values, x_fun, y_fun) do
    values
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.chunk_by(fn {v, _i} -> is_nil(value(v)) end)
    |> Enum.reject(fn [{v, _i} | _] -> is_nil(value(v)) end)
    |> Enum.map(fn chunk -> Enum.map(chunk, fn {v, i} -> {x_fun.(i), y_fun.(value(v))} end) end)
  end

  @doc "A straight-line path through the points of each segment."
  def line_path(segments) do
    segments
    |> Enum.map(&segment_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp segment_line([]), do: ""
  defp segment_line([{x, y}]), do: "M#{fmt(x - 1.0)},#{fmt(y)} L#{fmt(x + 1.0)},#{fmt(y)}"

  defp segment_line([{x0, y0} | rest]) do
    Enum.join(
      ["M#{fmt(x0)},#{fmt(y0)}" | Enum.map(rest, fn {x, y} -> "L#{fmt(x)},#{fmt(y)}" end)],
      " "
    )
  end

  @doc """
  A monotone cubic path through the points of each segment. It does not
  overshoot the data, so a smoothed line never dips below zero.
  """
  def smooth_path(segments) do
    segments
    |> Enum.map(&segment_smooth/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp segment_smooth(points) when length(points) < 3, do: segment_line(points)

  defp segment_smooth([{x0, y0} | _] = points) do
    tangents = tangents(points)

    curves =
      [points, tl(points), tangents, tl(tangents)]
      |> Enum.zip()
      |> Enum.map(fn {{xa, ya}, {xb, yb}, ta, tb} ->
        dx = (xb - xa) / 3.0

        "C#{fmt(xa + dx)},#{fmt(ya + ta * dx)} #{fmt(xb - dx)},#{fmt(yb - tb * dx)} #{fmt(xb)},#{fmt(yb)}"
      end)

    Enum.join(["M#{fmt(x0)},#{fmt(y0)}" | curves], " ")
  end

  defp tangents(points) do
    slopes =
      points
      |> Enum.zip(tl(points))
      |> Enum.map(fn {{xa, ya}, {xb, yb}} ->
        if xb == xa, do: 0.0, else: (yb - ya) / (xb - xa)
      end)

    n = length(points)
    slope_tuple = List.to_tuple(slopes)

    Enum.map(0..(n - 1), fn
      0 -> elem(slope_tuple, 0)
      i when i == n - 1 -> elem(slope_tuple, n - 2)
      i -> harmonic(elem(slope_tuple, i - 1), elem(slope_tuple, i))
    end)
  end

  defp harmonic(s0, s1) when s0 * s1 <= 0, do: 0.0
  defp harmonic(s0, s1), do: 2.0 * s0 * s1 / (s0 + s1)

  @doc "Closes each segment's line down to `baseline_y`, for an area fill."
  def area_path(segments, baseline_y, smooth?) do
    segments
    |> Enum.reject(&(length(&1) < 2))
    |> Enum.map_join(" ", fn [{x0, _} | _] = points ->
      {xn, _} = List.last(points)
      top = if smooth?, do: segment_smooth(points), else: segment_line(points)
      "#{top} L#{fmt(xn)},#{fmt(baseline_y)} L#{fmt(x0)},#{fmt(baseline_y)} Z"
    end)
  end

  @doc """
  Up to about `count` round tick values covering `{lo, hi}`, using steps of
  1, 2 or 5 times a power of ten.
  """
  def nice_ticks({lo, hi}, count \\ 4) when hi > lo do
    step = nice_step((hi - lo) / max(count, 1))
    first = Float.ceil(lo / step) * step

    first
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 <= hi + step * 1.0e-9))
    |> Enum.map(&clean_zero/1)
  end

  @doc "Expands `{lo, hi}` outward to the nearest nice ticks."
  def nice_domain({lo, hi}, count \\ 4) when hi > lo do
    step = nice_step((hi - lo) / max(count, 1))
    {clean_zero(Float.floor(lo / step) * step), clean_zero(Float.ceil(hi / step) * step)}
  end

  defp nice_step(raw) when raw > 0 do
    magnitude = :math.pow(10, Float.floor(:math.log10(raw)))
    residual = raw / magnitude

    cond do
      residual <= 1.0 -> magnitude
      residual <= 2.0 -> 2 * magnitude
      residual <= 5.0 -> 5 * magnitude
      true -> 10 * magnitude
    end
  end

  defp nice_step(_raw), do: 1.0

  defp clean_zero(v) when v == 0, do: 0.0
  defp clean_zero(v), do: v

  @doc """
  Path for an annular sector between `start` and `stop` angles (radians,
  clockwise from 12 o'clock).
  """
  def arc_path({cx, cy}, outer, inner, start, stop) do
    large = if stop - start > :math.pi(), do: 1, else: 0
    {x0, y0} = polar({cx, cy}, outer, start)
    {x1, y1} = polar({cx, cy}, outer, stop)
    {x2, y2} = polar({cx, cy}, inner, stop)
    {x3, y3} = polar({cx, cy}, inner, start)

    "M#{fmt(x0)},#{fmt(y0)} A#{fmt(outer)},#{fmt(outer)} 0 #{large} 1 #{fmt(x1)},#{fmt(y1)} " <>
      "L#{fmt(x2)},#{fmt(y2)} A#{fmt(inner)},#{fmt(inner)} 0 #{large} 0 #{fmt(x3)},#{fmt(y3)} Z"
  end

  @doc "Point at `radius` and `angle` (radians, clockwise from 12 o'clock)."
  def polar({cx, cy}, radius, angle),
    do: {cx + radius * :math.sin(angle), cy - radius * :math.cos(angle)}

  @doc "Formats a coordinate with at most two decimals."
  def fmt(num) when is_integer(num), do: Integer.to_string(num)

  def fmt(num) when is_float(num) do
    rounded = Float.round(num, 2)

    if rounded == Float.round(rounded),
      do: rounded |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(rounded, [:compact, decimals: 2])
  end
end

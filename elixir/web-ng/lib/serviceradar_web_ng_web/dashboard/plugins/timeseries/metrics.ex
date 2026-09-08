defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics do
  @moduledoc false

  @counter_max_32 4_294_967_295.0
  @counter_max_64 18_446_744_073_709_551_615.0
  @rollover_floor_ratio 0.9
  @counter_rate_drop_event [:serviceradar, :web_ng, :timeseries, :counter_rate, :dropped]

  def counter_rates(series_points, max_speed) when is_list(series_points) do
    Enum.map(series_points, fn entry ->
      {series, points, metadata} = normalize_counter_series(entry)
      sorted_points = Enum.sort_by(points, fn {dt, _v} -> dt end)
      effective_max = if traffic_series?(series), do: max_speed

      {series, counter_rate_points(series, sorted_points, metadata, effective_max)}
    end)
  end

  def counter_rates(series_points, _max_speed), do: series_points

  def series_color(index) do
    colors = [
      {"#3B82F6", "rgba(59,130,246,0.25)"},
      {"#38BDF8", "rgba(56,189,248,0.25)"},
      {"#8B5CF6", "rgba(139,92,246,0.25)"},
      {"#22C55E", "rgba(34,197,94,0.25)"},
      {"#F59E0B", "rgba(245,158,11,0.25)"},
      {"#EC4899", "rgba(236,72,153,0.25)"}
    ]

    Enum.at(colors, rem(index, length(colors)))
  end

  def scale_max_for_unit(:percent), do: 100.0
  def scale_max_for_unit(_), do: nil

  def unit_for_series(series, spec, rate_mode) do
    explicit_unit = spec_series_unit(spec, series)

    cond do
      rate_mode == :counter ->
        if traffic_series?(series), do: :bytes_per_sec, else: :count_per_sec

      rate_mode == :rate and traffic_series?(series) ->
        :bytes_per_sec

      explicit_unit != nil ->
        explicit_unit

      percent_field?(spec) ->
        :percent

      bytes_field?(spec) ->
        :bytes

      hz_field?(spec) ->
        :hz

      true ->
        :number
    end
  end

  def combined_unit(series_data) when is_list(series_data) do
    series_data
    |> Enum.map(&Map.get(&1, :unit))
    |> Enum.uniq()
    |> case do
      [unit] -> unit
      _ -> :number
    end
  end

  def unit_to_string(unit) do
    case unit do
      :percent -> "percent"
      :bytes_per_sec -> "bytes_per_sec"
      :bits_per_sec -> "bits_per_sec"
      :bytes -> "bytes"
      :hz -> "hz"
      :count_per_sec -> "count_per_sec"
      _ -> "number"
    end
  end

  def format_value(v, unit) when is_float(v) or is_integer(v) do
    value = v * 1.0

    case unit do
      :percent -> "#{Float.round(value, 1)}%"
      :bytes_per_sec -> format_bytes_per_sec(value)
      :bits_per_sec -> format_bits_per_sec(value)
      :bytes -> format_bytes(value)
      :hz -> format_hz(value)
      :count_per_sec -> format_count_per_sec(value)
      _ -> format_number(value)
    end
  end

  def format_value(_, _), do: "—"

  def humanize_series_name(name) when is_binary(name) do
    humanize_base_series_name(series_base_name(name))
  end

  def humanize_series_name(name), do: name

  def traffic_series?(name) when is_binary(name) do
    series_base_name(name) in ["ifInOctets", "ifOutOctets", "ifHCInOctets", "ifHCOutOctets"]
  end

  def traffic_series?(_), do: false

  def compute_utilization(value, max_speed) when is_number(value) and is_number(max_speed) and max_speed > 0 do
    percentage = value / max_speed * 100
    Float.round(percentage, 1)
  end

  def compute_utilization(_, _), do: nil

  def utilization_badge_variant(pct) when pct >= 90, do: "error"
  def utilization_badge_variant(pct) when pct >= 75, do: "warning"
  def utilization_badge_variant(pct) when pct >= 50, do: "info"
  def utilization_badge_variant(_), do: "success"

  defp humanize_base_series_name("ifInOctets"), do: "Inbound Traffic"
  defp humanize_base_series_name("ifOutOctets"), do: "Outbound Traffic"
  defp humanize_base_series_name("ifInErrors"), do: "Inbound Errors"
  defp humanize_base_series_name("ifOutErrors"), do: "Outbound Errors"
  defp humanize_base_series_name("ifInDiscards"), do: "Inbound Discards"
  defp humanize_base_series_name("ifOutDiscards"), do: "Outbound Discards"
  defp humanize_base_series_name("ifInUcastPkts"), do: "Inbound Packets"
  defp humanize_base_series_name("ifOutUcastPkts"), do: "Outbound Packets"
  defp humanize_base_series_name("ifHCInOctets"), do: "Inbound Traffic"
  defp humanize_base_series_name("ifHCOutOctets"), do: "Outbound Traffic"
  defp humanize_base_series_name("ifHCInUcastPkts"), do: "Inbound Packets"
  defp humanize_base_series_name("ifHCOutUcastPkts"), do: "Outbound Packets"
  defp humanize_base_series_name(name), do: name

  defp series_base_name(name) when is_binary(name) do
    case String.split(name, "::", parts: 2) do
      [base | _] -> base
      _ -> name
    end
  end

  defp series_base_name(name), do: name

  defp normalize_counter_series({series, points}), do: {series, normalize_points(points), %{}}

  defp normalize_counter_series({series, points, metadata}) when is_map(metadata) do
    {series, normalize_points(points), metadata}
  end

  defp normalize_counter_series(%{} = entry) do
    series =
      Map.get(entry, :series) || Map.get(entry, "series") || Map.get(entry, :name) ||
        Map.get(entry, "name") || "series"

    points = Map.get(entry, :points) || Map.get(entry, "points") || []

    {series, normalize_points(points), entry}
  end

  defp normalize_counter_series(entry), do: {to_string(entry || "series"), [], %{}}

  defp normalize_points(points) when is_list(points), do: points
  defp normalize_points(_), do: []

  defp counter_rate_points(series, points, metadata, max_speed) do
    {_prev, acc} =
      Enum.reduce(points, {nil, []}, fn point, state ->
        counter_rate_step(series, point, state, metadata, max_speed)
      end)

    Enum.reverse(acc)
  end

  defp counter_rate_step(series, {dt, value}, {nil, acc}, metadata, _max_speed) when is_number(value) do
    emit_counter_rate_drop(series, :warmup, dt, metadata)
    {{dt, value}, acc}
  end

  defp counter_rate_step(series, {dt, value}, {{prev_dt, prev_value}, acc}, metadata, max_speed) do
    diff = DateTime.diff(dt, prev_dt, :second)

    case counter_rate(diff, value, prev_value, metadata, max_speed) do
      {:ok, rate} ->
        {{dt, value}, [{dt, rate} | acc]}

      {:gap, reason} when is_number(value) ->
        emit_counter_rate_drop(series, reason, dt, metadata)
        {{dt, value}, [{dt, nil} | acc]}

      {:gap, reason} ->
        emit_counter_rate_drop(series, reason, dt, metadata)
        {nil, [{dt, nil} | acc]}
    end
  end

  defp counter_rate_step(series, {dt, _value}, state, metadata, _max_speed) do
    emit_counter_rate_drop(series, :non_numeric, dt, metadata)
    state
  end

  defp counter_rate(diff, _value, _prev_value, _metadata, _max_speed) when diff <= 0, do: {:gap, :non_monotonic_time}

  defp counter_rate(diff, value, prev_value, metadata, max_speed) do
    with {:ok, delta} <- counter_delta(value, prev_value, metadata) do
      {:ok, clamp_rate(delta / diff, max_speed)}
    end
  end

  defp counter_delta(current, previous, metadata) when is_number(current) and is_number(previous) do
    if current >= previous do
      {:ok, current - previous}
    else
      rollover_delta(current, previous, metadata)
    end
  end

  defp counter_delta(_, _, _), do: {:gap, :non_numeric}

  defp rollover_delta(current, previous, metadata) do
    max_value = counter_max(metadata, previous)

    if plausible_rollover?(previous, max_value) do
      {:ok, max_value - previous + current}
    else
      {:gap, :counter_decrease}
    end
  end

  defp emit_counter_rate_drop(series, reason, at, metadata) do
    :telemetry.execute(
      @counter_rate_drop_event,
      %{count: 1},
      %{
        series: series,
        reason: reason,
        at: at,
        counter_width: counter_width(metadata)
      }
    )
  end

  defp plausible_rollover?(previous, max_value) when is_number(previous) and is_number(max_value) and max_value > 0 do
    previous >= max_value * @rollover_floor_ratio
  end

  defp plausible_rollover?(_previous, _max_value), do: false

  defp counter_max(metadata, previous) do
    case counter_width(metadata) do
      32 -> @counter_max_32
      64 -> @counter_max_64
      _ when previous > @counter_max_32 -> @counter_max_64
      _ -> @counter_max_32
    end
  end

  defp counter_width(metadata) when is_map(metadata) do
    metadata
    |> counter_width_candidates()
    |> Enum.find_value(&normalize_counter_width/1)
  end

  defp counter_width_candidates(metadata) do
    nested_metadata =
      metadata
      |> Map.get(:metadata, Map.get(metadata, "metadata", %{}))
      |> metadata_map()

    [
      Map.get(metadata, :counter_width),
      Map.get(metadata, "counter_width"),
      Map.get(metadata, :counter_bits),
      Map.get(metadata, "counter_bits"),
      Map.get(metadata, :pdu_width),
      Map.get(metadata, "pdu_width"),
      Map.get(nested_metadata, :counter_width),
      Map.get(nested_metadata, "counter_width"),
      Map.get(nested_metadata, :counter_bits),
      Map.get(nested_metadata, "counter_bits"),
      Map.get(nested_metadata, :pdu_width),
      Map.get(nested_metadata, "pdu_width")
    ]
  end

  defp metadata_map(value) when is_map(value), do: value
  defp metadata_map(_), do: %{}

  defp normalize_counter_width(value) when value in [32, 64], do: value

  defp normalize_counter_width(value) when is_float(value) and value in [32.0, 64.0] do
    trunc(value)
  end

  defp normalize_counter_width(value) when is_binary(value) do
    case Integer.parse(value) do
      {width, ""} when width in [32, 64] -> width
      _ -> nil
    end
  end

  defp normalize_counter_width(_), do: nil

  defp clamp_rate(rate, max_speed) when is_number(rate) and is_number(max_speed) and max_speed > 0 do
    if rate > max_speed, do: max_speed, else: rate
  end

  defp clamp_rate(rate, _max_speed), do: rate

  defp spec_series_unit(%{series_units: units}, series) when is_map(units) do
    Map.get(units, series) || Map.get(units, to_string(series || ""))
  end

  defp spec_series_unit(%{"series_units" => units}, series) when is_map(units) do
    Map.get(units, series) || Map.get(units, to_string(series || ""))
  end

  defp spec_series_unit(_spec, _series), do: nil

  defp percent_field?(%{y: y}) when is_binary(y), do: String.contains?(y, "percent")
  defp percent_field?(_), do: false

  defp bytes_field?(%{y: y}) when is_binary(y), do: String.contains?(y, "bytes")
  defp bytes_field?(_), do: false

  defp hz_field?(%{y: y}) when is_binary(y), do: String.contains?(y, "hz")
  defp hz_field?(_), do: false

  defp format_number(value) do
    if abs(value) >= 1_000 do
      value |> Float.round(1) |> to_string()
    else
      value |> Float.round(2) |> to_string()
    end
  end

  defp format_bytes_per_sec(bps) when bps >= 1_000_000_000, do: "#{Float.round(bps / 1_000_000_000, 2)} GB/s"
  defp format_bytes_per_sec(bps) when bps >= 1_000_000, do: "#{Float.round(bps / 1_000_000, 2)} MB/s"
  defp format_bytes_per_sec(bps) when bps >= 1_000, do: "#{Float.round(bps / 1_000, 2)} KB/s"
  defp format_bytes_per_sec(bps) when bps >= 0, do: "#{Float.round(bps, 1)} B/s"
  defp format_bytes_per_sec(bps), do: "#{Float.round(bps, 2)}"

  defp format_bits_per_sec(bps) when bps >= 1_000_000_000, do: "#{Float.round(bps / 1_000_000_000, 2)} Gbit/s"
  defp format_bits_per_sec(bps) when bps >= 1_000_000, do: "#{Float.round(bps / 1_000_000, 2)} Mbit/s"
  defp format_bits_per_sec(bps) when bps >= 1_000, do: "#{Float.round(bps / 1_000, 2)} Kbit/s"
  defp format_bits_per_sec(bps) when bps >= 0, do: "#{Float.round(bps, 1)} bit/s"
  defp format_bits_per_sec(bps), do: "#{Float.round(bps, 2)}"

  defp format_bytes(bytes) when bytes >= 1_000_000_000, do: "#{Float.round(bytes / 1_000_000_000, 2)} GB"
  defp format_bytes(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 2)} MB"
  defp format_bytes(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 2)} KB"
  defp format_bytes(bytes) when bytes >= 0, do: "#{Float.round(bytes, 1)} B"
  defp format_bytes(bytes), do: "#{Float.round(bytes, 2)}"

  defp format_hz(value) when value >= 1_000_000_000, do: "#{Float.round(value / 1_000_000_000, 2)} GHz"
  defp format_hz(value) when value >= 1_000_000, do: "#{Float.round(value / 1_000_000, 2)} MHz"
  defp format_hz(value) when value >= 1_000, do: "#{Float.round(value / 1_000, 2)} KHz"
  defp format_hz(value) when value >= 0, do: "#{Float.round(value, 1)} Hz"
  defp format_hz(value), do: "#{Float.round(value, 2)}"

  defp format_count_per_sec(value) when value >= 1_000_000, do: "#{Float.round(value / 1_000_000, 2)} M/s"
  defp format_count_per_sec(value) when value >= 1_000, do: "#{Float.round(value / 1_000, 2)} K/s"
  defp format_count_per_sec(value) when value >= 0, do: "#{Float.round(value, 2)} /s"
  defp format_count_per_sec(value), do: "#{Float.round(value, 2)} /s"
end

defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics do
  @moduledoc false

  @counter_max_32 4_294_967_295.0
  @counter_max_64 18_446_744_073_709_551_615.0

  def counter_rates(series_points, max_speed) when is_list(series_points) do
    Enum.map(series_points, fn {series, points} ->
      sorted_points = Enum.sort_by(points, fn {dt, _v} -> dt end)
      {series, counter_rate_points(sorted_points, series, max_speed)}
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

  def humanize_series_name("ifInOctets"), do: "Inbound Traffic"
  def humanize_series_name("ifOutOctets"), do: "Outbound Traffic"
  def humanize_series_name("ifInErrors"), do: "Inbound Errors"
  def humanize_series_name("ifOutErrors"), do: "Outbound Errors"
  def humanize_series_name("ifInDiscards"), do: "Inbound Discards"
  def humanize_series_name("ifOutDiscards"), do: "Outbound Discards"
  def humanize_series_name("ifInUcastPkts"), do: "Inbound Packets"
  def humanize_series_name("ifOutUcastPkts"), do: "Outbound Packets"
  def humanize_series_name("ifHCInOctets"), do: "Inbound Traffic (64-bit)"
  def humanize_series_name("ifHCOutOctets"), do: "Outbound Traffic (64-bit)"
  def humanize_series_name(name), do: name

  def traffic_series?("ifInOctets"), do: true
  def traffic_series?("ifOutOctets"), do: true
  def traffic_series?("ifHCInOctets"), do: true
  def traffic_series?("ifHCOutOctets"), do: true
  def traffic_series?(_), do: false

  def compute_utilization(value, max_speed) when is_number(value) and is_number(max_speed) and max_speed > 0 do
    percentage = value / max_speed * 100
    Float.round(percentage, 1)
  end

  def compute_utilization(_, _), do: nil

  def utilization_badge_class(pct) when pct >= 90, do: "badge-error"
  def utilization_badge_class(pct) when pct >= 75, do: "badge-warning"
  def utilization_badge_class(pct) when pct >= 50, do: "badge-info"
  def utilization_badge_class(_), do: "badge-success"

  defp counter_rate_points(points, series, max_speed) do
    {_prev, acc} =
      Enum.reduce(points, {nil, []}, fn point, state ->
        counter_rate_step(point, state, series, max_speed)
      end)

    Enum.reverse(acc)
  end

  defp counter_rate_step({dt, value}, {nil, acc}, _series, _max_speed) do
    {{dt, value}, [{dt, 0.0} | acc]}
  end

  defp counter_rate_step({dt, value}, {{prev_dt, prev_value}, acc}, series, max_speed) do
    diff = DateTime.diff(dt, prev_dt, :second)
    rate = counter_rate(diff, value, prev_value, series, max_speed)
    {{dt, value}, [{dt, rate} | acc]}
  end

  defp counter_rate(diff, _value, _prev_value, _series, _max_speed) when diff <= 0, do: 0.0

  defp counter_rate(diff, value, prev_value, series, max_speed) do
    value
    |> counter_delta(prev_value, series)
    |> Kernel./(diff)
    |> clamp_rate(max_speed)
  end

  defp counter_delta(current, previous, series) when is_number(current) and is_number(previous) do
    if current >= previous do
      current - previous
    else
      rollover_delta(current, previous, series)
    end
  end

  defp counter_delta(_, _, _), do: 0.0

  defp rollover_delta(current, previous, series) do
    max_value = counter_max(series, previous)

    if max_value > previous do
      max_value - previous + current
    else
      0.0
    end
  end

  defp counter_max(series, previous) do
    series_label = to_string(series || "")

    cond do
      String.contains?(series_label, "HC") -> @counter_max_64
      previous > @counter_max_32 -> @counter_max_64
      true -> @counter_max_32
    end
  end

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

  defp format_bits_per_sec(bps) when bps >= 1_000_000_000, do: "#{Float.round(bps / 1_000_000_000, 2)} Gbps"
  defp format_bits_per_sec(bps) when bps >= 1_000_000, do: "#{Float.round(bps / 1_000_000, 2)} Mbps"
  defp format_bits_per_sec(bps) when bps >= 1_000, do: "#{Float.round(bps / 1_000, 2)} Kbps"
  defp format_bits_per_sec(bps) when bps >= 0, do: "#{Float.round(bps, 1)} bps"
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

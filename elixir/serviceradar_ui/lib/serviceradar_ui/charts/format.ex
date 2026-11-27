defmodule ServiceRadarUI.Charts.Format do
  @moduledoc """
  Value and time formatting shared by the charts. The `SrTimeseries` hook
  formats tooltip values with the same units.

  Units: `"number"` (default), `"percent"`, `"bytes"`, `"bytes_per_sec"`,
  `"bits_per_sec"`, `"count"`, `"count_per_sec"`, `"ms"`, `"hz"`.
  """

  @units ~w(number percent bytes bytes_per_sec bits_per_sec count count_per_sec ms hz)

  @doc "The supported unit names."
  def units, do: @units

  @doc """
  Formats a value for display in the given unit.

      iex> ServiceRadarUI.Charts.Format.value(1_536_000, "bytes")
      "1.54 MB"
      iex> ServiceRadarUI.Charts.Format.value(42.25, "percent")
      "42.3%"
      iex> ServiceRadarUI.Charts.Format.value(nil, "ms")
      "-"
  """
  def value(nil, _unit), do: "-"
  def value(v, unit) when is_integer(v), do: value(v * 1.0, unit)
  def value(v, "percent") when is_float(v), do: "#{decimal(v, 1)}%"
  def value(v, "bytes") when is_float(v), do: si(v, ~w(B KB MB GB TB PB), 1000)
  def value(v, "bytes_per_sec") when is_float(v), do: si(v, ~w(B KB MB GB TB PB), 1000) <> "/s"

  def value(v, "bits_per_sec") when is_float(v),
    do: si(v, ~w(bit/s Kbit/s Mbit/s Gbit/s Tbit/s), 1000)

  def value(v, "hz") when is_float(v), do: si(v, ~w(Hz KHz MHz GHz), 1000)
  def value(v, "count") when is_float(v), do: compact(v)
  def value(v, "count_per_sec") when is_float(v), do: compact(v) <> "/s"
  def value(v, "ms") when is_float(v) and v >= 1000, do: "#{decimal(v / 1000, 2)} s"
  def value(v, "ms") when is_float(v), do: "#{decimal(v, 1)} ms"
  def value(v, _unit) when is_float(v), do: compact(v)
  def value(v, _unit), do: to_string(v)

  # Scales by `base` until the value fits the unit; the first (base) unit is
  # shown without decimals ("512 B"), larger units with two ("1.54 MB").
  defp si(v, units, base, depth \\ 0)

  defp si(v, [unit], _base, depth), do: "#{decimal(v, places(depth))} #{unit}"

  defp si(v, [unit | rest], base, depth) do
    if abs(v) >= base,
      do: si(v / base, rest, base, depth + 1),
      else: "#{decimal(v, places(depth))} #{unit}"
  end

  defp places(0), do: 0
  defp places(_depth), do: 2

  defp compact(v) do
    abs = abs(v)

    cond do
      abs >= 1.0e9 -> "#{decimal(v / 1.0e9, 2)}G"
      abs >= 1.0e6 -> "#{decimal(v / 1.0e6, 2)}M"
      abs >= 1.0e4 -> "#{decimal(v / 1.0e3, 1)}K"
      abs >= 100 -> decimal(v, 0)
      true -> decimal(v, 2)
    end
  end

  @doc false
  def decimal(v, 0), do: v |> Float.round() |> trunc() |> Integer.to_string()

  def decimal(v, places) do
    v
    |> Float.round(places)
    |> :erlang.float_to_binary(decimals: places)
    |> String.replace(~r/\.?0+$/, "")
  end

  @doc """
  Normalizes a time value to a UTC `DateTime`.

  Accepts `DateTime`, `NaiveDateTime` (taken as UTC), Unix milliseconds and
  ISO 8601 strings. Returns nil for anything else.
  """
  def to_datetime(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")
  def to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  def to_datetime(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)

  def to_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.shift_zone!(dt, "Etc/UTC")
      _error -> nil
    end
  end

  def to_datetime(_value), do: nil

  @doc """
  Server-side fallback label for an axis tick, in UTC. The `SrTimeseries`
  hook replaces it with the viewer's time zone and format.
  """
  def axis_time(%DateTime{} = dt, span_ms) when span_ms > 2 * 86_400_000,
    do: Calendar.strftime(dt, "%b %d")

  def axis_time(%DateTime{} = dt, _span_ms), do: Calendar.strftime(dt, "%H:%M")
end

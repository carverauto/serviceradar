defmodule ServiceRadarWebNGWeb.DashboardLive.Window do
  @moduledoc false

  @presets [
    {"last_15m", "Last 15 minutes", 900},
    {"last_1h", "Last hour", 3_600},
    {"last_6h", "Last 6 hours", 21_600},
    {"last_24h", "Last 24 hours", 86_400},
    {"last_7d", "Last 7 days", 604_800},
    {"last_30d", "Last 30 days", 2_592_000},
    {"last_90d", "Last 90 days", 7_776_000}
  ]

  def options, do: Enum.map(@presets, fn {value, label, _} -> {value, label} end)
  def valid?(value), do: Enum.any?(@presets, &(elem(&1, 0) == value))
  def default("netflow"), do: "last_15m"
  def default("events"), do: "last_24h"
  def normalize(value, kind), do: if(valid?(value), do: value, else: default(kind))

  def resolve(value, kind, now \\ DateTime.utc_now()) do
    value = normalize(value, kind)
    {^value, label, seconds} = Enum.find(@presets, &(elem(&1, 0) == value))
    %{value: value, label: label, start: DateTime.add(now, -seconds, :second), end: now, seconds: seconds}
  end

  def label(value), do: Enum.find_value(@presets, fn {preset, label, _} -> if preset == value, do: label end)

  def query_time(%{start: start_at, end: end_at}) do
    "time:[#{DateTime.to_iso8601(start_at)},#{DateTime.to_iso8601(end_at)}]"
  end

  def event_bucket_seconds(%{seconds: seconds}) do
    Enum.find([60, 300, 900, 3_600, 21_600, 86_400], 86_400, &(seconds / &1 <= 120))
  end
end

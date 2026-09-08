defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData.Stats do
  @moduledoc false

  alias ServiceRadar.Inventory.Device

  require Ash.Query
  require Logger

  # Load device stats for cards using SRQL GROUP BY queries
  def load_device_stats(srql_module, scope) do
    default_device_stats()
    |> Map.merge(load_inventory_summary(srql_module, scope))
    |> Map.merge(load_new_device_counts(scope))
  end

  defp load_inventory_summary(srql_module, scope) do
    query = "in:devices rollup_stats:inventory_summary"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [payload | _]}} when is_map(payload) ->
        stats = parse_inventory_summary_payload(payload)
        Logger.debug("Device stats rollup parsed: #{inspect(stats)}")
        stats

      {:ok, %{"results" => [%{"payload" => payload} | _]}} when is_map(payload) ->
        # Backward compatibility if SRQL returns wrapped payload rows.
        stats = parse_inventory_summary_payload(payload)
        Logger.debug("Device stats rollup parsed (wrapped payload): #{inspect(stats)}")
        stats

      {:ok, other} ->
        Logger.warning("Device stats rollup returned unexpected payload: #{inspect(other)}")
        %{}

      {:error, reason} ->
        Logger.warning("Device stats rollup query failed: #{inspect(reason)}")
        %{}
    end
  rescue
    e ->
      Logger.error("Device stats loading failed: #{inspect(e)}")
      %{}
  end

  def default_device_stats do
    %{
      total: 0,
      available: 0,
      unavailable: 0,
      by_type: [],
      by_vendor: [],
      by_risk_level: [],
      new_today: 0,
      new_last_7d: 0,
      new_last_30d: 0
    }
  end

  # Windows match SRQL TimeFilterSpec: today = UTC midnight..now,
  # last_7d / last_30d = rolling now-N days..now. Clicking the card uses
  # the same first_seen: tokens so the list agrees with these counts.
  def new_device_windows(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    today_start = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], now.time_zone)

    [
      %{key: :new_today, token: "today", label: "Today", since: today_start, until: now},
      %{
        key: :new_last_7d,
        token: "last_7d",
        label: "7d",
        since: DateTime.add(now, -7, :day),
        until: now
      },
      %{
        key: :new_last_30d,
        token: "last_30d",
        label: "30d",
        since: DateTime.add(now, -30, :day),
        until: now
      }
    ]
  end

  defp parse_inventory_summary_payload(payload) do
    %{
      total: to_stats_int(Map.get(payload, "total")),
      available: to_stats_int(Map.get(payload, "available")),
      unavailable: to_stats_int(Map.get(payload, "unavailable")),
      by_type: parse_rollup_grouped_items(Map.get(payload, "by_type"), "type"),
      by_vendor: parse_rollup_grouped_items(Map.get(payload, "by_vendor"), "vendor_name"),
      by_risk_level: []
    }
  end

  defp load_new_device_counts(scope) do
    Map.new(new_device_windows(), fn window ->
      {window.key, count_first_seen_between(scope, window.since, window.until)}
    end)
  rescue
    e ->
      Logger.warning("New device counts failed: #{inspect(e)}")
      %{new_today: 0, new_last_7d: 0, new_last_30d: 0}
  end

  defp count_first_seen_between(scope, start_at, end_at) do
    Device
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(first_seen_time >= ^start_at and first_seen_time <= ^end_at)
    |> Ash.count(scope: scope)
    |> case do
      {:ok, count} when is_integer(count) ->
        count

      {:error, reason} ->
        Logger.warning("New device count failed: #{inspect(reason)}")
        0
    end
  end

  defp parse_rollup_grouped_items(items, key) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      %{
        name: to_string(Map.get(item, key) || "Unknown"),
        count: to_stats_int(Map.get(item, "count"))
      }
    end)
    |> Enum.filter(fn %{count: count} -> count > 0 end)
  end

  defp parse_rollup_grouped_items(_, _), do: []

  defp to_stats_int(nil), do: 0
  defp to_stats_int(value) when is_integer(value), do: value
  defp to_stats_int(value) when is_float(value), do: trunc(value)
  defp to_stats_int(%Decimal{} = value), do: Decimal.to_integer(value)

  defp to_stats_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp to_stats_int(_), do: 0
end

defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData.Stats do
  @moduledoc false

  require Logger

  # Load device stats for cards using SRQL GROUP BY queries
  def load_device_stats(srql_module, scope) do
    query = "in:devices rollup_stats:inventory_summary"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [payload | _]}} when is_map(payload) ->
        stats = %{
          total: to_stats_int(Map.get(payload, "total")),
          available: to_stats_int(Map.get(payload, "available")),
          unavailable: to_stats_int(Map.get(payload, "unavailable")),
          by_type: parse_rollup_grouped_items(Map.get(payload, "by_type"), "type"),
          by_vendor: parse_rollup_grouped_items(Map.get(payload, "by_vendor"), "vendor_name"),
          by_risk_level: []
        }

        Logger.debug("Device stats rollup parsed: #{inspect(stats)}")
        stats

      {:ok, %{"results" => [%{"payload" => payload} | _]}} when is_map(payload) ->
        # Backward compatibility if SRQL returns wrapped payload rows.
        stats = %{
          total: to_stats_int(Map.get(payload, "total")),
          available: to_stats_int(Map.get(payload, "available")),
          unavailable: to_stats_int(Map.get(payload, "unavailable")),
          by_type: parse_rollup_grouped_items(Map.get(payload, "by_type"), "type"),
          by_vendor: parse_rollup_grouped_items(Map.get(payload, "by_vendor"), "vendor_name"),
          by_risk_level: []
        }

        Logger.debug("Device stats rollup parsed (wrapped payload): #{inspect(stats)}")
        stats

      {:ok, other} ->
        Logger.warning("Device stats rollup returned unexpected payload: #{inspect(other)}")
        default_device_stats()

      {:error, reason} ->
        Logger.warning("Device stats rollup query failed: #{inspect(reason)}")
        default_device_stats()
    end
  rescue
    e ->
      Logger.error("Device stats loading failed: #{inspect(e)}")
      default_device_stats()
  end

  defp default_device_stats do
    %{
      total: 0,
      available: 0,
      unavailable: 0,
      by_type: [],
      by_vendor: [],
      by_risk_level: []
    }
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

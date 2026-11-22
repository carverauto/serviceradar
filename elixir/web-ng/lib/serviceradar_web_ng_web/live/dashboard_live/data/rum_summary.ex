defmodule ServiceRadarWebNGWeb.DashboardLive.Data.RumSummary do
  @moduledoc false

  alias ServiceRadar.Inventory.WebProperty

  def empty do
    %{
      enabled_properties: 0,
      beacons: 0,
      p75_lcp_ms: nil,
      p75_inp_ms: nil,
      p75_cls: nil,
      p75_ttfb_ms: nil,
      properties: []
    }
  end

  def load(scope) do
    case Ash.read(WebProperty, scope: scope) do
      {:ok, properties} when is_list(properties) ->
        enabled = Enum.filter(properties, &(&1.rum_enabled == true))

        if enabled == [] do
          empty()
        else
          stats = fetch_24h_stats(scope)

          %{
            enabled_properties: length(enabled),
            beacons: stats.beacons,
            p75_lcp_ms: stats.p75_lcp_ms,
            p75_inp_ms: stats.p75_inp_ms,
            p75_cls: stats.p75_cls,
            p75_ttfb_ms: stats.p75_ttfb_ms,
            properties:
              enabled
              |> Enum.sort_by(&String.downcase(&1.name || ""))
              |> Enum.take(6)
              |> Enum.map(fn wp ->
                %{id: wp.id, name: wp.name, canonical_origin: wp.canonical_origin}
              end)
          }
        end

      _ ->
        empty()
    end
  rescue
    _ -> empty()
  end

  defp fetch_24h_stats(scope) do
    srql = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)

    query =
      ~s|in:rum time:last_24h stats:"count() as beacons, p75(lcp_ms) as p75_lcp_ms, p75(inp_ms) as p75_inp_ms, p75(cls) as p75_cls, p75(ttfb_ms) as p75_ttfb_ms" limit:1|

    case srql.query(query, %{scope: scope}) do
      {:ok, %{"results" => [row | _]}} when is_map(row) ->
        %{
          beacons: to_int(row["beacons"]),
          p75_lcp_ms: to_float(row["p75_lcp_ms"]),
          p75_inp_ms: to_float(row["p75_inp_ms"]),
          p75_cls: to_float(row["p75_cls"]),
          p75_ttfb_ms: to_float(row["p75_ttfb_ms"])
        }

      _ ->
        %{beacons: 0, p75_lcp_ms: nil, p75_inp_ms: nil, p75_cls: nil, p75_ttfb_ms: nil}
    end
  rescue
    _ -> %{beacons: 0, p75_lcp_ms: nil, p75_inp_ms: nil, p75_cls: nil, p75_ttfb_ms: nil}
  end

  defp to_int(val) when is_integer(val), do: val
  defp to_int(val) when is_float(val), do: round(val)

  defp to_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val * 1.0

  defp to_float(val) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_float(_), do: nil
end

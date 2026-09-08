defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowList do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess,
    only: [enrich_flow_rows_with_attribution: 1, flow_get: 2]

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Params, only: [normalize_optional_string: 1]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.QueryState, only: [flows_list_base_query: 2]

  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadarWebNGWeb.NetFlow.EnrichmentExpiry
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.ChartData
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Config
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder

  require Ash.Query

  @default_limit Config.default_limit()
  @default_time Config.default_time()

  def load_srql_assigns(socket, query, uri, limit) when is_binary(query) do
    srql = Map.get(socket.assigns, :srql, %{})
    page_path = uri |> to_string() |> URI.parse() |> Map.get(:path)

    {builder_supported, builder_sync, builder_state} =
      case SRQLBuilder.parse(query) do
        {:ok, parsed} -> {true, true, parsed}
        {:error, _} -> {false, false, SRQLBuilder.default_state("flows", limit)}
      end

    srql =
      Map.merge(srql, %{
        enabled: true,
        entity: "flows",
        page_path: page_path,
        query: query,
        draft: query,
        error: nil,
        loading: false,
        builder_available: true,
        builder_supported: builder_supported,
        builder_sync: builder_sync,
        builder: builder_state,
        builder_mode_notice: nil
      })

    socket
    |> assign(:srql, srql)
    |> assign(:limit, limit)
  end

  def load_srql_assigns(socket, other, uri, limit), do: load_srql_assigns(socket, to_string(other || ""), uri, limit)

  def load_flows_list(socket, params, %{} = state) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    scope = socket.assigns.current_scope

    chart_query = Map.get(socket.assigns.srql, :query) || ""
    fallback_time = Map.get(state, "time", @default_time)

    list_query =
      chart_query
      |> flows_list_base_query(fallback_time)
      |> ensure_sort_time_desc()

    display_window = TimeWindow.display_window_from_query(list_query, fallback_time)

    cursor = params |> Map.get("cursor") |> normalize_optional_string()
    limit = Map.get(socket.assigns, :limit, @default_limit)

    {flows, pagination} =
      case srql_module.query(list_query, %{cursor: cursor, limit: limit, scope: scope}) do
        {:ok, %{"results" => results, "pagination" => pag}} when is_list(results) ->
          {results |> ChartData.extract_srql_rows() |> enrich_flow_rows_with_attribution(), pag || %{}}

        {:ok, %{"results" => results}} when is_list(results) ->
          {results |> ChartData.extract_srql_rows() |> enrich_flow_rows_with_attribution(), %{}}

        _ ->
          {[], %{}}
      end

    socket
    |> assign(:flows, flows)
    |> assign(:flows_pagination, pagination)
    |> assign(:rdns_map, rdns_map_for_flows(flows, scope))
    |> assign(:geo_iso2_map, geo_iso2_map_for_flows(flows, scope))
    |> assign(:flows_window, display_window)
  rescue
    _ ->
      socket
      |> assign(:flows, [])
      |> assign(:flows_pagination, %{})
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
      |> assign(:flows_window, nil)
  end

  def ensure_sort_time_desc(query) when is_binary(query) do
    q = String.trim(query)

    if Regex.match?(~r/(?:^|\s)sort:/, q) do
      q
    else
      String.trim(q <> " sort:time:desc")
    end
  end

  def rdns_map_for_flows(flows, scope) when is_list(flows) do
    ips =
      flows
      |> Enum.flat_map(fn row ->
        [
          flow_get(row, ["src_endpoint_ip", "src_ip"]),
          flow_get(row, ["dst_endpoint_ip", "dst_ip"])
        ]
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    query =
      IpRdnsCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, DateTime.utc_now())

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.filter(fn row ->
          row.status == "ok" and is_binary(row.hostname) and String.trim(row.hostname) != ""
        end)
        |> Map.new(fn row -> {row.ip, row.hostname} end)

      _ ->
        %{}
    end
  end

  def geo_iso2_map_for_flows(flows, scope) when is_list(flows) do
    ips =
      flows
      |> Enum.flat_map(fn row ->
        [
          flow_get(row, ["src_endpoint_ip", "src_ip"]),
          flow_get(row, ["dst_endpoint_ip", "dst_ip"])
        ]
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    query =
      IpGeoEnrichmentCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, DateTime.utc_now())

    with [_ | _] <- ips,
         {:ok, rows} when is_list(rows) <- Ash.read(query, scope: scope) do
      rows
      |> Enum.filter(fn row ->
        is_binary(row.country_iso2) and String.length(String.trim(row.country_iso2)) == 2
      end)
      |> Map.new(fn row -> {row.ip, String.upcase(String.trim(row.country_iso2))} end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end
end

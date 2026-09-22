# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.NetflowTraffic do
  @moduledoc false

  # Every conversation in the window, not the heaviest few. The heaviest
  # conversations of a typical network all terminate in the same handful of
  # cloud regions, so a byte-ranked top 120 drew a few dozen arcs on top of one
  # another while thousands of conversations to other places were never
  # fetched. Which arcs to draw is decided after geolocation, in
  # `collapse_arcs/1`, and nothing is dropped there.
  #
  # This is a memory guard, not a product limit: a conversation is an IP pair,
  # so the row count grows with the window and the network, and the rows pass
  # through this process. Reaching it is logged, never silent. The way to
  # remove it is to group by place in the warehouse, where the result is
  # bounded by geography instead of by address pairs.
  @conversation_limit 250_000

  @spec conversation_limit() :: pos_integer()
  def conversation_limit, do: @conversation_limit

  @spec srql_query(map()) :: String.t()
  def srql_query(%{} = window) do
    time = ServiceRadarWebNGWeb.DashboardLive.Window.query_time(window)

    ~s|in:flows #{time} stats:"sum(bytes_total) as bytes_total, sum(packets_total) as packets_total, count(*) as flow_count by src_endpoint_ip,dst_endpoint_ip,partition" sort:bytes_total:desc limit:#{@conversation_limit}|
  end

  @doc """
  Merges conversations that would draw the same arc into one.

  Two conversations between the same pair of places are the same line on a
  map, so they become one link carrying their summed traffic and a
  `conversation_count`; the heaviest member supplies the labels. Arcs are
  bounded by geography, so none are dropped, whatever the window. Links that
  could not be geolocated draw nothing on the geo map; they are kept as they
  are for the topology view and so the tiles still account for them.
  """
  @spec collapse_arcs([map()]) :: [map()]
  def collapse_arcs(links) when is_list(links) do
    {mapped, unmapped} = Enum.split_with(links, &(&1[:geo_mapped] == true))

    arcs =
      mapped
      |> Enum.group_by(&{&1.geo_from, &1.geo_to})
      |> Enum.map(fn {_places, members} -> merge_arc(members) end)
      |> Enum.sort_by(& &1.bytes, :desc)

    unmapped =
      unmapped
      |> Enum.map(&Map.put_new(&1, :conversation_count, 1))
      |> Enum.sort_by(& &1.bytes, :desc)

    arcs ++ unmapped
  end

  defp merge_arc([only]), do: Map.put_new(only, :conversation_count, 1)

  defp merge_arc(members) do
    heaviest = Enum.max_by(members, & &1.bytes)
    bytes = members |> Enum.map(& &1.bytes) |> Enum.sum()
    packets = members |> Enum.map(& &1.packets) |> Enum.sum()

    Map.merge(heaviest, %{
      bytes: bytes,
      bytes_total: bytes,
      magnitude: bytes,
      packets: packets,
      packets_total: packets,
      flow_count: members |> Enum.map(& &1.flow_count) |> Enum.sum(),
      conversation_count: length(members)
    })
  end

  defmacro __using__(_opts) do
    quote do
      alias ServiceRadarWebNGWeb.DashboardLive.Data.NetflowTraffic

      require Logger

      defp traffic_links(%{seconds: _seconds} = window, scope, srql_module) do
        query = NetflowTraffic.srql_query(window)

        case srql_module.query(query, %{scope: scope}) do
          {:ok, %{"results" => []}} ->
            []

          {:ok, %{"results" => rows}} when is_list(rows) ->
            limit = NetflowTraffic.conversation_limit()

            if length(rows) >= limit do
              Logger.warning(
                "NetFlow map reached its #{limit}-conversation memory guard for #{inspect(window[:seconds])}s; " <>
                  "the lightest conversations in this window are not on the map"
              )
            end

            rows = Enum.filter(rows, &distinct_endpoints?/1)
            geo = netflow_geo_points(netflow_endpoint_keys(rows))

            rows
            |> Enum.with_index()
            |> Enum.map(fn {row, idx} -> srql_traffic_link(row, idx, geo) end)
            |> NetflowTraffic.collapse_arcs()
            |> Enum.with_index()
            |> Enum.map(fn {link, idx} ->
              # Ids and colours follow draw order, which collapsing changed.
              %{link | id: "flow-#{idx}", color: flow_color(idx, link.magnitude)}
            end)

          _ ->
            :error
        end
      end

      defp distinct_endpoints?(row) do
        src = row["src_endpoint_ip"]
        dst = row["dst_endpoint_ip"]

        is_binary(src) and src != "" and is_binary(dst) and dst != "" and src != dst
      end

      defp netflow_endpoint_keys(rows) do
        rows
        |> Enum.flat_map(fn row ->
          partition = row["flow_partition"]
          [{row["src_endpoint_ip"], partition}, {row["dst_endpoint_ip"], partition}]
        end)
        |> Enum.filter(fn {ip, _partition} -> is_binary(ip) and ip != "" end)
        |> Enum.uniq()
      end

      defp srql_traffic_link(row, idx, geo) do
        src = row["src_endpoint_ip"]
        dst = row["dst_endpoint_ip"]
        partition = row["flow_partition"]
        src_geo = Map.get(geo, {src, partition}, %{})
        dst_geo = Map.get(geo, {dst, partition}, %{})
        magnitude = to_int(row["bytes_total"])
        topology_from = point_for(src)
        topology_to = point_for(dst)

        geo_from =
          geo_point_or_country(src_geo[:longitude], src_geo[:latitude], src_geo[:country])

        geo_to = geo_point_or_country(dst_geo[:longitude], dst_geo[:latitude], dst_geo[:country])

        %{
          id: "flow-#{idx}",
          src_endpoint_ip: row["src_endpoint_ip"],
          dst_endpoint_ip: row["dst_endpoint_ip"],
          from: topology_from,
          to: topology_to,
          topology_from: topology_from,
          topology_to: topology_to,
          geo_from: geo_from,
          geo_to: geo_to,
          geo_mapped: not is_nil(geo_from) and not is_nil(geo_to),
          source_label: src,
          target_label: dst,
          source_geo_label: geo_label(src_geo[:city], src_geo[:country], src),
          target_geo_label: geo_label(dst_geo[:city], dst_geo[:country], dst),
          source_anchor_label: src_geo[:anchor_label],
          target_anchor_label: dst_geo[:anchor_label],
          source_local_anchor: src_geo[:local_anchor] == true,
          target_local_anchor: dst_geo[:local_anchor] == true,
          bytes_total: row["bytes_total"],
          bytes: magnitude,
          magnitude: magnitude,
          packets_total: row["packets_total"],
          packets: to_int(row["packets_total"]),
          flow_count: to_int(row["flow_count"]),
          color: flow_color(idx, magnitude)
        }
      end

      defp netflow_geo_points([]), do: %{}

      defp netflow_geo_points(keys) do
        has_geo? = relation_exists?("platform.ip_geo_enrichment_cache")
        has_ipinfo? = relation_exists?("platform.ip_ipinfo_cache")
        has_anchor? = netflow_location_anchors_available?()

        if has_geo? or has_ipinfo? or has_anchor? do
          netflow_geo_points_rows(keys, has_geo?, has_ipinfo?, has_anchor?)
        else
          %{}
        end
      rescue
        _ -> %{}
      end

      @sobelow_skip ["SQL.Query"]
      defp netflow_geo_points_rows(keys, has_geo?, has_ipinfo?, has_anchor?) do
        geo_lat = if has_geo?, do: "g.latitude", else: "NULL::float8"
        geo_lon = if has_geo?, do: "g.longitude", else: "NULL::float8"
        geo_city = if has_geo?, do: "g.city", else: "NULL::text"
        geo_country = if has_geo?, do: "g.country_iso2", else: "NULL::text"

        lat = anchored_expr(has_anchor?, "a.latitude", geo_lat)
        lon = anchored_expr(has_anchor?, "a.longitude", geo_lon)

        city =
          ipinfo_coalesce(has_ipinfo?, anchored_label_expr(has_anchor?, "a", geo_city), "i.city")

        country =
          ipinfo_coalesce(
            has_ipinfo?,
            anchored_country_expr(has_anchor?, "a", geo_country),
            "i.country_code"
          )

        geo_join =
          if has_geo?,
            do: "LEFT JOIN platform.ip_geo_enrichment_cache g ON g.ip = e.ip",
            else: ""

        ipinfo_join =
          if has_ipinfo?, do: "LEFT JOIN platform.ip_ipinfo_cache i ON i.ip = e.ip", else: ""

        anchor_join =
          if has_anchor? do
            """
            LEFT JOIN LATERAL (
              SELECT c.location_label, c.label, c.latitude, c.longitude
              FROM platform.netflow_local_cidrs c
              WHERE c.enabled
                AND c.latitude IS NOT NULL
                AND c.longitude IS NOT NULL
                AND #{endpoint_inet_expr("e.ip")} <<= c.cidr
                AND (c.partition IS NULL OR c.partition = e.partition)
              ORDER BY masklen(c.cidr) DESC, c.updated_at DESC NULLS LAST
              LIMIT 1
            ) a ON true
            """
          else
            ""
          end

        sql = """
        SELECT
          e.ip,
          e.partition,
          #{lat} AS latitude,
          #{lon} AS longitude,
          #{city} AS city,
          #{country} AS country,
          #{anchor_label_select_expr(has_anchor?, "a")} AS anchor_label,
          #{local_anchor_select_expr(has_anchor?, "a")} AS local_anchor
        FROM unnest($1::text[], $2::text[]) AS e(ip, partition)
        #{geo_join}
        #{ipinfo_join}
        #{anchor_join}
        """

        ips = Enum.map(keys, &elem(&1, 0))
        partitions = Enum.map(keys, &elem(&1, 1))

        case ServiceRadarWebNG.Repo.query(sql, [ips, partitions]) do
          {:ok, %{rows: rows}} ->
            Map.new(rows, fn [
                               ip,
                               partition,
                               latitude,
                               longitude,
                               city,
                               country,
                               anchor_label,
                               local_anchor
                             ] ->
              {{ip, partition},
               %{
                 latitude: latitude,
                 longitude: longitude,
                 city: city,
                 country: country,
                 anchor_label: anchor_label,
                 local_anchor: local_anchor
               }}
            end)

          _ ->
            %{}
        end
      end

      defp traffic_links(value, scope, srql_module) when is_binary(value) do
        case traffic_links(
               ServiceRadarWebNGWeb.DashboardLive.Window.resolve(value, "netflow"),
               scope,
               srql_module
             ) do
          :error -> []
          links -> links
        end
      end
    end
  end
end

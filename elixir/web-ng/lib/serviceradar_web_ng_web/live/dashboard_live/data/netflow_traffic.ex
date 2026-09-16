# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.NetflowTraffic do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp traffic_links(%{seconds: seconds} = window, scope, srql_module) when seconds >= 21_600 do
        time = ServiceRadarWebNGWeb.DashboardLive.Window.query_time(window)

        query =
          ~s|in:flows #{time} stats:"sum(bytes_total) as bytes_total, sum(packets_total) as packets_total, count(*) as flow_count by src_endpoint_ip,dst_endpoint_ip" sort:bytes_total:desc limit:120|

        case srql_module.query(query, %{scope: scope}) do
          {:ok, %{"results" => []}} ->
            []

          {:ok, %{"results" => rows}} when is_list(rows) ->
            traffic_links_from_relation("analytics_flow_pairs", nil, rows)

          _ ->
            :error
        end
      end

      defp traffic_links(%{start: _, end: _} = window, _scope, _srql_module) do
        traffic_links_from_relation("ocsf_network_activity", "time", window)
      rescue
        _ -> :error
      end

      defp traffic_links(value, scope, srql_module) do
        case traffic_links(ServiceRadarWebNGWeb.DashboardLive.Window.resolve(value, "netflow"), scope, srql_module) do
          :error -> []
          links -> links
        end
      end

      @sobelow_skip ["SQL.Query"]
      defp traffic_links_from_relation(relation, time_column, input) do
        flow_count_expr = flow_count_expr(relation)

        bytes_expr =
          if relation == "ocsf_network_activity",
            do: "bytes_total::numeric * GREATEST(COALESCE(sampling_rate, 1), 1)",
            else: "bytes_total"

        packets_expr =
          if relation == "ocsf_network_activity",
            do: "packets_total::numeric * GREATEST(COALESCE(sampling_rate, 1), 1)",
            else: "packets_total"

        {source, time_predicate, params} =
          if relation == "analytics_flow_pairs" do
            {"jsonb_to_recordset($1::jsonb) AS f(src_endpoint_ip text, dst_endpoint_ip text, bytes_total float8, packets_total float8, flow_count bigint)",
             "TRUE", [input, 120]}
          else
            {"#{relation} f", "f.#{time_column} >= $1 AND f.#{time_column} < $3", [input.start, 120, input.end]}
          end

        has_geo? = relation_exists?("platform.ip_geo_enrichment_cache")
        has_ipinfo? = relation_exists?("platform.ip_ipinfo_cache")
        has_threat? = relation_exists?("platform.ip_threat_intel_cache")
        has_anchor? = netflow_location_anchors_available?()
        anchor_partition_filter = anchor_partition_filter(relation)

        src_geo_lat = if has_geo?, do: "src_geo.latitude", else: "NULL::float8"
        src_geo_lon = if has_geo?, do: "src_geo.longitude", else: "NULL::float8"
        src_geo_city = if has_geo?, do: "src_geo.city", else: "NULL::text"
        src_geo_country = if has_geo?, do: "src_geo.country_iso2", else: "NULL::text"
        dst_geo_lat = if has_geo?, do: "dst_geo.latitude", else: "NULL::float8"
        dst_geo_lon = if has_geo?, do: "dst_geo.longitude", else: "NULL::float8"
        dst_geo_city = if has_geo?, do: "dst_geo.city", else: "NULL::text"
        dst_geo_country = if has_geo?, do: "dst_geo.country_iso2", else: "NULL::text"

        src_lat = anchored_expr(has_anchor?, "src_anchor.latitude", src_geo_lat)
        src_lon = anchored_expr(has_anchor?, "src_anchor.longitude", src_geo_lon)

        src_city =
          ipinfo_coalesce(has_ipinfo?, anchored_label_expr(has_anchor?, "src_anchor", src_geo_city), "src_ipinfo.city")

        src_country =
          ipinfo_coalesce(
            has_ipinfo?,
            anchored_country_expr(has_anchor?, "src_anchor", src_geo_country),
            "src_ipinfo.country_code"
          )

        dst_lat = anchored_expr(has_anchor?, "dst_anchor.latitude", dst_geo_lat)
        dst_lon = anchored_expr(has_anchor?, "dst_anchor.longitude", dst_geo_lon)

        dst_city =
          ipinfo_coalesce(has_ipinfo?, anchored_label_expr(has_anchor?, "dst_anchor", dst_geo_city), "dst_ipinfo.city")

        dst_country =
          ipinfo_coalesce(
            has_ipinfo?,
            anchored_country_expr(has_anchor?, "dst_anchor", dst_geo_country),
            "dst_ipinfo.country_code"
          )

        src_anchor_label = anchor_label_select_expr(has_anchor?, "src_anchor")
        dst_anchor_label = anchor_label_select_expr(has_anchor?, "dst_anchor")
        src_local_anchor = local_anchor_select_expr(has_anchor?, "src_anchor")
        dst_local_anchor = local_anchor_select_expr(has_anchor?, "dst_anchor")
        threat_select = threat_select_expr(has_threat?)
        attribution_select = attribution_select_expr(relation)

        geo_select = """
          #{src_lat} AS src_latitude,
          #{src_lon} AS src_longitude,
          #{src_city} AS src_city,
          #{src_country} AS src_country,
          #{src_anchor_label} AS src_anchor_label,
          #{src_local_anchor} AS src_local_anchor,
          #{dst_lat} AS dst_latitude,
          #{dst_lon} AS dst_longitude,
          #{dst_city} AS dst_city,
          #{dst_country} AS dst_country,
          #{dst_anchor_label} AS dst_anchor_label,
          #{dst_local_anchor} AS dst_local_anchor
        """

        geo_join =
          if has_geo? do
            """
            LEFT JOIN platform.ip_geo_enrichment_cache src_geo ON src_geo.ip = NULLIF(f.src_endpoint_ip, '')
            LEFT JOIN platform.ip_geo_enrichment_cache dst_geo ON dst_geo.ip = NULLIF(f.dst_endpoint_ip, '')
            """
          else
            ""
          end

        ipinfo_join =
          if has_ipinfo? do
            """
            LEFT JOIN platform.ip_ipinfo_cache src_ipinfo ON src_ipinfo.ip = NULLIF(f.src_endpoint_ip, '')
            LEFT JOIN platform.ip_ipinfo_cache dst_ipinfo ON dst_ipinfo.ip = NULLIF(f.dst_endpoint_ip, '')
            """
          else
            ""
          end

        anchor_join =
          if has_anchor? do
            """
            LEFT JOIN LATERAL (
              SELECT c.location_label, c.label, c.latitude, c.longitude
              FROM platform.netflow_local_cidrs c
              WHERE c.enabled
                AND c.latitude IS NOT NULL
                AND c.longitude IS NOT NULL
                AND #{endpoint_inet_expr("f.src_endpoint_ip")} <<= c.cidr
                AND #{anchor_partition_filter}
              ORDER BY masklen(c.cidr) DESC, c.updated_at DESC NULLS LAST
              LIMIT 1
            ) src_anchor ON true
            LEFT JOIN LATERAL (
              SELECT c.location_label, c.label, c.latitude, c.longitude
              FROM platform.netflow_local_cidrs c
              WHERE c.enabled
                AND c.latitude IS NOT NULL
                AND c.longitude IS NOT NULL
                AND #{endpoint_inet_expr("f.dst_endpoint_ip")} <<= c.cidr
                AND #{anchor_partition_filter}
              ORDER BY masklen(c.cidr) DESC, c.updated_at DESC NULLS LAST
              LIMIT 1
            ) dst_anchor ON true
            """
          else
            ""
          end

        threat_join =
          if has_threat? do
            """
            LEFT JOIN platform.ip_threat_intel_cache src_threat
              ON src_threat.ip = NULLIF(f.src_endpoint_ip, '')
              AND src_threat.matched = true
              AND src_threat.expires_at > now()
            LEFT JOIN platform.ip_threat_intel_cache dst_threat
              ON dst_threat.ip = NULLIF(f.dst_endpoint_ip, '')
              AND dst_threat.matched = true
              AND dst_threat.expires_at > now()
            """
          else
            ""
          end

        sql = """
        SELECT
          COALESCE(f.src_endpoint_ip, 'Unknown') AS src,
          COALESCE(f.dst_endpoint_ip, 'Unknown') AS dst,
          COALESCE(SUM(#{bytes_expr}), 0)::bigint AS bytes_total,
          COALESCE(SUM(#{packets_expr}), 0)::bigint AS packets_total,
          COALESCE(#{flow_count_expr}, 0)::bigint AS flow_count,
          #{geo_select},
          #{threat_select},
          #{attribution_select}
        FROM #{source}
        #{geo_join}
        #{ipinfo_join}
        #{anchor_join}
        #{threat_join}
        WHERE #{time_predicate}
          AND f.src_endpoint_ip IS NOT NULL
          AND f.dst_endpoint_ip IS NOT NULL
          AND f.src_endpoint_ip <> f.dst_endpoint_ip
        GROUP BY src, dst, src_latitude, src_longitude, src_city, src_country, src_anchor_label, src_local_anchor, dst_latitude, dst_longitude, dst_city, dst_country, dst_anchor_label, dst_local_anchor
        ORDER BY bytes_total DESC
        LIMIT $2
        """

        case ServiceRadarWebNG.Repo.query(sql, params) do
          {:ok, %{rows: rows}} ->
            rows
            |> Enum.with_index()
            |> Enum.map(fn {[
                              src,
                              dst,
                              bytes,
                              packets,
                              flow_count,
                              src_lat,
                              src_lon,
                              src_city,
                              src_country,
                              src_anchor_label,
                              src_local_anchor,
                              dst_lat,
                              dst_lon,
                              dst_city,
                              dst_country,
                              dst_anchor_label,
                              dst_local_anchor,
                              src_threat_matched,
                              src_threat_match_count,
                              src_threat_max_severity,
                              src_threat_sources,
                              dst_threat_matched,
                              dst_threat_match_count,
                              dst_threat_max_severity,
                              dst_threat_sources,
                              attributed_flow_count,
                              attribution_agent_id,
                              attribution_comm,
                              attribution_pid,
                              attribution_container_id,
                              attribution_pod_namespace,
                              attribution_pod_name,
                              attribution_container_name,
                              attribution_image
                            ], idx} ->
              magnitude = to_int(bytes)
              topology_from = point_for(src)
              topology_to = point_for(dst)
              geo_from = geo_point_or_country(src_lon, src_lat, src_country)
              geo_to = geo_point_or_country(dst_lon, dst_lat, dst_country)
              threat_matched = src_threat_matched == true or dst_threat_matched == true
              threat_sources = threat_sources(src_threat_sources, dst_threat_sources)

              %{
                id: "flow-#{idx}",
                from: topology_from,
                to: topology_to,
                topology_from: topology_from,
                topology_to: topology_to,
                geo_from: geo_from,
                geo_to: geo_to,
                geo_mapped: not is_nil(geo_from) and not is_nil(geo_to),
                source_label: src,
                target_label: dst,
                source_geo_label: geo_label(src_city, src_country, src),
                target_geo_label: geo_label(dst_city, dst_country, dst),
                source_anchor_label: src_anchor_label,
                target_anchor_label: dst_anchor_label,
                source_local_anchor: src_local_anchor == true,
                target_local_anchor: dst_local_anchor == true,
                source_threat_matched: src_threat_matched == true,
                target_threat_matched: dst_threat_matched == true,
                threat_matched: threat_matched,
                threat_match_count: to_int(src_threat_match_count) + to_int(dst_threat_match_count),
                threat_max_severity: max(to_int(src_threat_max_severity), to_int(dst_threat_max_severity)),
                threat_sources: threat_sources,
                attributed_flow_count: to_int(attributed_flow_count),
                attribution_agent_id: attribution_agent_id,
                attribution_comm: attribution_comm,
                attribution_pid: to_int(attribution_pid),
                attribution_container_id: attribution_container_id,
                attribution_pod_namespace: attribution_pod_namespace,
                attribution_pod_name: attribution_pod_name,
                attribution_container_name: attribution_container_name,
                attribution_image: attribution_image,
                magnitude: magnitude,
                bytes: magnitude,
                packets: to_int(packets),
                flow_count: to_int(flow_count),
                color: if(threat_matched, do: [244, 63, 94, 245], else: flow_color(idx, magnitude))
              }
            end)

          _ ->
            :error
        end
      end
    end
  end
end

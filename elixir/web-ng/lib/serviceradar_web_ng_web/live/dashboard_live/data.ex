defmodule ServiceRadarWebNGWeb.DashboardLive.Data do
  @moduledoc false

  alias ServiceRadarWebNG.FieldSurveyDashboardPlaylist
  alias ServiceRadarWebNG.FieldSurveyFloorplan
  alias ServiceRadarWebNG.Graph, as: AgeGraph
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.TenantUsage
  alias ServiceRadarWebNG.Topology.RuntimeGraph
  alias ServiceRadarWebNGWeb.Stats

  @default_time_window "last_24h"
  @top_flow_limit 120
  @mtr_overlay_limit 80
  @topology_link_limit 160
  @topology_sparkline_interface_limit 80
  @dashboard_sparkline_limit 48
  @netflow_map_window_minutes 15
  @snmp_traffic_metrics ~w(ifHCInOctets ifHCOutOctets ifInOctets ifOutOctets)

  @spec empty(keyword()) :: map()
  def empty(opts \\ []) do
    time_window = Keyword.get(opts, :time_window, @default_time_window)

    %{
      time_window: time_window,
      time_window_label: time_window_label(time_window),
      dashboard_modules: [:inventory, :health],
      module_states: %{
        inventory: :loading,
        health: :loading,
        netflow: :loading,
        mtr: :loading,
        camera: :loading,
        fieldsurvey: :loading,
        security_events: :loading,
        vulnerable_assets: :unconnected,
        siem: :unconnected
      },
      kpi_cards:
        kpi_cards(
          empty_device_summary(),
          empty_services_summary(),
          empty_flow_summary(),
          empty_camera_summary(),
          empty_survey_summary(),
          empty_alert_summary(),
          empty_event_summary(),
          empty_sparklines()
        ),
      map_stats: map_stats(empty_flow_summary(), empty_mtr_summary(), []),
      map_view: "netflow",
      traffic_links_window_label: netflow_map_window_label(),
      topology_links: [],
      topology_links_json: "[]",
      traffic_links: [],
      traffic_links_json: "[]",
      mtr_overlays: [],
      mtr_overlays_json: "[]",
      wifi_map_sites: [],
      wifi_map_sites_json: "[]",
      wifi_map_summary: empty_wifi_map_summary(),
      map_empty_title: "Checking traffic sources",
      map_empty_detail: "Dashboard data will load after the LiveView connects.",
      observability_metrics:
        observability_metrics(
          empty_flow_summary(),
          empty_mtr_summary(),
          empty_trace_summary(),
          empty_services_summary(),
          empty_sparklines()
        ),
      security_trend: [],
      security_trend_max: 0,
      security_summary: empty_event_summary(),
      threat_intel_summary: empty_threat_intel_summary(),
      alert_feed: [],
      camera_summary: empty_camera_summary(),
      survey_summary: empty_survey_summary()
    }
  end

  @spec load(term(), keyword()) :: map()
  def load(scope, opts \\ []) do
    time_window = Keyword.get(opts, :time_window, @default_time_window)
    srql_module = Keyword.get(opts, :srql_module, default_srql_module())
    collector_counts = TenantUsage.collector_counts_by_type()
    device_summary = device_summary(scope)
    services_summary = services_summary(scope, time_window)
    flow_summary = flow_summary(time_window)
    traffic_links = traffic_links(time_window)
    topology_links = topology_links(time_window)
    flow_summary = Map.put(flow_summary, :link_count, max(length(traffic_links), length(topology_links)))
    mtr_overlays = mtr_overlays()
    mtr_summary = summarize_mtr_overlays(mtr_overlays)
    wifi_map_sites = wifi_map_sites()
    wifi_map_summary = summarize_wifi_map_sites(wifi_map_sites)
    camera_summary = camera_summary(scope)
    survey_summary = empty_survey_summary()
    alert_summary = Stats.alerts_summary(scope: scope)
    alert_feed = alert_feed(time_window)
    event_summary = Stats.events_summary(time: time_window)
    threat_intel_summary = threat_intel_summary()
    trace_summary = trace_summary(srql_module, scope, time_window)
    security_trend = security_trend(time_window)
    sparklines = dashboard_sparklines(time_window, security_trend, mtr_overlays)

    module_states =
      module_states(
        collector_counts,
        flow_summary,
        traffic_links,
        mtr_summary,
        camera_summary,
        survey_summary,
        wifi_map_summary,
        event_summary,
        alert_summary
      )

    %{
      time_window: time_window,
      time_window_label: time_window_label(time_window),
      dashboard_modules: enabled_modules(module_states),
      module_states: module_states,
      kpi_cards:
        kpi_cards(
          device_summary,
          services_summary,
          flow_summary,
          camera_summary,
          survey_summary,
          alert_summary,
          event_summary,
          sparklines
        ),
      map_stats: map_stats(flow_summary, mtr_summary, traffic_links),
      map_view: "netflow",
      traffic_links_window_label: netflow_map_window_label(),
      topology_links: topology_links,
      topology_links_json: Jason.encode!(topology_links),
      traffic_links: traffic_links,
      traffic_links_json: Jason.encode!(traffic_links),
      mtr_overlays: mtr_overlays,
      mtr_overlays_json: Jason.encode!(mtr_overlays),
      wifi_map_sites: wifi_map_sites,
      wifi_map_sites_json: Jason.encode!(wifi_map_sites),
      wifi_map_summary: wifi_map_summary,
      map_empty_title: map_empty_title(module_states.netflow),
      map_empty_detail: map_empty_detail(module_states.netflow),
      observability_metrics:
        observability_metrics(flow_summary, mtr_summary, trace_summary, services_summary, sparklines),
      security_trend: security_trend,
      security_trend_max: max_trend_total(security_trend),
      security_summary: event_summary,
      threat_intel_summary: threat_intel_summary,
      alert_feed: alert_feed,
      camera_summary: camera_summary,
      survey_summary: survey_summary
    }
  end

  @spec load_survey_summary(term()) :: map()
  def load_survey_summary(scope), do: survey_summary(scope)

  @spec survey_kpi_card(map(), list()) :: map()
  def survey_kpi_card(survey, sparkline \\ []) do
    %{
      title: "Wi-Fi Coverage",
      value: survey_value(survey),
      detail: survey_detail(survey),
      icon: "hero-wifi",
      tone: "violet",
      sparkline: sparkline
    }
  end

  defp device_summary(_scope) do
    if relation_exists?("platform.ocsf_devices") do
      sql = """
      SELECT
        COUNT(*)::bigint AS total,
        COUNT(*) FILTER (WHERE is_available = true)::bigint AS available
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL
      """

      case Repo.query(sql, []) do
        {:ok, %{rows: [[total, available]]}} ->
          total = to_int(total)
          available = to_int(available)
          %{total: total, available: available, unavailable: max(total - available, 0)}

        _ ->
          empty_device_summary()
      end
    else
      empty_device_summary()
    end
  rescue
    _ -> empty_device_summary()
  end

  defp services_summary(scope, time_window) do
    if relation_exists?("platform.services_availability_5m") do
      Stats.services_availability(scope: scope, time: time_window)
    else
      empty_services_summary()
    end
  rescue
    _ -> empty_services_summary()
  end

  defp trace_summary(srql_module, scope, time_window) do
    Stats.traces_summary_with_computed(scope: scope, time: time_window, srql_module: srql_module)
  rescue
    _ -> empty_trace_summary()
  end

  defp flow_summary(time_window) do
    cutoff = cutoff_for_time_window(time_window)

    Enum.find_value(
      [
        {"platform.flow_traffic_1h", "flow_traffic_1h", "bucket"},
        {"platform.ocsf_network_activity_5m_traffic", "ocsf_network_activity_5m_traffic", "bucket"},
        {"platform.ocsf_network_activity", "ocsf_network_activity", "time"}
      ],
      empty_flow_summary(),
      fn {relation_ref, relation, time_column} ->
        if relation_exists?(relation_ref) do
          summary = flow_summary_from_relation(relation, time_column, cutoff)

          if summary.flow_count > 0 or summary.bytes_total > 0 do
            summary
          end
        end
      end
    )
  rescue
    _ -> empty_flow_summary()
  end

  defp flow_summary_from_relation(relation, time_column, cutoff) do
    flow_count_expr = flow_count_expr(relation)

    sql = """
    SELECT
      COALESCE(SUM(bytes_total), 0)::bigint,
      COALESCE(SUM(packets_total), 0)::bigint,
      COALESCE(#{flow_count_expr}, 0)::bigint
    FROM #{relation}
    WHERE #{time_column} >= $1
    """

    case Repo.query(sql, [cutoff]) do
      {:ok, %{rows: [[bytes, packets, flows]]}} ->
        seconds = max(DateTime.diff(DateTime.utc_now(), cutoff, :second), 1)

        %{
          bytes_total: to_int(bytes),
          packets_total: to_int(packets),
          flow_count: to_int(flows),
          bps: Float.round(to_int(bytes) * 8 / seconds, 2),
          pps: Float.round(to_int(packets) / seconds, 2)
        }

      _ ->
        empty_flow_summary()
    end
  end

  defp traffic_links(time_window) do
    cutoff = netflow_map_cutoff(time_window)

    Enum.find_value(
      traffic_link_sources(time_window),
      [],
      fn {relation_ref, relation, time_column} ->
        if relation_exists?(relation_ref) do
          links = traffic_links_from_relation(relation, time_column, cutoff)
          if links != [], do: links
        end
      end
    )
  rescue
    _ -> []
  end

  defp traffic_link_sources(time_window) when time_window in ["last_1h", "last_6h"] do
    [
      {"platform.ocsf_network_activity", "ocsf_network_activity", "time"},
      {"platform.ocsf_network_activity_hourly_conversations", "ocsf_network_activity_hourly_conversations", "bucket"}
    ]
  end

  defp traffic_link_sources(_time_window) do
    [
      {"platform.ocsf_network_activity", "ocsf_network_activity", "time"},
      {"platform.ocsf_network_activity_hourly_conversations", "ocsf_network_activity_hourly_conversations", "bucket"}
    ]
  end

  defp traffic_links_from_relation(relation, time_column, cutoff) do
    flow_count_expr = flow_count_expr(relation)
    has_geo? = relation_exists?("platform.ip_geo_enrichment_cache")
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
    src_city = anchored_label_expr(has_anchor?, "src_anchor", src_geo_city)
    src_country = anchored_country_expr(has_anchor?, "src_anchor", src_geo_country)
    dst_lat = anchored_expr(has_anchor?, "dst_anchor.latitude", dst_geo_lat)
    dst_lon = anchored_expr(has_anchor?, "dst_anchor.longitude", dst_geo_lon)
    dst_city = anchored_label_expr(has_anchor?, "dst_anchor", dst_geo_city)
    dst_country = anchored_country_expr(has_anchor?, "dst_anchor", dst_geo_country)
    src_anchor_label = anchor_label_select_expr(has_anchor?, "src_anchor")
    dst_anchor_label = anchor_label_select_expr(has_anchor?, "dst_anchor")
    src_local_anchor = local_anchor_select_expr(has_anchor?, "src_anchor")
    dst_local_anchor = local_anchor_select_expr(has_anchor?, "dst_anchor")
    threat_select = threat_select_expr(has_threat?)

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
      COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total,
      COALESCE(SUM(packets_total), 0)::bigint AS packets_total,
      COALESCE(#{flow_count_expr}, 0)::bigint AS flow_count,
      #{geo_select},
      #{threat_select}
    FROM #{relation} f
    #{geo_join}
    #{anchor_join}
    #{threat_join}
    WHERE f.#{time_column} >= $1
      AND f.src_endpoint_ip IS NOT NULL
      AND f.dst_endpoint_ip IS NOT NULL
      AND f.src_endpoint_ip <> f.dst_endpoint_ip
    GROUP BY src, dst, src_latitude, src_longitude, src_city, src_country, src_anchor_label, src_local_anchor, dst_latitude, dst_longitude, dst_city, dst_country, dst_anchor_label, dst_local_anchor
    ORDER BY bytes_total DESC
    LIMIT $2
    """

    case Repo.query(sql, [cutoff, @top_flow_limit]) do
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
                          dst_threat_sources
                        ], idx} ->
          magnitude = to_int(bytes)
          topology_from = point_for(src)
          topology_to = point_for(dst)
          geo_from = geo_point(src_lon, src_lat)
          geo_to = geo_point(dst_lon, dst_lat)
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
            magnitude: magnitude,
            bytes: magnitude,
            packets: to_int(packets),
            flow_count: to_int(flow_count),
            color: if(threat_matched, do: [244, 63, 94, 245], else: flow_color(idx, magnitude))
          }
        end)

      _ ->
        []
    end
  end

  defp threat_select_expr(true) do
    """
      COALESCE(BOOL_OR(src_threat.ip IS NOT NULL), false) AS src_threat_matched,
      COALESCE(MAX(src_threat.match_count), 0)::integer AS src_threat_match_count,
      COALESCE(MAX(src_threat.max_severity), 0)::integer AS src_threat_max_severity,
      COALESCE(MAX(array_to_string(src_threat.sources, ',')), '') AS src_threat_sources,
      COALESCE(BOOL_OR(dst_threat.ip IS NOT NULL), false) AS dst_threat_matched,
      COALESCE(MAX(dst_threat.match_count), 0)::integer AS dst_threat_match_count,
      COALESCE(MAX(dst_threat.max_severity), 0)::integer AS dst_threat_max_severity,
      COALESCE(MAX(array_to_string(dst_threat.sources, ',')), '') AS dst_threat_sources
    """
  end

  defp threat_select_expr(false) do
    """
      false AS src_threat_matched,
      0 AS src_threat_match_count,
      0 AS src_threat_max_severity,
      '' AS src_threat_sources,
      false AS dst_threat_matched,
      0 AS dst_threat_match_count,
      0 AS dst_threat_max_severity,
      '' AS dst_threat_sources
    """
  end

  defp threat_sources(src_sources, dst_sources) do
    [src_sources, dst_sources]
    |> Enum.flat_map(fn value ->
      value
      |> to_string()
      |> String.split(",", trim: true)
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp topology_links(time_window) do
    case runtime_graph_links() do
      {:ok, links} when is_list(links) ->
        links
        |> Enum.with_index()
        |> Enum.map(&normalize_topology_link/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&dashboard_backbone_link?/1)
        |> Enum.take(@topology_link_limit)
        |> attach_interface_sparklines(cutoff_for_time_window(time_window), sparkline_bucket_for(time_window))

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp runtime_graph_links do
    case RuntimeGraph.get_links() do
      {:ok, []} ->
        RuntimeGraph.refresh_now()
        {:ok, []}

      result ->
        result
    end
  end

  defp normalize_topology_link({%{} = link, idx}) do
    source = link.local_device_id || link.local_device_ip
    target = link.neighbor_device_id || link.neighbor_mgmt_addr || link.neighbor_system_name
    source_label = topology_endpoint_label(link.local_device_id, link.local_device_ip, nil)
    target_label = topology_endpoint_label(link.neighbor_device_id, link.neighbor_mgmt_addr, link.neighbor_system_name)

    if present?(source) and present?(target) and source != target do
      bps =
        [
          Map.get(link, :flow_bps),
          Map.get(link, :flow_bps_ab),
          Map.get(link, :flow_bps_ba)
        ]
        |> Enum.map(&to_int/1)
        |> Enum.max(fn -> 0 end)

      capacity_bps = to_int(Map.get(link, :capacity_bps))

      %{
        id: "topology-#{idx}",
        from: point_for(source),
        to: point_for(target),
        source_id: source,
        target_id: target,
        source_label: source_label,
        target_label: target_label,
        local_if_index: link.local_if_index || link.local_if_index_ab,
        neighbor_if_index: link.neighbor_if_index || link.local_if_index_ba,
        local_if_name: link.local_if_name || link.local_if_name_ab,
        neighbor_if_name: link.neighbor_if_name || link.local_if_name_ba,
        protocol: link.protocol || "topology",
        evidence_class: link.evidence_class || "",
        topology_plane: topology_plane(link),
        telemetry_source: link.telemetry_source || "topology",
        magnitude: bps,
        flow_bps: bps,
        flow_bps_ab: to_int(Map.get(link, :flow_bps_ab)),
        flow_bps_ba: to_int(Map.get(link, :flow_bps_ba)),
        capacity_bps: capacity_bps,
        utilization_pct: utilization_pct(bps, capacity_bps),
        color: topology_color(link, bps)
      }
    end
  end

  defp normalize_topology_link(_), do: nil

  defp topology_endpoint_label(id, ip, name) do
    cond do
      present?(name) -> name
      present?(ip) -> ip
      present?(id) -> compact_identifier(id)
      true -> "unknown"
    end
  end

  defp compact_identifier(value) do
    value
    |> to_string()
    |> String.replace_prefix("sr:", "")
    |> String.replace_prefix("device:", "")
    |> String.slice(0, 12)
  end

  defp attach_interface_sparklines(links, _cutoff, _bucket) when links == [], do: links

  defp attach_interface_sparklines(links, cutoff, bucket) do
    if relation_exists?("platform.timeseries_metrics") do
      pairs =
        links
        |> Enum.flat_map(&topology_interface_pairs/1)
        |> Enum.uniq()
        |> Enum.take(@topology_sparkline_interface_limit)

      sparkline_by_pair = interface_sparkline_map(pairs, cutoff, bucket)

      Enum.map(links, fn link ->
        local_key = interface_pair_key(link.source_label, link.local_if_index)
        neighbor_key = interface_pair_key(link.target_label, link.neighbor_if_index)

        sparkline =
          Map.get(sparkline_by_pair, local_key) ||
            Map.get(sparkline_by_pair, neighbor_key) ||
            []

        link
        |> Map.put(:sparkline, sparkline)
        |> Map.put(:sparkline_label, "SNMP interface rate")
        |> apply_sparkline_rate()
      end)
    else
      links
    end
  rescue
    _ -> links
  end

  defp topology_interface_pairs(link) do
    Enum.reject(
      [
        interface_pair_key(Map.get(link, :source_id) || link.source_label, link.local_if_index),
        interface_pair_key(Map.get(link, :target_id) || link.target_label, link.neighbor_if_index)
      ],
      &is_nil/1
    )
  end

  defp interface_pair_key(device_id, if_index) do
    cond do
      not is_binary(device_id) or not String.starts_with?(device_id, "sr:") ->
        nil

      is_integer(if_index) and if_index >= 0 ->
        {device_id, if_index}

      true ->
        nil
    end
  end

  defp interface_sparkline_map([], _cutoff, _bucket), do: %{}

  defp interface_sparkline_map(pairs, cutoff, bucket) do
    {device_ids, if_indexes} = Enum.unzip(pairs)
    bucket_interval = bucket_interval_literal(bucket)

    sql = """
    WITH wanted(device_id, if_index) AS (
      SELECT * FROM unnest($2::text[], $3::int[])
    )
    SELECT
      m.device_id,
      m.if_index,
      m.metric_name,
      time_bucket(#{bucket_interval}, m.timestamp) AS bucket,
      MAX(m.value)::float8 AS value
    FROM platform.timeseries_metrics m
    INNER JOIN wanted w ON w.device_id = m.device_id AND w.if_index = m.if_index
    WHERE m.timestamp >= $1
      AND m.metric_name = ANY($4::text[])
    GROUP BY m.device_id, m.if_index, m.metric_name, bucket
    ORDER BY m.device_id, m.if_index, m.metric_name, bucket
    """

    case Repo.query(sql, [cutoff, device_ids, if_indexes, @snmp_traffic_metrics]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.group_by(fn [device_id, if_index, _metric, _bucket, _value] -> {device_id, if_index} end)
        |> Map.new(fn {key, grouped_rows} -> {key, build_interface_sparkline(grouped_rows)} end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp build_interface_sparkline(rows) do
    rows
    |> Enum.group_by(fn [_device_id, _if_index, metric_name, _bucket, _value] -> metric_name end)
    |> Enum.flat_map(fn {_metric_name, metric_rows} -> counter_rate_points(metric_rows) end)
    |> Enum.group_by(& &1.bucket, & &1.value)
    |> Enum.map(fn {bucket, values} ->
      %{
        time: bucket,
        value: values |> Enum.sum() |> Float.round(2)
      }
    end)
    |> Enum.sort_by(& &1.time)
    |> Enum.take(-36)
  end

  defp apply_sparkline_rate(%{flow_bps: flow_bps, sparkline: sparkline} = link) do
    latest_bps =
      sparkline
      |> List.last()
      |> case do
        %{value: value} -> to_int(value)
        _ -> 0
      end

    if to_int(flow_bps) > 0 or latest_bps <= 0 do
      link
    else
      link
      |> Map.put(:flow_bps, latest_bps)
      |> Map.put(:magnitude, latest_bps)
      |> Map.put(:utilization_pct, utilization_pct(latest_bps, Map.get(link, :capacity_bps)))
      |> Map.put(:telemetry_source, "snmp")
      |> Map.put(:color, topology_color(link, latest_bps))
    end
  end

  defp apply_sparkline_rate(link), do: link

  defp counter_rate_points(rows) do
    rows
    |> Enum.sort_by(fn [_device_id, _if_index, _metric_name, bucket, _value] -> unix_ms(bucket) end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [
        [_device_id, _if_index, _metric_name, prev_bucket, prev_value],
        [_device_id2, _if_index2, _metric_name2, bucket, value]
      ] ->
        seconds = max((unix_ms(bucket) - unix_ms(prev_bucket)) / 1000, 1)
        delta = to_float(value) - to_float(prev_value)

        if delta >= 0 do
          [%{bucket: bucket_label(bucket), value: delta * 8 / seconds}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp mtr_overlays do
    if mtr_path_edges_present?() do
      cypher = """
      MATCH (a)-[r:MTR_PATH]->(b)
      WHERE a.id IS NOT NULL AND b.id IS NOT NULL
      RETURN {
        source: a.id,
        target: b.id,
        source_addr: coalesce(a.addr, ''),
        target_addr: coalesce(b.addr, ''),
        avg_us: coalesce(r.avg_us, 0),
        loss_pct: coalesce(r.loss_pct, 0.0),
        jitter_us: coalesce(r.jitter_us, 0),
        from_hop: coalesce(r.from_hop, 0),
        to_hop: coalesce(r.to_hop, 0),
        agent_id: coalesce(r.agent_id, '')
      }
      LIMIT #{@mtr_overlay_limit}
      """

      case AgeGraph.query(cypher) do
        {:ok, rows} when is_list(rows) ->
          rows
          |> Enum.map(&normalize_mtr_overlay/1)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp mtr_path_edges_present? do
    case AgeGraph.query("MATCH ()-[r:MTR_PATH]->() RETURN count(r)") do
      {:ok, [%{"count" => count}]} -> to_int(count) > 0
      {:ok, [%{count: count}]} -> to_int(count) > 0
      {:ok, [count]} -> to_int(count) > 0
      _ -> false
    end
  rescue
    _ -> false
  end

  defp normalize_mtr_overlay(%{} = row) do
    row = unwrap_single_map(row)
    source = map_value(row, "source")
    target = map_value(row, "target")

    if present?(source) and present?(target) do
      loss_pct = to_float(map_value(row, "loss_pct"))
      avg_us = to_int(map_value(row, "avg_us"))

      %{
        id: "mtr-#{source}-#{target}",
        from: point_for(map_value(row, "source_addr") || source),
        to: point_for(map_value(row, "target_addr") || target),
        source_label: source,
        target_label: target,
        source_addr: map_value(row, "source_addr") || "",
        target_addr: map_value(row, "target_addr") || "",
        avg_us: avg_us,
        loss_pct: loss_pct,
        jitter_us: to_int(map_value(row, "jitter_us")),
        magnitude: max(avg_us, 1),
        color: mtr_color(loss_pct, avg_us)
      }
    end
  end

  defp normalize_mtr_overlay(_), do: nil

  defp summarize_mtr_overlays([]), do: empty_mtr_summary()

  defp summarize_mtr_overlays(overlays) do
    count = length(overlays)
    avg_loss = overlays |> Enum.map(& &1.loss_pct) |> average()
    avg_latency_ms = overlays |> Enum.map(fn overlay -> overlay.avg_us / 1000 end) |> average()

    %{
      path_count: count,
      avg_loss_pct: Float.round(avg_loss, 2),
      avg_latency_ms: Float.round(avg_latency_ms, 1),
      degraded_count: Enum.count(overlays, &(&1.loss_pct > 0 or &1.avg_us > 100_000))
    }
  end

  defp wifi_map_sites do
    if relation_exists?("platform.wifi_sites") and relation_exists?("platform.wifi_site_snapshots") do
      sql = """
      SELECT
        s.site_code,
        s.name,
        s.site_type,
        s.region,
        s.latitude,
        s.longitude,
        COALESCE(latest.ap_count, 0)::integer AS ap_count,
        COALESCE(latest.up_count, 0)::integer AS up_count,
        COALESCE(latest.down_count, 0)::integer AS down_count,
        COALESCE(latest.model_breakdown, '{}'::jsonb) AS model_breakdown,
        COALESCE(latest.wlc_count, 0)::integer AS wlc_count,
        COALESCE(latest.wlc_model_breakdown, '{}'::jsonb) AS wlc_model_breakdown,
        COALESCE(latest.aos_version_breakdown, '{}'::jsonb) AS aos_version_breakdown,
        COALESCE(to_jsonb(latest.controller_names), '[]'::jsonb) AS controller_names,
        COALESCE(latest.server_group, '') AS server_group,
        COALESCE(latest.cluster, '') AS cluster,
        COALESCE(latest.aaa_profile, '') AS aaa_profile,
        latest.collection_timestamp
      FROM platform.wifi_sites s
      LEFT JOIN LATERAL (
        SELECT *
        FROM platform.wifi_site_snapshots snap
        WHERE snap.source_id = s.source_id AND snap.site_code = s.site_code
        ORDER BY snap.collection_timestamp DESC NULLS LAST, snap.inserted_at DESC
        LIMIT 1
      ) latest ON true
      WHERE s.latitude IS NOT NULL
        AND s.longitude IS NOT NULL
      ORDER BY COALESCE(latest.ap_count, 0) DESC, s.site_code
      LIMIT 500
      """

      case Repo.query(sql, [], timeout: 5_000) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [
                              site_code,
                              name,
                              site_type,
                              region,
                              latitude,
                              longitude,
                              ap_count,
                              up_count,
                              down_count,
                              model_breakdown,
                              wlc_count,
                              wlc_model_breakdown,
                              aos_version_breakdown,
                              controller_names,
                              server_group,
                              cluster,
                              aaa_profile,
                              collection_timestamp
                            ] ->
            %{
              site_code: site_code || "",
              name: name || site_code || "",
              site_type: site_type || "",
              region: region || "",
              latitude: to_float(latitude),
              longitude: to_float(longitude),
              ap_count: to_int(ap_count),
              up_count: to_int(up_count),
              down_count: to_int(down_count),
              model_breakdown: model_breakdown || %{},
              wlc_count: to_int(wlc_count),
              wlc_model_breakdown: wlc_model_breakdown || %{},
              aos_version_breakdown: aos_version_breakdown || %{},
              controller_names: controller_names || [],
              server_group: server_group || "",
              cluster: cluster || "",
              aaa_profile: aaa_profile || "",
              collection_timestamp: format_wifi_timestamp(collection_timestamp)
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp summarize_wifi_map_sites(sites) when is_list(sites) do
    %{
      site_count: length(sites),
      ap_count: sites |> Enum.map(&Map.get(&1, :ap_count, 0)) |> Enum.sum(),
      up_count: sites |> Enum.map(&Map.get(&1, :up_count, 0)) |> Enum.sum(),
      down_count: sites |> Enum.map(&Map.get(&1, :down_count, 0)) |> Enum.sum(),
      wlc_count: sites |> Enum.map(&Map.get(&1, :wlc_count, 0)) |> Enum.sum(),
      region_count:
        sites
        |> Enum.map(&Map.get(&1, :region, ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> length()
    }
  end

  defp summarize_wifi_map_sites(_sites), do: empty_wifi_map_summary()

  defp format_wifi_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp format_wifi_timestamp(%NaiveDateTime{} = timestamp),
    do: timestamp |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp format_wifi_timestamp(_timestamp), do: ""

  defp camera_summary(_scope) do
    if relation_exists?("platform.camera_sources") do
      sql = """
      SELECT id::text, display_name, device_uid, availability_status
      FROM platform.camera_sources
      ORDER BY COALESCE(display_name, device_uid, id::text)
      LIMIT 100
      """

      case Repo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          sources =
            Enum.map(rows, fn [id, display_name, device_uid, availability_status] ->
              %{
                id: id,
                display_name: display_name,
                device_uid: device_uid,
                availability_status: availability_status
              }
            end)

          total = length(sources)

          online =
            Enum.count(sources, fn source ->
              source.availability_status in ["available", "online", "active", "healthy"]
            end)

          %{
            total: total,
            online: online,
            offline: max(total - online, 0),
            recording: active_camera_relay_count(),
            tiles: sources |> Enum.take(4) |> Enum.map(&camera_tile/1)
          }

        _ ->
          empty_camera_summary()
      end
    else
      empty_camera_summary()
    end
  rescue
    _ -> empty_camera_summary()
  end

  defp active_camera_relay_count do
    if relation_exists?("platform.camera_relay_sessions") do
      sql = """
      SELECT COUNT(DISTINCT camera_source_id)::bigint
      FROM platform.camera_relay_sessions
      WHERE status = 'active'
        AND media_ingest_id IS NOT NULL
        AND media_ingest_id <> ''
        AND (lease_expires_at IS NULL OR lease_expires_at > now())
      """

      case Repo.query(sql, []) do
        {:ok, %{rows: [[count]]}} -> to_int(count)
        _ -> 0
      end
    else
      0
    end
  rescue
    _ -> 0
  end

  defp survey_summary(scope) do
    summary =
      cond do
        relation_exists?("platform.survey_rf_pose_matches") ->
          sql = """
          SELECT
            COUNT(*)::bigint AS sample_count,
            COUNT(DISTINCT session_id)::bigint AS session_count,
            COALESCE(AVG(rssi_dbm), 0)::float8 AS avg_rssi,
            COUNT(DISTINCT bssid)::bigint AS secure_count
          FROM platform.survey_rf_pose_matches
          WHERE x IS NOT NULL
            AND z IS NOT NULL
            AND rssi_dbm IS NOT NULL
          """

          case Repo.query(sql, [], timeout: 5_000) do
            {:ok, %{rows: [[samples, sessions, avg_rssi, secure]]}} ->
              %{
                sample_count: to_int(samples),
                session_count: to_int(sessions),
                avg_rssi: avg_rssi |> to_float() |> Float.round(1),
                secure_count: to_int(secure)
              }

            _ ->
              empty_survey_summary()
          end

        relation_exists?("platform.survey_samples") ->
          sql = """
          SELECT
            COUNT(*)::bigint AS sample_count,
            COUNT(DISTINCT session_id)::bigint AS session_count,
            COALESCE(AVG(rssi), 0)::float8 AS avg_rssi,
            COUNT(*) FILTER (WHERE is_secure = true)::bigint AS secure_count
          FROM platform.survey_samples
          """

          case Repo.query(sql, [], timeout: 5_000) do
            {:ok, %{rows: [[samples, sessions, avg_rssi, secure]]}} ->
              %{
                sample_count: to_int(samples),
                session_count: to_int(sessions),
                avg_rssi: avg_rssi |> to_float() |> Float.round(1),
                secure_count: to_int(secure)
              }

            _ ->
              empty_survey_summary()
          end

        true ->
          empty_survey_summary()
      end

    Map.merge(summary, latest_survey_raster_summary(scope))
  rescue
    _ -> empty_survey_summary()
  end

  defp latest_survey_raster_summary(scope) do
    if relation_exists?("platform.survey_coverage_rasters") do
      case playlist_survey_raster_summary(scope) do
        {:ok, summary} ->
          summary

        {:fallback, diagnostics} ->
          Map.put(latest_survey_raster_summary_from_sql(), :raster_playlist_diagnostics, diagnostics)
      end
    else
      empty_survey_raster_summary()
    end
  rescue
    _ -> empty_survey_raster_summary()
  end

  defp playlist_survey_raster_summary(scope) do
    case FieldSurveyDashboardPlaylist.list(scope) do
      {:ok, entries} ->
        entries
        |> Enum.filter(& &1.enabled)
        |> rotate_playlist_entries()
        |> resolve_playlist_entries(scope)

      _ ->
        {:fallback, [playlist_diagnostic("Playlist unavailable")]}
    end
  end

  defp resolve_playlist_entries([], _scope), do: {:fallback, []}

  defp resolve_playlist_entries(entries, scope) do
    entries
    |> Enum.reduce_while([], fn entry, diagnostics ->
      case FieldSurveyDashboardPlaylist.preview(scope, entry.srql_query) do
        {:ok, candidate} ->
          if fresh_raster_candidate?(candidate, entry.max_age_seconds) do
            {:halt, {:ok, dashboard_survey_raster_summary(candidate, entry)}}
          else
            {:cont, [playlist_diagnostic("#{entry.label}: raster is older than max age") | diagnostics]}
          end

        {:error, reason} ->
          {:cont, [playlist_diagnostic("#{entry.label}: #{format_playlist_error(reason)}") | diagnostics]}
      end
    end)
    |> case do
      {:ok, _summary} = result -> result
      diagnostics when is_list(diagnostics) -> {:fallback, Enum.reverse(diagnostics)}
    end
  end

  defp playlist_diagnostic(message), do: %{level: :warning, message: message}

  defp format_playlist_error(:playlist_query_must_target_field_survey_rasters),
    do: "query must target field_survey_rasters"

  defp format_playlist_error(:no_field_survey_raster_candidate), do: "query returned no floorplan-backed raster"

  defp format_playlist_error(reason), do: inspect(reason)

  defp rotate_playlist_entries([]), do: []

  defp rotate_playlist_entries(entries) do
    total_dwell =
      entries
      |> Enum.map(&max(&1.dwell_seconds || 30, 5))
      |> Enum.sum()

    position = rem(System.system_time(:second), max(total_dwell, 1))

    {index, _elapsed} =
      entries
      |> Enum.map(&max(&1.dwell_seconds || 30, 5))
      |> Enum.with_index()
      |> Enum.reduce_while({0, 0}, fn {dwell, index}, {_current_index, elapsed} ->
        next_elapsed = elapsed + dwell

        if position < next_elapsed do
          {:halt, {index, elapsed}}
        else
          {:cont, {index, next_elapsed}}
        end
      end)

    Enum.drop(entries, index) ++ Enum.take(entries, index)
  end

  defp latest_survey_raster_summary_from_sql do
    sql = """
    SELECT r.session_id, r.min_x, r.max_x, r.min_z, r.max_z, r.cells, r.metadata, r.generated_at
    FROM platform.survey_coverage_rasters r
    WHERE r.overlay_type = 'wifi_rssi'
      AND r.selector_type = 'all'
      AND r.selector_value = '*'
    ORDER BY EXISTS (
      SELECT 1
      FROM platform.survey_room_artifacts a
      WHERE a.session_id = r.session_id
        AND a.artifact_type = 'floorplan_geojson'
        AND jsonb_typeof(a.metadata->'floorplan_segments') = 'array'
        AND jsonb_array_length(a.metadata->'floorplan_segments') > 0
    ) DESC,
    r.generated_at DESC
    LIMIT 1
    """

    case Repo.query(sql, [], timeout: 5_000) do
      {:ok, %{rows: [[session_id, _min_x, _max_x, _min_z, _max_z, cells, metadata, generated_at]]}} ->
        dashboard_survey_raster_summary(
          %{
            "session_id" => session_id,
            "cells" => cells,
            "metadata" => metadata,
            "generated_at" => generated_at
          },
          nil
        )

      _ ->
        empty_survey_raster_summary()
    end
  rescue
    _ -> empty_survey_raster_summary()
  end

  defp dashboard_survey_raster_summary(candidate, playlist_entry) when is_map(candidate) do
    session_id = map_value(candidate, "session_id")
    cells_payload = map_value(candidate, "cells") || %{}
    raw_cells = map_value(cells_payload, "cells") || []
    metadata = map_value(candidate, "metadata") || %{}
    raw_raster_cells = raw_cells |> Enum.map(&dashboard_raw_raster_cell/1) |> Enum.reject(&is_nil/1)
    raw_floorplan_segments = latest_dashboard_floorplan_segments(session_id)
    raw_ap_markers = latest_dashboard_ap_markers(session_id)

    {raster_cells, floorplan_segments, ap_markers, aspect_ratio} =
      raw_raster_cells
      |> normalize_dashboard_survey(raw_floorplan_segments)
      |> add_dashboard_ap_markers(raw_ap_markers)

    %{
      raster_session_id: session_id,
      raster_generated_at: map_value(candidate, "generated_at"),
      raster_cell_count: length(raw_cells),
      raster_cells: raster_cells,
      raster_surface_data_uri: nil,
      raster_aspect_ratio: aspect_ratio,
      floorplan_segment_count: length(floorplan_segments),
      floorplan_segments: floorplan_segments,
      ap_marker_count: length(ap_markers),
      ap_markers: ap_markers,
      raster_metadata: metadata,
      raster_playlist_entry_id: playlist_entry && playlist_entry.id,
      raster_playlist_label: playlist_entry && playlist_entry.label,
      raster_playlist_diagnostics: []
    }
  end

  defp fresh_raster_candidate?(candidate, max_age_seconds) when is_map(candidate) and is_integer(max_age_seconds) do
    case parse_dashboard_datetime(map_value(candidate, "generated_at")) do
      %DateTime{} = generated_at ->
        DateTime.diff(DateTime.utc_now(), generated_at, :second) <= max_age_seconds

      _ ->
        true
    end
  end

  defp fresh_raster_candidate?(_candidate, _max_age_seconds), do: true

  defp parse_dashboard_datetime(%DateTime{} = value), do: value

  defp parse_dashboard_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp parse_dashboard_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_dashboard_datetime(_value), do: nil

  defp dashboard_raw_raster_cell(cell) when is_map(cell) do
    x = map_value(cell, "x")
    z = map_value(cell, "z")
    rssi = map_value(cell, "rssi")

    with true <- is_number(x),
         true <- is_number(z),
         true <- is_number(rssi) do
      %{
        x: to_float(x),
        z: to_float(z),
        radius_m: clamp(to_float(map_value(cell, "radius_m") || 0.32), 0.08, 2.5),
        rssi: Float.round(to_float(rssi), 1),
        confidence: clamp(to_float(map_value(cell, "confidence") || 0.5), 0.15, 1.0)
      }
    else
      _ -> nil
    end
  end

  defp dashboard_raw_raster_cell(_cell), do: nil

  defp normalize_dashboard_survey(raw_cells, raw_segments) do
    angle = dashboard_rotation_angle(raw_cells, raw_segments)

    {rotated_cells, rotated_segments, bounds, final_angle} =
      case dashboard_rotated_projection(raw_cells, raw_segments, angle) do
        {cells, segments, %{aspect_ratio: aspect_ratio} = bounds} when aspect_ratio < 1.0 ->
          if raw_cells == [] and raw_segments == [] do
            {cells, segments, bounds, angle}
          else
            {flipped_cells, flipped_segments, flipped_bounds} =
              dashboard_rotated_projection(raw_cells, raw_segments, angle + :math.pi() / 2.0)

            {flipped_cells, flipped_segments, flipped_bounds, angle + :math.pi() / 2.0}
          end

        {cells, segments, bounds} ->
          {cells, segments, bounds, angle}
      end

    raster_cells =
      rotated_cells
      |> Enum.map(&project_dashboard_cell(&1, bounds))
      |> Enum.sort_by(& &1.confidence, :desc)
      |> Enum.take(900)

    floorplan_segments =
      rotated_segments
      |> Enum.map(&project_dashboard_segment(&1, bounds))
      |> Enum.reject(&zero_dashboard_segment?/1)
      |> Enum.take(180)

    {raster_cells, floorplan_segments, bounds, final_angle, Map.get(bounds, :aspect_ratio, 1.78)}
  end

  defp add_dashboard_ap_markers({raster_cells, floorplan_segments, bounds, angle, aspect_ratio}, raw_ap_markers) do
    ap_markers =
      raw_ap_markers
      |> Enum.map(&score_dashboard_ap_marker/1)
      |> Enum.filter(&dashboard_ap_marker_candidate?/1)
      |> Enum.sort_by(
        fn marker ->
          {marker.confidence || 0.0, marker.sample_count || 0, marker.strongest_rssi || -120}
        end,
        :desc
      )
      |> cluster_dashboard_ap_markers()
      |> Enum.map(&rotate_dashboard_point(&1, angle))
      |> Enum.map(&project_dashboard_ap_marker(&1, bounds))
      |> Enum.reject(&is_nil/1)
      |> Enum.take(3)

    {raster_cells, floorplan_segments, ap_markers, aspect_ratio}
  end

  defp dashboard_rotated_projection(raw_cells, raw_segments, angle) do
    rotated_cells = Enum.map(raw_cells, &rotate_dashboard_point(&1, angle))
    rotated_segments = Enum.map(raw_segments, &rotate_dashboard_segment(&1, angle))
    bounds = dashboard_projection_bounds(rotated_cells, rotated_segments)

    {rotated_cells, rotated_segments, bounds}
  end

  defp dashboard_rotation_angle(_raw_cells, [_ | _] = raw_segments) do
    primary_segments =
      case Enum.filter(raw_segments, &(&1.kind == "wall")) do
        [] -> raw_segments
        walls -> walls
      end

    primary_segments
    |> Enum.max_by(&dashboard_segment_length/1, fn -> nil end)
    |> case do
      %{start_x: start_x, start_z: start_z, end_x: end_x, end_z: end_z} ->
        :math.atan2(end_z - start_z, end_x - start_x)

      _ ->
        0.0
    end
    |> normalize_dashboard_angle()
  end

  defp dashboard_rotation_angle([_ | _] = raw_cells, _raw_segments) do
    count = length(raw_cells)
    mean_x = raw_cells |> Enum.map(& &1.x) |> Enum.sum() |> Kernel./(count)
    mean_z = raw_cells |> Enum.map(& &1.z) |> Enum.sum() |> Kernel./(count)

    {cov_xx, cov_zz, cov_xz} =
      Enum.reduce(raw_cells, {0.0, 0.0, 0.0}, fn cell, {xx, zz, xz} ->
        dx = cell.x - mean_x
        dz = cell.z - mean_z
        {xx + dx * dx, zz + dz * dz, xz + dx * dz}
      end)

    normalize_dashboard_angle(0.5 * :math.atan2(2.0 * cov_xz, cov_xx - cov_zz))
  end

  defp dashboard_rotation_angle(_raw_cells, _raw_segments), do: 0.0

  defp normalize_dashboard_angle(angle) do
    cond do
      angle > :math.pi() / 2.0 -> angle - :math.pi()
      angle < -:math.pi() / 2.0 -> angle + :math.pi()
      true -> angle
    end
  end

  defp rotate_dashboard_point(%{x: x, z: z} = point, angle) do
    cos = :math.cos(-angle)
    sin = :math.sin(-angle)

    point
    |> Map.put(:x_rot, x * cos - z * sin)
    |> Map.put(:z_rot, x * sin + z * cos)
  end

  defp rotate_dashboard_segment(segment, angle) do
    start = rotate_dashboard_point(%{x: segment.start_x, z: segment.start_z}, angle)
    finish = rotate_dashboard_point(%{x: segment.end_x, z: segment.end_z}, angle)

    segment
    |> Map.put(:start_x_rot, start.x_rot)
    |> Map.put(:start_z_rot, start.z_rot)
    |> Map.put(:end_x_rot, finish.x_rot)
    |> Map.put(:end_z_rot, finish.z_rot)
  end

  defp dashboard_projection_bounds(rotated_cells, rotated_segments) do
    points =
      Enum.map(rotated_cells, &%{x: &1.x_rot, z: &1.z_rot}) ++
        Enum.flat_map(rotated_segments, fn segment ->
          [
            %{x: segment.start_x_rot, z: segment.start_z_rot},
            %{x: segment.end_x_rot, z: segment.end_z_rot}
          ]
        end)

    xs = Enum.map(points, & &1.x)
    zs = Enum.map(points, & &1.z)

    case {Enum.min(xs, fn -> nil end), Enum.max(xs, fn -> nil end), Enum.min(zs, fn -> nil end),
          Enum.max(zs, fn -> nil end)} do
      {nil, _, _, _} ->
        %{min_x: -1.0, max_x: 1.0, min_z: -1.0, max_z: 1.0, aspect_ratio: 1.0}

      {min_x, max_x, min_z, max_z} ->
        x_pad = max((max_x - min_x) * 0.08, 0.6)
        z_pad = max((max_z - min_z) * 0.08, 0.6)
        min_x = min_x - x_pad
        max_x = max_x + x_pad
        min_z = min_z - z_pad
        max_z = max_z + z_pad
        width = max(max_x - min_x, 0.01)
        height = max(max_z - min_z, 0.01)

        %{
          min_x: min_x,
          max_x: max_x,
          min_z: min_z,
          max_z: max_z,
          aspect_ratio: clamp(width / height, 0.72, 3.2)
        }
    end
  end

  defp project_dashboard_cell(cell, bounds) do
    width = max(bounds.max_x - bounds.min_x, 0.01)
    height = max(bounds.max_z - bounds.min_z, 0.01)
    meters_per_pct = max(width, height) / 100.0

    cell
    |> Map.put(:x_pct, clamp((cell.x_rot - bounds.min_x) / width * 100.0, 0.0, 100.0))
    |> Map.put(:z_pct, 100.0 - clamp((cell.z_rot - bounds.min_z) / height * 100.0, 0.0, 100.0))
    |> Map.put(:radius_pct, clamp(cell.radius_m / max(meters_per_pct, 0.01), 1.6, 7.0))
  end

  defp project_dashboard_segment(segment, bounds) do
    width = max(bounds.max_x - bounds.min_x, 0.01)
    height = max(bounds.max_z - bounds.min_z, 0.01)

    segment
    |> Map.put(:start_x_pct, clamp((segment.start_x_rot - bounds.min_x) / width * 100.0, 0.0, 100.0))
    |> Map.put(:start_z_pct, 100.0 - clamp((segment.start_z_rot - bounds.min_z) / height * 100.0, 0.0, 100.0))
    |> Map.put(:end_x_pct, clamp((segment.end_x_rot - bounds.min_x) / width * 100.0, 0.0, 100.0))
    |> Map.put(:end_z_pct, 100.0 - clamp((segment.end_z_rot - bounds.min_z) / height * 100.0, 0.0, 100.0))
  end

  defp project_dashboard_ap_marker(marker, bounds) do
    width = max(bounds.max_x - bounds.min_x, 0.01)
    height = max(bounds.max_z - bounds.min_z, 0.01)
    x_pct = clamp((marker.x_rot - bounds.min_x) / width * 100.0, 0.0, 100.0)
    z_pct = 100.0 - clamp((marker.z_rot - bounds.min_z) / height * 100.0, 0.0, 100.0)

    marker
    |> Map.put(:x_pct, x_pct)
    |> Map.put(:z_pct, z_pct)
  end

  defp dashboard_segment_length(%{start_x: start_x, start_z: start_z, end_x: end_x, end_z: end_z}) do
    :math.sqrt(:math.pow(end_x - start_x, 2) + :math.pow(end_z - start_z, 2))
  end

  defp latest_dashboard_ap_markers(_session_id) do
    # AP/device enrichment currently depends on raw RF+pose scans and can block the dashboard.
    # Keep the dashboard card fast; richer AP drill-in belongs behind an indexed summary path.
    []
  end

  defp score_dashboard_ap_marker(
         %{sample_count: sample_count, support_count: support_count, strongest_rssi: strongest_rssi} = marker
       ) do
    sample_score = min(:math.log10(max(sample_count, 1)) / 3.0, 1.0)
    support_score = min(:math.log10(max(support_count, 1)) / 2.3, 1.0)
    signal_score = min(max((strongest_rssi + 86.0) / 36.0, 0.0), 1.0)
    confidence = sample_score * 0.36 + support_score * 0.34 + signal_score * 0.3

    Map.put(marker, :confidence, Float.round(confidence, 3))
  end

  defp dashboard_ap_marker_candidate?(marker) do
    (Map.get(marker, :confidence) || 0.0) >= 0.82 and
      (Map.get(marker, :support_count) || 0) >= 20 and
      is_number(Map.get(marker, :x)) and
      is_number(Map.get(marker, :z)) and
      not invalid_dashboard_bssid?(Map.get(marker, :bssid))
  end

  defp cluster_dashboard_ap_markers(markers) do
    Enum.reduce(markers, [], fn marker, selected ->
      if Enum.any?(selected, &same_dashboard_ap_candidate?(&1, marker)) do
        selected
      else
        selected ++ [marker]
      end
    end)
  end

  defp same_dashboard_ap_candidate?(left, right) do
    distance =
      :math.sqrt(
        :math.pow((Map.get(left, :x) || 0.0) - (Map.get(right, :x) || 0.0), 2) +
          :math.pow((Map.get(left, :z) || 0.0) - (Map.get(right, :z) || 0.0), 2)
      )

    same_dashboard_radio_family?(Map.get(left, :bssid), Map.get(right, :bssid)) or distance <= 1.8
  end

  defp same_dashboard_radio_family?(left, right) when is_binary(left) and is_binary(right) do
    left_parts = left |> String.downcase() |> String.split(":")
    right_parts = right |> String.downcase() |> String.split(":")

    length(left_parts) == 6 and length(right_parts) == 6 and Enum.take(left_parts, 4) == Enum.take(right_parts, 4)
  end

  defp same_dashboard_radio_family?(_left, _right), do: false

  defp invalid_dashboard_bssid?(bssid) when is_binary(bssid) do
    normalized = String.downcase(String.trim(bssid))
    normalized in ["", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"]
  end

  defp invalid_dashboard_bssid?(_bssid), do: true

  defp latest_dashboard_floorplan_segments(session_id) do
    if relation_exists?("platform.survey_room_artifacts") do
      sql = """
      SELECT metadata
      FROM platform.survey_room_artifacts
      WHERE session_id = $1
        AND artifact_type = 'floorplan_geojson'
        AND jsonb_typeof(metadata->'floorplan_segments') = 'array'
        AND jsonb_array_length(metadata->'floorplan_segments') > 0
      ORDER BY uploaded_at DESC
      LIMIT 1
      """

      case Repo.query(sql, [session_id]) do
        {:ok, %{rows: [[metadata]]}} ->
          FieldSurveyFloorplan.segments_from_metadata(metadata)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp zero_dashboard_segment?(segment) do
    abs(segment.start_x_pct - segment.end_x_pct) < 0.01 and abs(segment.start_z_pct - segment.end_z_pct) < 0.01
  end

  defp security_trend(time_window) do
    cutoff = cutoff_for_time_window(time_window)

    if relation_exists?("platform.ocsf_events") do
      sql = """
      SELECT
        date_trunc('hour', time) AS bucket,
        COUNT(*)::bigint AS total,
        COUNT(*) FILTER (WHERE COALESCE(severity_id, 0) BETWEEN 1 AND 2)::bigint AS low,
        COUNT(*) FILTER (WHERE COALESCE(severity_id, 0) = 3)::bigint AS medium,
        COUNT(*) FILTER (WHERE COALESCE(severity_id, 0) = 4)::bigint AS high,
        COUNT(*) FILTER (WHERE COALESCE(severity_id, 0) >= 5)::bigint AS critical
      FROM ocsf_events
      WHERE time >= $1
      GROUP BY 1
      ORDER BY 1 ASC
      LIMIT 48
      """

      case Repo.query(sql, [cutoff]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [bucket, total, low, medium, high, critical] ->
            %{
              bucket: bucket,
              label: format_bucket(bucket),
              total: to_int(total),
              low: to_int(low),
              medium: to_int(medium),
              high: to_int(high),
              critical: to_int(critical)
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp dashboard_sparklines(time_window, security_trend, mtr_overlays) do
    %{
      assets: device_activity_sparkline(time_window),
      threats: security_trend |> Enum.map(&(&1.high + &1.critical)) |> sparkline_tail(),
      network_health: service_availability_sparkline(time_window),
      camera: camera_activity_sparkline(time_window),
      survey: survey_sample_sparkline(time_window),
      throughput: flow_traffic_sparkline(time_window, :bps),
      service_health: service_availability_sparkline(time_window),
      latency: trace_sparkline(time_window, :latency_ms, mtr_overlays),
      packet_loss: mtr_overlay_sparkline(mtr_overlays, :loss_pct)
    }
  rescue
    _ -> empty_sparklines()
  end

  defp empty_sparklines do
    %{
      assets: [],
      threats: [],
      network_health: [],
      camera: [],
      survey: [],
      throughput: [],
      service_health: [],
      latency: [],
      packet_loss: []
    }
  end

  defp flow_traffic_sparkline(time_window, metric) do
    cutoff = cutoff_for_time_window(time_window)

    Enum.find_value(flow_sparkline_sources(time_window), [], fn {relation_ref, relation, time_column, bucket_seconds} ->
      if relation_exists?(relation_ref) do
        values = flow_traffic_sparkline_from_relation(relation, time_column, cutoff, bucket_seconds, metric)
        if values != [], do: values
      end
    end)
  rescue
    _ -> []
  end

  defp flow_sparkline_sources(time_window) when time_window in ["last_7d", "last_30d"] do
    [
      {"platform.flow_traffic_1h", "platform.flow_traffic_1h", "bucket", 3600},
      {"platform.ocsf_network_activity_5m_traffic", "platform.ocsf_network_activity_5m_traffic", "bucket", 300},
      {"platform.ocsf_network_activity", "platform.ocsf_network_activity", "time", bucket_seconds_for(time_window)}
    ]
  end

  defp flow_sparkline_sources(time_window) do
    [
      {"platform.ocsf_network_activity_5m_traffic", "platform.ocsf_network_activity_5m_traffic", "bucket", 300},
      {"platform.flow_traffic_1h", "platform.flow_traffic_1h", "bucket", 3600},
      {"platform.ocsf_network_activity", "platform.ocsf_network_activity", "time", bucket_seconds_for(time_window)}
    ]
  end

  defp flow_traffic_sparkline_from_relation(
         "platform.ocsf_network_activity" = relation,
         time_column,
         cutoff,
         seconds,
         metric
       ) do
    bucket_interval = bucket_interval_literal(sparkline_bucket_for_from_seconds(seconds))

    sql = """
    SELECT
      time_bucket(#{bucket_interval}, #{time_column}) AS bucket,
      COALESCE(SUM(bytes_total), 0)::float8 AS bytes_total,
      COALESCE(SUM(packets_total), 0)::float8 AS packets_total,
      COUNT(*)::float8 AS flow_count
    FROM #{relation}
    WHERE #{time_column} >= $1
    GROUP BY 1
    ORDER BY 1 ASC
    LIMIT $2
    """

    sparkline_query_values(sql, [cutoff, @dashboard_sparkline_limit * 2], metric, seconds)
  end

  defp flow_traffic_sparkline_from_relation(relation, time_column, cutoff, seconds, metric) do
    sql = """
    SELECT
      #{time_column} AS bucket,
      COALESCE(SUM(bytes_total), 0)::float8 AS bytes_total,
      COALESCE(SUM(packets_total), 0)::float8 AS packets_total,
      COALESCE(SUM(flow_count), 0)::float8 AS flow_count
    FROM #{relation}
    WHERE #{time_column} >= $1
    GROUP BY 1
    ORDER BY 1 ASC
    LIMIT $2
    """

    sparkline_query_values(sql, [cutoff, @dashboard_sparkline_limit * 2], metric, seconds)
  end

  defp sparkline_query_values(sql, params, metric, seconds) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [_bucket, bytes, packets, flows] ->
          case metric do
            :bps -> to_float(bytes) * 8 / max(seconds, 1)
            :pps -> to_float(packets) / max(seconds, 1)
            :flows -> to_float(flows)
            _ -> to_float(bytes)
          end
        end)
        |> sparkline_tail()

      _ ->
        []
    end
  end

  defp service_availability_sparkline(time_window) do
    if relation_exists?("platform.services_availability_5m") do
      sql = """
      SELECT
        bucket,
        CASE
          WHEN COALESCE(SUM(total_count), 0) = 0 THEN 0.0
          ELSE COALESCE(SUM(available_count), 0)::float8 / COALESCE(SUM(total_count), 0)::float8 * 100.0
        END AS availability_pct
      FROM platform.services_availability_5m
      WHERE bucket >= $1
      GROUP BY bucket
      ORDER BY bucket ASC
      LIMIT $2
      """

      one_value_sparkline(sql, [cutoff_for_time_window(time_window), @dashboard_sparkline_limit * 2])
    else
      []
    end
  rescue
    _ -> []
  end

  defp trace_sparkline(time_window, metric, mtr_overlays) do
    rollup_values =
      if relation_exists?("platform.traces_stats_5m") do
        trace_rollup_sparkline(time_window, metric)
      else
        []
      end

    if rollup_values == [] and metric == :latency_ms do
      mtr_overlay_sparkline(mtr_overlays, :avg_latency_ms)
    else
      rollup_values
    end
  rescue
    _ -> []
  end

  defp trace_rollup_sparkline(time_window, :latency_ms) do
    sql = """
    SELECT bucket, COALESCE(AVG(avg_duration_ms), 0)::float8
    FROM platform.traces_stats_5m
    WHERE bucket >= $1
    GROUP BY bucket
    ORDER BY bucket ASC
    LIMIT $2
    """

    one_value_sparkline(sql, [cutoff_for_time_window(time_window), @dashboard_sparkline_limit * 2])
  end

  defp trace_rollup_sparkline(time_window, :success_pct) do
    sql = """
    SELECT
      bucket,
      CASE
        WHEN COALESCE(SUM(total_count), 0) = 0 THEN 100.0
        ELSE (1.0 - COALESCE(SUM(error_count), 0)::float8 / COALESCE(SUM(total_count), 0)::float8) * 100.0
      END AS success_pct
    FROM platform.traces_stats_5m
    WHERE bucket >= $1
    GROUP BY bucket
    ORDER BY bucket ASC
    LIMIT $2
    """

    one_value_sparkline(sql, [cutoff_for_time_window(time_window), @dashboard_sparkline_limit * 2])
  end

  defp trace_rollup_sparkline(_time_window, _metric), do: []

  defp device_activity_sparkline(time_window) do
    if relation_exists?("platform.ocsf_devices") do
      sql = """
      SELECT
        time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, last_seen_time) AS bucket,
        COUNT(*) FILTER (WHERE COALESCE(is_available, false) = true)::float8 AS value
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL
        AND last_seen_time >= $1
      GROUP BY 1
      ORDER BY 1 ASC
      LIMIT $2
      """

      one_value_sparkline(sql, [cutoff_for_time_window(time_window), @dashboard_sparkline_limit * 2])
    else
      []
    end
  rescue
    _ -> []
  end

  defp camera_activity_sparkline(time_window) do
    if relation_exists?("platform.camera_sources") do
      sql = """
      SELECT
        time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, COALESCE(last_activity_at, last_event_at, updated_at)) AS bucket,
        COUNT(*) FILTER (WHERE availability_status IN ('available', 'online', 'active', 'healthy'))::float8 AS value
      FROM platform.camera_sources
      WHERE COALESCE(last_activity_at, last_event_at, updated_at) >= $1
      GROUP BY 1
      ORDER BY 1 ASC
      LIMIT $2
      """

      one_value_sparkline(sql, [cutoff_for_time_window(time_window), @dashboard_sparkline_limit * 2])
    else
      []
    end
  rescue
    _ -> []
  end

  defp survey_sample_sparkline(time_window) do
    cond do
      relation_exists?("platform.survey_rf_pose_matches") ->
        sql = """
        SELECT
          time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, rf_captured_at) AS bucket,
          COUNT(*)::float8 AS value
        FROM platform.survey_rf_pose_matches
        WHERE rf_captured_at >= $1
          AND x IS NOT NULL
          AND z IS NOT NULL
          AND rssi_dbm IS NOT NULL
        GROUP BY 1
        ORDER BY 1 ASC
        LIMIT $2
        """

        one_value_sparkline(sql, [cutoff_for_time_window(time_window), @dashboard_sparkline_limit * 2])

      relation_exists?("platform.survey_samples") ->
        sql = """
        SELECT
          time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, timestamp) AS bucket,
          COUNT(*)::float8 AS value
        FROM platform.survey_samples
        WHERE timestamp >= $1
        GROUP BY 1
        ORDER BY 1 ASC
        LIMIT $2
        """

        one_value_sparkline(sql, [cutoff_for_time_window(time_window), @dashboard_sparkline_limit * 2])

      true ->
        []
    end
  rescue
    _ -> []
  end

  defp one_value_sparkline(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [_bucket, value] -> to_float(value) end)
        |> sparkline_tail()

      _ ->
        []
    end
  end

  defp mtr_overlay_sparkline([], _metric), do: []

  defp mtr_overlay_sparkline(overlays, :avg_latency_ms) do
    overlays
    |> Enum.map(fn overlay -> to_float(overlay.avg_us) / 1000 end)
    |> sparkline_tail()
  end

  defp mtr_overlay_sparkline(overlays, :loss_pct) do
    overlays
    |> Enum.map(&to_float(&1.loss_pct))
    |> sparkline_tail()
  end

  defp mtr_overlay_sparkline(_overlays, _metric), do: []

  defp sparkline_tail(values) do
    values
    |> Enum.map(&to_float/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(-@dashboard_sparkline_limit)
  end

  defp alert_feed(time_window) do
    if relation_exists?("platform.alerts") do
      cutoff = cutoff_for_time_window(time_window)

      sql = """
      SELECT
        id::text,
        COALESCE(title, '') AS title,
        COALESCE(description, '') AS description,
        COALESCE(severity::text, '') AS severity,
        COALESCE(status::text, '') AS status,
        COALESCE(source_type::text, '') AS source_type,
        COALESCE(device_uid, '') AS device_uid,
        COALESCE(triggered_at, created_at) AS observed_at
      FROM platform.alerts
      WHERE COALESCE(triggered_at, created_at) >= $1
      ORDER BY COALESCE(triggered_at, created_at) DESC
      LIMIT 8
      """

      case Repo.query(sql, [cutoff]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, title, description, severity, status, source_type, device_uid, observed_at] ->
            %{
              id: id,
              title: first_present([title, description, "Untitled alert"]),
              description: description,
              severity: severity,
              status: status,
              source_type: source_type,
              device_uid: device_uid,
              observed_at: observed_at,
              observed_label: format_alert_time(observed_at)
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp threat_intel_summary do
    empty_threat_intel_summary()
    |> Map.merge(threat_intel_indicator_counts())
    |> Map.merge(threat_intel_match_counts())
    |> Map.merge(threat_intel_latest_status())
  rescue
    _ -> empty_threat_intel_summary()
  end

  defp threat_intel_indicator_counts do
    counts =
      if relation_exists?("platform.threat_intel_indicators") do
        sql = """
        SELECT
          COUNT(*)::bigint,
          COUNT(DISTINCT source)::bigint
        FROM platform.threat_intel_indicators
        WHERE expires_at IS NULL OR expires_at > now()
        """

        case Repo.query(sql, []) do
          {:ok, %{rows: [[indicators, sources]]}} ->
            %{imported_indicators: to_int(indicators), sources: to_int(sources)}

          _ ->
            %{}
        end
      else
        %{}
      end

    source_objects =
      if relation_exists?("platform.threat_intel_source_objects") do
        case Repo.query("SELECT COUNT(*)::bigint FROM platform.threat_intel_source_objects", []) do
          {:ok, %{rows: [[count]]}} -> %{source_objects: to_int(count)}
          _ -> %{}
        end
      else
        %{}
      end

    Map.merge(counts, source_objects)
  end

  defp threat_intel_match_counts do
    if relation_exists?("platform.ip_threat_intel_cache") do
      sql = """
      SELECT
        COUNT(*) FILTER (WHERE matched = true AND expires_at > now())::bigint,
        COALESCE(SUM(match_count) FILTER (WHERE matched = true AND expires_at > now()), 0)::bigint,
        COALESCE(MAX(max_severity) FILTER (WHERE matched = true AND expires_at > now()), 0)::integer
      FROM platform.ip_threat_intel_cache
      """

      case Repo.query(sql, []) do
        {:ok, %{rows: [[matched_ips, indicator_matches, max_severity]]}} ->
          %{
            matched_ips: to_int(matched_ips),
            indicator_matches: to_int(indicator_matches),
            max_severity: to_int(max_severity)
          }

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp threat_intel_latest_status do
    if relation_exists?("platform.threat_intel_sync_statuses") do
      sql = """
      SELECT
        provider,
        source,
        last_status,
        COALESCE(last_message, last_error, ''),
        last_attempt_at,
        last_success_at,
        indicators_count,
        skipped_count,
        total_count
      FROM platform.threat_intel_sync_statuses
      ORDER BY last_attempt_at DESC
      LIMIT 1
      """

      case Repo.query(sql, []) do
        {:ok, %{rows: [[provider, source, status, message, attempted_at, success_at, indicators, skipped, total]]}} ->
          %{
            latest_provider: provider,
            latest_source: source,
            latest_status: status,
            latest_message: message,
            latest_attempt_at: attempted_at,
            latest_success_at: success_at,
            latest_sync_indicators: to_int(indicators),
            latest_sync_skipped: to_int(skipped),
            latest_sync_total: to_int(total),
            latest_attempt_label: format_alert_time(attempted_at),
            latest_success_label: format_alert_time(success_at)
          }

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp module_states(
         collector_counts,
         flow_summary,
         traffic_links,
         mtr_summary,
         camera_summary,
         survey_summary,
         wifi_map_summary,
         event_summary,
         alert_summary
       ) do
    netflow_configured? = Map.get(collector_counts, "netflow", 0) > 0 or Map.get(collector_counts, "sflow", 0) > 0
    flow_active? = flow_summary.flow_count > 0 or traffic_links != []

    %{
      inventory: :active,
      health: :active,
      netflow: source_state(netflow_configured?, flow_active?),
      mtr: source_state(false, mtr_summary.path_count > 0),
      camera: source_state(false, camera_summary.total > 0),
      fieldsurvey: source_state(false, survey_available?(survey_summary)),
      wifi_map: source_state(false, wifi_map_summary.site_count > 0),
      security_events: source_state(false, event_summary.total > 0),
      vulnerable_assets: :unconnected,
      siem: source_state(false, alert_summary.total > 0)
    }
  end

  defp source_state(_configured?, true), do: :active
  defp source_state(true, false), do: :configured_empty
  defp source_state(false, false), do: :unconfigured

  defp enabled_modules(states) do
    states
    |> Enum.filter(fn {_key, state} -> state in [:active, :configured_empty] end)
    |> Enum.map(&elem(&1, 0))
  end

  defp kpi_cards(device, services, flows, camera, survey, alerts, events, sparklines) do
    [
      %{
        title: "Total Assets",
        value: format_compact_count(device.total),
        detail: "#{format_count(device.available)} available",
        icon: "hero-server-stack",
        tone: "success",
        sparkline: Map.get(sparklines, :assets, [])
      },
      %{
        title: "Threat Level",
        value: threat_level(alerts, events),
        detail: threat_detail(alerts, events),
        icon: "hero-shield-exclamation",
        tone: threat_tone(alerts, events),
        sparkline: Map.get(sparklines, :threats, [])
      },
      %{
        title: "Network Health",
        value: network_health_value(services, flows),
        detail: network_health_detail(services, flows),
        icon: "hero-heart",
        tone: network_health_tone(services),
        sparkline: Map.get(sparklines, :network_health, [])
      },
      %{
        title: "Camera Fleet",
        value: format_compact_count(camera.total),
        detail: "#{format_count(camera.online)} available",
        icon: "hero-video-camera",
        tone: "info",
        sparkline: Map.get(sparklines, :camera, [])
      },
      survey_kpi_card(survey, Map.get(sparklines, :survey, []))
    ]
  end

  defp map_stats(_flows, _mtr, traffic_links) do
    link_count = length(List.wrap(traffic_links))
    window_bytes = traffic_links |> Enum.map(&to_int(Map.get(&1, :bytes, Map.get(&1, "bytes", 0)))) |> Enum.sum()

    window_flows =
      traffic_links |> Enum.map(&to_int(Map.get(&1, :flow_count, Map.get(&1, "flow_count", 0)))) |> Enum.sum()

    geo_mapped = Enum.count(traffic_links, &Map.get(&1, :geo_mapped, Map.get(&1, "geo_mapped", false)))
    geo_pct = if link_count > 0, do: geo_mapped * 100 / link_count, else: 0

    [
      %{label: "Window", value: netflow_map_window_label()},
      %{label: "Conversations", value: format_count(link_count)},
      %{label: "Flow Records", value: format_count(window_flows)},
      %{label: "Traffic", value: format_bytes(window_bytes)},
      %{label: "Geo Mapped", value: "#{format_percent(geo_pct)}%"}
    ]
  end

  defp observability_metrics(flows, mtr, traces, services, sparklines) do
    mtr_available? = to_int(mtr.path_count) > 0
    flows_available? = to_int(flows.flow_count) > 0 or to_int(flows.bytes_total) > 0
    service_available? = to_int(services.total) > 0 or to_int(traces.total) > 0

    [
      %{
        label: "Latency (Avg)",
        value: if(mtr_available?, do: format_float(mtr.avg_latency_ms), else: "No MTR"),
        scale: if(mtr_available?, do: "ms", else: ""),
        available: mtr_available?,
        tone: metric_tone(mtr.avg_latency_ms, 150),
        sparkline: Map.get(sparklines, :latency, []),
        axis_min: "0",
        axis_mid: "75",
        axis_max: "150"
      },
      %{
        label: "Packet Loss",
        value: if(mtr_available?, do: format_float(mtr.avg_loss_pct), else: "No MTR"),
        scale: if(mtr_available?, do: "%", else: ""),
        available: mtr_available?,
        tone: metric_tone(mtr.avg_loss_pct, 1),
        sparkline: Map.get(sparklines, :packet_loss, []),
        axis_min: "0%",
        axis_mid: packet_loss_axis_mid(Map.get(sparklines, :packet_loss, []), mtr.avg_loss_pct),
        axis_max: packet_loss_axis_max(Map.get(sparklines, :packet_loss, []), mtr.avg_loss_pct)
      },
      %{
        label: "Throughput",
        value: if(flows_available?, do: format_rate(flows.bps), else: "No data"),
        scale: if(flows_available?, do: "bps", else: ""),
        available: flows_available?,
        tone: "info",
        sparkline: Map.get(sparklines, :throughput, []),
        axis_min: "0",
        axis_mid: "5G",
        axis_max: "10G"
      },
      %{
        label: "Service Health",
        value: if(service_available?, do: service_health_metric(services, traces), else: "No data"),
        scale: if(service_available?, do: "%", else: ""),
        available: service_available?,
        tone: network_health_tone(services),
        sparkline: Map.get(sparklines, :service_health, []),
        axis_min: "90%",
        axis_mid: "95%",
        axis_max: "100%"
      }
    ]
  end

  defp packet_loss_axis_max(values, current) do
    max_value = axis_max_value(values, current)

    cond do
      max_value > 50 -> "100%"
      max_value > 10 -> "50%"
      max_value > 1 -> "10%"
      true -> "1%"
    end
  end

  defp packet_loss_axis_mid(values, current) do
    case packet_loss_axis_max(values, current) do
      "100%" -> "50%"
      "50%" -> "25%"
      "10%" -> "5%"
      _ -> "0.5%"
    end
  end

  defp axis_max_value(values, current) do
    values
    |> Enum.map(&sparkline_numeric_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.concat([to_float(current)])
    |> Enum.max(fn -> 0.0 end)
  end

  defp sparkline_numeric_value(%{value: value}), do: to_float(value)
  defp sparkline_numeric_value(value), do: to_float(value)

  defp empty_device_summary, do: %{total: 0, available: 0, unavailable: 0}
  defp empty_services_summary, do: %{total: 0, available: 0, unavailable: 0, availability_pct: 0.0}
  defp empty_flow_summary, do: %{bytes_total: 0, packets_total: 0, flow_count: 0, bps: 0.0, pps: 0.0, link_count: 0}
  defp empty_mtr_summary, do: %{path_count: 0, avg_loss_pct: 0.0, avg_latency_ms: 0.0, degraded_count: 0}
  defp empty_camera_summary, do: %{total: 0, online: 0, offline: 0, recording: 0, tiles: []}

  defp empty_wifi_map_summary,
    do: %{site_count: 0, ap_count: 0, up_count: 0, down_count: 0, wlc_count: 0, region_count: 0}

  defp empty_survey_summary,
    do: Map.merge(%{sample_count: 0, session_count: 0, avg_rssi: 0.0, secure_count: 0}, empty_survey_raster_summary())

  defp empty_survey_raster_summary,
    do: %{
      raster_session_id: nil,
      raster_generated_at: nil,
      raster_cell_count: 0,
      raster_cells: [],
      raster_surface_data_uri: nil,
      raster_aspect_ratio: 1.78,
      floorplan_segment_count: 0,
      floorplan_segments: [],
      ap_marker_count: 0,
      ap_markers: [],
      raster_metadata: %{},
      raster_playlist_entry_id: nil,
      raster_playlist_label: nil,
      raster_playlist_diagnostics: []
    }

  defp empty_alert_summary, do: Stats.empty_alerts_summary()
  defp empty_event_summary, do: Stats.empty_events_summary()

  defp empty_threat_intel_summary,
    do: %{
      imported_indicators: 0,
      source_objects: 0,
      matched_ips: 0,
      indicator_matches: 0,
      max_severity: 0,
      sources: 0,
      latest_provider: nil,
      latest_source: nil,
      latest_status: nil,
      latest_message: nil,
      latest_attempt_at: nil,
      latest_success_at: nil,
      latest_sync_indicators: 0,
      latest_sync_skipped: 0,
      latest_sync_total: 0,
      latest_attempt_label: "",
      latest_success_label: ""
    }

  defp empty_trace_summary,
    do: %{total: 0, errors: 0, avg_duration_ms: 0.0, p95_duration_ms: 0.0, error_rate: 0.0, successful: 0}

  defp relation_exists?(relation_name) do
    case Repo.query("SELECT to_regclass($1) IS NOT NULL", [relation_name]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp netflow_location_anchors_available? do
    relation_exists?("platform.netflow_local_cidrs") and
      column_exists?("platform.netflow_local_cidrs", "latitude") and
      column_exists?("platform.netflow_local_cidrs", "longitude") and
      column_exists?("platform.netflow_local_cidrs", "location_label")
  end

  defp anchor_partition_filter(relation) do
    if column_exists?(qualified_relation_name(relation), "partition") do
      "(c.partition IS NULL OR c.partition = f.partition)"
    else
      "TRUE"
    end
  end

  defp qualified_relation_name("platform." <> _ = relation), do: relation
  defp qualified_relation_name(relation), do: "platform.#{relation}"

  defp endpoint_inet_expr(column) do
    """
    (CASE
      WHEN NULLIF(#{column}, '') ~ '^[0-9A-Fa-f:.]+$'
      THEN NULLIF(#{column}, '')::inet
      ELSE NULL::inet
    END)
    """
  end

  defp column_exists?(relation_name, column_name) do
    case String.split(relation_name, ".", parts: 2) do
      [schema, table] ->
        sql = """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = $1
            AND table_name = $2
            AND column_name = $3
        )
        """

        case Repo.query(sql, [schema, table, column_name]) do
          {:ok, %{rows: [[true]]}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp anchored_expr(true, anchor_expr, fallback_expr), do: "COALESCE(#{anchor_expr}, #{fallback_expr})"
  defp anchored_expr(false, _anchor_expr, fallback_expr), do: fallback_expr

  defp anchored_label_expr(true, anchor_alias, fallback_expr),
    do: "COALESCE(#{anchor_alias}.location_label, #{anchor_alias}.label, #{fallback_expr})"

  defp anchored_label_expr(false, _anchor_alias, fallback_expr), do: fallback_expr

  defp anchored_country_expr(true, anchor_alias, fallback_expr) do
    """
    CASE
      WHEN #{anchor_alias}.latitude IS NOT NULL AND #{anchor_alias}.longitude IS NOT NULL
      THEN NULL::text
      ELSE #{fallback_expr}
    END
    """
  end

  defp anchored_country_expr(false, _anchor_alias, fallback_expr), do: fallback_expr

  defp anchor_label_select_expr(true, anchor_alias), do: "#{anchor_alias}.location_label"
  defp anchor_label_select_expr(false, _anchor_alias), do: "NULL::text"

  defp local_anchor_select_expr(true, anchor_alias), do: "(#{anchor_alias}.location_label IS NOT NULL)"
  defp local_anchor_select_expr(false, _anchor_alias), do: "FALSE"

  defp flow_count_expr("ocsf_network_activity"), do: "COUNT(*)"
  defp flow_count_expr(_relation), do: "SUM(flow_count)"

  defp cutoff_for_time_window("last_1h"), do: DateTime.add(DateTime.utc_now(), -1, :hour)
  defp cutoff_for_time_window("last_6h"), do: DateTime.add(DateTime.utc_now(), -6, :hour)
  defp cutoff_for_time_window("last_24h"), do: DateTime.add(DateTime.utc_now(), -24, :hour)
  defp cutoff_for_time_window("last_7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp cutoff_for_time_window("last_30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp cutoff_for_time_window(_), do: cutoff_for_time_window(@default_time_window)

  defp netflow_map_cutoff(_time_window), do: DateTime.add(DateTime.utc_now(), -@netflow_map_window_minutes, :minute)

  defp netflow_map_window_label, do: "Last #{@netflow_map_window_minutes} min"

  defp sparkline_bucket_for("last_1h"), do: "1 minute"
  defp sparkline_bucket_for("last_6h"), do: "5 minutes"
  defp sparkline_bucket_for("last_24h"), do: "15 minutes"
  defp sparkline_bucket_for("last_7d"), do: "1 hour"
  defp sparkline_bucket_for("last_30d"), do: "6 hours"
  defp sparkline_bucket_for(_), do: sparkline_bucket_for(@default_time_window)

  defp bucket_seconds_for("last_1h"), do: 60
  defp bucket_seconds_for("last_6h"), do: 300
  defp bucket_seconds_for("last_24h"), do: 900
  defp bucket_seconds_for("last_7d"), do: 3600
  defp bucket_seconds_for("last_30d"), do: 21_600
  defp bucket_seconds_for(_), do: bucket_seconds_for(@default_time_window)

  defp sparkline_bucket_for_from_seconds(60), do: "1 minute"
  defp sparkline_bucket_for_from_seconds(300), do: "5 minutes"
  defp sparkline_bucket_for_from_seconds(900), do: "15 minutes"
  defp sparkline_bucket_for_from_seconds(3600), do: "1 hour"
  defp sparkline_bucket_for_from_seconds(21_600), do: "6 hours"
  defp sparkline_bucket_for_from_seconds(_), do: sparkline_bucket_for(@default_time_window)

  defp bucket_interval_literal("1 minute"), do: "'1 minute'::interval"
  defp bucket_interval_literal("5 minutes"), do: "'5 minutes'::interval"
  defp bucket_interval_literal("15 minutes"), do: "'15 minutes'::interval"
  defp bucket_interval_literal("1 hour"), do: "'1 hour'::interval"
  defp bucket_interval_literal("6 hours"), do: "'6 hours'::interval"
  defp bucket_interval_literal(_), do: bucket_interval_literal(sparkline_bucket_for(@default_time_window))

  defp time_window_label("last_1h"), do: "Last hour"
  defp time_window_label("last_6h"), do: "Last 6 hours"
  defp time_window_label("last_24h"), do: "Last 24 hours"
  defp time_window_label("last_7d"), do: "Last 7 days"
  defp time_window_label("last_30d"), do: "Last 30 days"
  defp time_window_label(_), do: time_window_label(@default_time_window)

  defp point_for(value) do
    text = to_string(value || "unknown")
    hash = :erlang.phash2(text, 10_000_000)
    x = rem(hash, 330) - 165
    y = rem(div(hash, 331), 104) - 52
    [x, y]
  end

  defp geo_point(lon, lat) do
    lon = to_float(lon)
    lat = to_float(lat)

    if lon >= -180 and lon <= 180 and lat >= -90 and lat <= 90 and (lon != 0.0 or lat != 0.0) do
      [lon, lat]
    end
  end

  defp geo_label(nil, nil, _ip), do: nil

  defp geo_label(city, country, ip) do
    [city, country, ip]
    |> Enum.filter(&present?/1)
    |> Enum.join(", ")
  end

  defp topology_plane(%{metadata: metadata} = link) when is_map(metadata) do
    Map.get(metadata, "topology_plane") || Map.get(metadata, :topology_plane) || topology_plane_from_evidence(link)
  end

  defp topology_plane(link), do: topology_plane_from_evidence(link)

  defp topology_plane_from_evidence(%{} = link) do
    evidence_class =
      link
      |> map_value_any([:evidence_class, "evidence_class"])
      |> to_string()
      |> String.trim()
      |> String.downcase()

    relation_type =
      link
      |> map_value_any([:relation_type, "relation_type"])
      |> to_string()
      |> String.trim()
      |> String.upcase()

    cond do
      relation_type == "LOGICAL_PEER" or evidence_class == "direct-logical" -> "logical"
      relation_type == "HOSTED_ON" or evidence_class == "hosted-virtual" -> "hosted"
      relation_type in ["ATTACHED_TO", "OBSERVED_TO"] -> "attachment"
      evidence_class in ["endpoint-attachment", "observed-only"] -> "attachment"
      relation_type == "CONNECTS_TO" -> "backbone"
      evidence_class in ["direct", "direct-physical"] -> "backbone"
      true -> "topology"
    end
  end

  defp topology_plane_from_evidence(_), do: "topology"

  defp dashboard_backbone_link?(%{topology_plane: plane}), do: plane in ["backbone", "logical"]
  defp dashboard_backbone_link?(_link), do: false

  defp utilization_pct(_bps, 0), do: 0.0
  defp utilization_pct(bps, capacity_bps), do: Float.round(min(to_int(bps) / capacity_bps * 100, 100.0), 2)

  defp topology_color(%{metadata: metadata}, bps) when is_map(metadata) do
    case Map.get(metadata, "topology_plane") || Map.get(metadata, :topology_plane) do
      "attachment" -> [168, 85, 247, 150]
      "hosted" -> [251, 191, 36, 160]
      "logical" -> [45, 212, 191, 170]
      _ -> if to_int(bps) > 0, do: [56, 189, 248, 190], else: [71, 85, 105, 130]
    end
  end

  defp topology_color(_link, bps), do: if(to_int(bps) > 0, do: [56, 189, 248, 190], else: [71, 85, 105, 130])

  defp map_value_any(%{} = map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_value_any(_map, _keys), do: nil

  defp flow_color(idx, magnitude) do
    opacity = 130 + min(round(:math.log10(max(magnitude, 10)) * 12), 95)

    case rem(idx, 3) do
      0 -> [56, 189, 248, opacity]
      1 -> [45, 212, 191, opacity]
      _ -> [96, 165, 250, opacity]
    end
  end

  defp mtr_color(loss_pct, avg_us) when loss_pct >= 5 or avg_us >= 250_000, do: [248, 113, 113, 210]
  defp mtr_color(loss_pct, avg_us) when loss_pct > 0 or avg_us >= 100_000, do: [251, 191, 36, 210]
  defp mtr_color(_, _), do: [34, 197, 94, 190]

  defp camera_tile(source) do
    %{
      id: source.id,
      label: source.display_name || source.device_uid || "Camera",
      status: source.availability_status || "unknown"
    }
  end

  defp map_empty_title(:configured_empty), do: "Awaiting observed NetFlow summaries"
  defp map_empty_title(:unconfigured), do: "NetFlow collector not configured"
  defp map_empty_title(_), do: "No observed flow data"

  defp map_empty_detail(:configured_empty), do: "Collector configuration exists, but no recent flow summaries were found."
  defp map_empty_detail(:unconfigured), do: "Install a NetFlow, IPFIX, or sFlow collector to animate traffic."
  defp map_empty_detail(_), do: "No synthetic traffic animation is shown."

  defp threat_level(%{pending: pending, escalated: escalated}, %{critical: critical, fatal: fatal, high: high}) do
    cond do
      escalated > 0 or fatal > 0 or critical > 0 -> "High"
      pending > 0 or high > 0 -> "Elevated"
      true -> "Normal"
    end
  end

  defp threat_detail(%{pending: pending, escalated: escalated}, %{critical: critical, fatal: fatal, high: high}) do
    active_alerts = pending + escalated
    severe_events = fatal + critical

    cond do
      escalated > 0 -> "#{format_count(escalated)} escalated alerts"
      severe_events > 0 -> "#{format_count(severe_events)} critical events"
      pending > 0 -> "#{format_count(pending)} pending alerts"
      high > 0 -> "#{format_count(high)} high severity events"
      active_alerts > 0 -> "#{format_count(active_alerts)} active alerts"
      true -> "0 active alerts"
    end
  end

  defp threat_tone(alerts, events) do
    case threat_level(alerts, events) do
      "High" -> "error"
      "Elevated" -> "violet"
      _ -> "success"
    end
  end

  defp network_health_value(%{total: total, availability_pct: availability_pct}, _flows) when total > 0 do
    "#{format_percent(availability_pct)}%"
  end

  defp network_health_value(_services, %{flow_count: flow_count}) when flow_count > 0, do: "Flowing"
  defp network_health_value(_services, _flows), do: "No signal"

  defp network_health_detail(%{total: total, available: available}, _flows) when total > 0 do
    "#{format_count(available)} of #{format_count(total)} services available"
  end

  defp network_health_detail(_services, %{flow_count: flow_count}) when flow_count > 0 do
    "#{format_count(flow_count)} observed flows"
  end

  defp network_health_detail(_services, _flows), do: "No health or flow summaries"

  defp network_health_tone(%{total: total, availability_pct: pct}) when total > 0 and pct < 90, do: "error"
  defp network_health_tone(_), do: "success"

  defp survey_available?(%{sample_count: samples, raster_cell_count: cells}), do: samples > 0 or cells > 0
  defp survey_available?(%{sample_count: samples}), do: samples > 0
  defp survey_available?(_survey), do: false

  defp survey_value(%{sample_count: 0, raster_cell_count: cells}) when cells > 0, do: "Persisted raster"
  defp survey_value(%{sample_count: 0}), do: "No survey"
  defp survey_value(%{session_count: sessions}), do: "#{format_count(sessions)} sessions"

  defp survey_detail(%{sample_count: 0, raster_cell_count: cells}) when cells > 0,
    do: "#{format_count(cells)} backend raster cells"

  defp survey_detail(%{sample_count: 0}), do: "FieldSurvey summary unavailable"

  defp survey_detail(%{sample_count: samples, avg_rssi: rssi}),
    do: "#{format_count(samples)} samples, #{format_float(rssi)} dBm avg"

  defp metric_tone(value, threshold) when value > threshold, do: "error"
  defp metric_tone(_, _), do: "success"

  defp service_health_metric(%{total: total, availability_pct: pct}, _traces) when total > 0, do: format_percent(pct)

  defp service_health_metric(_services, %{total: total, error_rate: error_rate}) when total > 0,
    do: format_percent(100.0 - error_rate)

  defp service_health_metric(_, _), do: "No data"

  defp max_trend_total(points) do
    points
    |> Enum.map(& &1.total)
    |> Enum.max(fn -> 0 end)
  end

  defp average([]), do: 0.0

  defp average(values) do
    numeric = Enum.filter(values, &is_number/1)

    case numeric do
      [] -> 0.0
      _ -> Enum.sum(numeric) / length(numeric)
    end
  end

  defp unwrap_single_map(%{} = map) when map_size(map) == 1 do
    [{_key, value}] = Map.to_list(map)
    if is_map(value), do: value, else: map
  end

  defp unwrap_single_map(map), do: map

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp to_int(value) when is_integer(value), do: max(value, 0)
  defp to_int(value) when is_float(value), do: value |> trunc() |> max(0)
  defp to_int(%Decimal{} = value), do: value |> Decimal.to_integer() |> max(0)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      _ -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp clamp(value, min_value, max_value), do: value |> max(min_value) |> min(max_value)

  defp format_count(value), do: value |> to_int() |> Integer.to_string() |> delimit_integer_string()

  defp format_compact_count(value) do
    count = to_int(value)

    cond do
      count >= 1_000_000 -> "#{format_float(count / 1_000_000)}M"
      count >= 10_000 -> "#{format_float(count / 1_000)}k"
      true -> format_count(count)
    end
  end

  defp delimit_integer_string(value) do
    value
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_percent(value), do: value |> to_float() |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)
  defp format_float(value), do: value |> to_float() |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)

  defp format_rate(value) when value >= 1_000_000_000, do: "#{format_float(value / 1_000_000_000)}G"
  defp format_rate(value) when value >= 1_000_000, do: "#{format_float(value / 1_000_000)}M"
  defp format_rate(value) when value >= 1_000, do: "#{format_float(value / 1_000)}K"
  defp format_rate(value) when value > 0, do: format_float(value)
  defp format_rate(_), do: "No data"

  defp format_bytes(value) when value >= 1_099_511_627_776, do: "#{format_float(value / 1_099_511_627_776)} TiB"
  defp format_bytes(value) when value >= 1_073_741_824, do: "#{format_float(value / 1_073_741_824)} GiB"
  defp format_bytes(value) when value >= 1_048_576, do: "#{format_float(value / 1_048_576)} MiB"
  defp format_bytes(value) when value >= 1024, do: "#{format_float(value / 1024)} KiB"
  defp format_bytes(value) when value > 0, do: "#{value} B"
  defp format_bytes(_), do: "No data"

  defp format_bucket(%DateTime{} = bucket), do: Calendar.strftime(bucket, "%H:%M")
  defp format_bucket(%NaiveDateTime{} = bucket), do: bucket |> DateTime.from_naive!("Etc/UTC") |> format_bucket()
  defp format_bucket(_), do: ""

  defp format_alert_time(%DateTime{} = value), do: Calendar.strftime(value, "%H:%M")
  defp format_alert_time(%NaiveDateTime{} = value), do: value |> DateTime.from_naive!("Etc/UTC") |> format_alert_time()
  defp format_alert_time(_), do: ""

  defp first_present(values) do
    Enum.find_value(values, fn value ->
      if present?(value), do: to_string(value)
    end)
  end

  defp bucket_label(%DateTime{} = bucket), do: DateTime.to_iso8601(bucket)
  defp bucket_label(%NaiveDateTime{} = bucket), do: bucket |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  defp bucket_label(bucket), do: to_string(bucket)

  defp unix_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp unix_ms(%NaiveDateTime{} = value), do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
  defp unix_ms(_), do: 0

  defp default_srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end

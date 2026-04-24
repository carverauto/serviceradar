defmodule ServiceRadarWebNGWeb.DashboardLive.Data do
  @moduledoc false

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
          empty_event_summary()
        ),
      map_stats: map_stats(empty_device_summary(), empty_flow_summary(), empty_mtr_summary(), []),
      map_view: "topology_traffic",
      topology_links: [],
      topology_links_json: "[]",
      traffic_links: [],
      traffic_links_json: "[]",
      mtr_overlays: [],
      mtr_overlays_json: "[]",
      map_empty_title: "Checking traffic sources",
      map_empty_detail: "Dashboard data will load after the LiveView connects.",
      observability_metrics:
        observability_metrics(empty_flow_summary(), empty_mtr_summary(), empty_trace_summary(), empty_services_summary()),
      security_trend: [],
      security_trend_max: 0,
      security_summary: empty_event_summary(),
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
    camera_summary = camera_summary(scope)
    survey_summary = survey_summary(scope)
    alert_summary = Stats.alerts_summary(scope: scope)
    alert_feed = alert_feed(time_window)
    event_summary = Stats.events_summary(time: time_window)
    trace_summary = trace_summary(srql_module, scope, time_window)
    security_trend = security_trend(time_window)

    module_states =
      module_states(
        collector_counts,
        flow_summary,
        traffic_links,
        mtr_summary,
        camera_summary,
        survey_summary,
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
          event_summary
        ),
      map_stats: map_stats(device_summary, flow_summary, mtr_summary, topology_links),
      map_view: "topology_traffic",
      topology_links: topology_links,
      topology_links_json: Jason.encode!(topology_links),
      traffic_links: traffic_links,
      traffic_links_json: Jason.encode!(traffic_links),
      mtr_overlays: mtr_overlays,
      mtr_overlays_json: Jason.encode!(mtr_overlays),
      map_empty_title: map_empty_title(module_states.netflow),
      map_empty_detail: map_empty_detail(module_states.netflow),
      observability_metrics: observability_metrics(flow_summary, mtr_summary, trace_summary, services_summary),
      security_trend: security_trend,
      security_trend_max: max_trend_total(security_trend),
      security_summary: event_summary,
      alert_feed: alert_feed,
      camera_summary: camera_summary,
      survey_summary: survey_summary
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
    cutoff = cutoff_for_time_window(time_window)

    Enum.find_value(
      [
        {"platform.ocsf_network_activity_hourly_conversations", "ocsf_network_activity_hourly_conversations", "bucket"},
        {"platform.ocsf_network_activity", "ocsf_network_activity", "time"}
      ],
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

  defp traffic_links_from_relation(relation, time_column, cutoff) do
    flow_count_expr = flow_count_expr(relation)
    has_geo? = relation_exists?("platform.ip_geo_enrichment_cache")

    geo_select =
      if has_geo? do
        """
          src_geo.latitude AS src_latitude,
          src_geo.longitude AS src_longitude,
          src_geo.city AS src_city,
          src_geo.country_iso2 AS src_country,
          dst_geo.latitude AS dst_latitude,
          dst_geo.longitude AS dst_longitude,
          dst_geo.city AS dst_city,
          dst_geo.country_iso2 AS dst_country
        """
      else
        """
          NULL::float8 AS src_latitude,
          NULL::float8 AS src_longitude,
          NULL::text AS src_city,
          NULL::text AS src_country,
          NULL::float8 AS dst_latitude,
          NULL::float8 AS dst_longitude,
          NULL::text AS dst_city,
          NULL::text AS dst_country
        """
      end

    geo_join =
      if has_geo? do
        """
        LEFT JOIN platform.ip_geo_enrichment_cache src_geo ON src_geo.ip = NULLIF(f.src_endpoint_ip, '')
        LEFT JOIN platform.ip_geo_enrichment_cache dst_geo ON dst_geo.ip = NULLIF(f.dst_endpoint_ip, '')
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
      #{geo_select}
    FROM #{relation} f
    #{geo_join}
    WHERE f.#{time_column} >= $1
      AND f.src_endpoint_ip IS NOT NULL
      AND f.dst_endpoint_ip IS NOT NULL
      AND f.src_endpoint_ip <> f.dst_endpoint_ip
    GROUP BY src, dst, src_latitude, src_longitude, src_city, src_country, dst_latitude, dst_longitude, dst_city, dst_country
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
                          dst_lat,
                          dst_lon,
                          dst_city,
                          dst_country
                        ], idx} ->
          magnitude = to_int(bytes)
          topology_from = point_for(src)
          topology_to = point_for(dst)
          geo_from = geo_point(src_lon, src_lat)
          geo_to = geo_point(dst_lon, dst_lat)

          %{
            id: "flow-#{idx}",
            from: topology_from,
            to: topology_to,
            topology_from: topology_from,
            topology_to: topology_to,
            geo_from: geo_from,
            geo_to: geo_to,
            source_label: src,
            target_label: dst,
            source_geo_label: geo_label(src_city, src_country, src),
            target_geo_label: geo_label(dst_city, dst_country, dst),
            magnitude: magnitude,
            bytes: magnitude,
            packets: to_int(packets),
            flow_count: to_int(flow_count),
            color: flow_color(idx, magnitude)
          }
        end)

      _ ->
        []
    end
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
        RuntimeGraph.refresh_now_sync()
        RuntimeGraph.get_links()

      result ->
        result
    end
  end

  defp normalize_topology_link({%{} = link, idx}) do
    source = link.local_device_id || link.local_device_ip
    target = link.neighbor_device_id || link.neighbor_mgmt_addr || link.neighbor_system_name

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
        source_label: source,
        target_label: target,
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
        interface_pair_key(link.source_label, link.local_if_index),
        interface_pair_key(link.target_label, link.neighbor_if_index)
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
            recording: online,
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

  defp survey_summary(_scope) do
    if relation_exists?("platform.survey_samples") do
      sql = """
      SELECT
        COUNT(*)::bigint AS sample_count,
        COUNT(DISTINCT session_id)::bigint AS session_count,
        COALESCE(AVG(rssi), 0)::float8 AS avg_rssi,
        COUNT(*) FILTER (WHERE is_secure = true)::bigint AS secure_count
      FROM platform.survey_samples
      """

      case Repo.query(sql, []) do
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
    else
      empty_survey_summary()
    end
  rescue
    _ -> empty_survey_summary()
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

  defp module_states(
         collector_counts,
         flow_summary,
         traffic_links,
         mtr_summary,
         camera_summary,
         survey_summary,
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
      fieldsurvey: source_state(false, survey_summary.sample_count > 0),
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

  defp kpi_cards(device, services, flows, camera, survey, alerts, events) do
    [
      %{
        title: "Total Assets",
        value: format_count(device.total),
        detail: "#{format_count(device.available)} available",
        icon: "hero-server-stack",
        tone: "success"
      },
      %{
        title: "Threat Level",
        value: threat_level(alerts, events),
        detail: "#{format_count(alerts.pending + alerts.escalated)} active alerts",
        icon: "hero-shield-exclamation",
        tone: threat_tone(alerts, events)
      },
      %{
        title: "Network Health",
        value: network_health_value(services, flows),
        detail: network_health_detail(services, flows),
        icon: "hero-heart",
        tone: network_health_tone(services)
      },
      %{
        title: "Camera Fleet",
        value: format_count(camera.total),
        detail: "#{format_count(camera.online)} online",
        icon: "hero-video-camera",
        tone: "info"
      },
      %{
        title: "Wi-Fi Coverage",
        value: survey_value(survey),
        detail: survey_detail(survey),
        icon: "hero-wifi",
        tone: "violet"
      }
    ]
  end

  defp map_stats(device, flows, mtr, topology_links) do
    router_capacity = router_backbone_capacity(topology_links)

    [
      %{label: "Total Sites", value: format_count(device.total)},
      %{label: "Active Router Links", value: format_count(router_capacity.active_links)},
      %{label: "Router Utilization", value: "#{format_percent(router_capacity.utilization_pct)}%"},
      %{label: "Traffic", value: format_bytes(flows.bytes_total)},
      %{label: "MTR Paths", value: format_count(mtr.path_count)}
    ]
  end

  defp observability_metrics(flows, mtr, traces, services) do
    [
      %{
        label: "Latency (Avg)",
        value: metric_value(mtr.avg_latency_ms, "No MTR"),
        scale: "ms",
        tone: metric_tone(mtr.avg_latency_ms, 150)
      },
      %{
        label: "Packet Loss",
        value: metric_value(mtr.avg_loss_pct, "No MTR"),
        scale: "%",
        tone: metric_tone(mtr.avg_loss_pct, 1)
      },
      %{label: "Throughput", value: format_rate(flows.bps), scale: "bps", tone: "info"},
      %{
        label: "Service Health",
        value: service_health_metric(services, traces),
        scale: "%",
        tone: network_health_tone(services)
      }
    ]
  end

  defp empty_device_summary, do: %{total: 0, available: 0, unavailable: 0}
  defp empty_services_summary, do: %{total: 0, available: 0, unavailable: 0, availability_pct: 0.0}
  defp empty_flow_summary, do: %{bytes_total: 0, packets_total: 0, flow_count: 0, bps: 0.0, pps: 0.0, link_count: 0}
  defp empty_mtr_summary, do: %{path_count: 0, avg_loss_pct: 0.0, avg_latency_ms: 0.0, degraded_count: 0}
  defp empty_camera_summary, do: %{total: 0, online: 0, offline: 0, recording: 0, tiles: []}
  defp empty_survey_summary, do: %{sample_count: 0, session_count: 0, avg_rssi: 0.0, secure_count: 0}
  defp empty_alert_summary, do: Stats.empty_alerts_summary()
  defp empty_event_summary, do: Stats.empty_events_summary()

  defp empty_trace_summary,
    do: %{total: 0, errors: 0, avg_duration_ms: 0.0, p95_duration_ms: 0.0, error_rate: 0.0, successful: 0}

  defp relation_exists?(relation_name) do
    case Repo.query("SELECT to_regclass($1) IS NOT NULL", [relation_name]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp flow_count_expr("ocsf_network_activity"), do: "COUNT(*)"
  defp flow_count_expr(_relation), do: "SUM(flow_count)"

  defp cutoff_for_time_window("last_1h"), do: DateTime.add(DateTime.utc_now(), -1, :hour)
  defp cutoff_for_time_window("last_6h"), do: DateTime.add(DateTime.utc_now(), -6, :hour)
  defp cutoff_for_time_window("last_24h"), do: DateTime.add(DateTime.utc_now(), -24, :hour)
  defp cutoff_for_time_window("last_7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp cutoff_for_time_window("last_30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp cutoff_for_time_window(_), do: cutoff_for_time_window(@default_time_window)

  defp sparkline_bucket_for("last_1h"), do: "1 minute"
  defp sparkline_bucket_for("last_6h"), do: "5 minutes"
  defp sparkline_bucket_for("last_24h"), do: "15 minutes"
  defp sparkline_bucket_for("last_7d"), do: "1 hour"
  defp sparkline_bucket_for("last_30d"), do: "6 hours"
  defp sparkline_bucket_for(_), do: sparkline_bucket_for(@default_time_window)

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

  defp router_backbone_capacity(links) when is_list(links) do
    active_links =
      Enum.filter(links, fn link -> to_int(Map.get(link, :flow_bps)) > 0 end)

    capacity_links =
      Enum.filter(active_links, fn link -> to_int(Map.get(link, :capacity_bps)) > 0 end)

    capacity_bps = Enum.reduce(capacity_links, 0, &(to_int(Map.get(&1, :capacity_bps)) + &2))
    usage_bps = Enum.reduce(active_links, 0, &(to_int(Map.get(&1, :flow_bps)) + &2))
    usage_with_capacity_bps = Enum.reduce(capacity_links, 0, &(to_int(Map.get(&1, :flow_bps)) + &2))

    %{
      active_links: length(active_links),
      capacity_bps: capacity_bps,
      usage_bps: usage_bps,
      utilization_pct: utilization_pct(usage_with_capacity_bps, capacity_bps)
    }
  end

  defp router_backbone_capacity(_links), do: %{active_links: 0, capacity_bps: 0, usage_bps: 0, utilization_pct: 0.0}

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

    case rem(idx, 4) do
      0 -> [56, 189, 248, opacity]
      1 -> [45, 212, 191, opacity]
      2 -> [34, 197, 94, opacity]
      _ -> [168, 85, 247, opacity]
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

  defp survey_value(%{sample_count: 0}), do: "No survey"
  defp survey_value(%{session_count: sessions}), do: "#{format_count(sessions)} sessions"

  defp survey_detail(%{sample_count: 0}), do: "FieldSurvey summary unavailable"

  defp survey_detail(%{sample_count: samples, avg_rssi: rssi}),
    do: "#{format_count(samples)} samples, #{format_float(rssi)} dBm avg"

  defp metric_value(value, fallback) when value == 0, do: fallback
  defp metric_value(value, _fallback), do: format_float(value)

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

  defp format_count(value), do: value |> to_int() |> Integer.to_string()
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

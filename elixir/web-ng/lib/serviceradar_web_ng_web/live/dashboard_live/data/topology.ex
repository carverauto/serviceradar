# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.Topology do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp topology_links(time_window) do
        case runtime_graph_links() do
          {:ok, links} when is_list(links) ->
            links
            |> Enum.with_index()
            |> Enum.map(&normalize_topology_link/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.filter(&dashboard_backbone_link?/1)
            |> Enum.take(160)
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
        case ServiceRadarWebNG.Topology.RuntimeGraph.get_links() do
          {:ok, []} ->
            ServiceRadarWebNG.Topology.RuntimeGraph.refresh_now()
            {:ok, []}

          result ->
            result
        end
      end

      defp normalize_topology_link({%{} = link, idx}) do
        source = link.local_device_id || link.local_device_ip
        target = link.neighbor_device_id || link.neighbor_mgmt_addr || link.neighbor_system_name
        source_label = topology_endpoint_label(link.local_device_id, link.local_device_ip, nil)

        target_label =
          topology_endpoint_label(link.neighbor_device_id, link.neighbor_mgmt_addr, link.neighbor_system_name)

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
            |> Enum.take(80)

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

      @sobelow_skip ["SQL.Query"]
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

        case ServiceRadarWebNG.Repo.query(sql, [
               cutoff,
               device_ids,
               if_indexes,
               ~w(ifHCInOctets ifHCOutOctets ifInOctets ifOutOctets)
             ]) do
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
    end
  end
end

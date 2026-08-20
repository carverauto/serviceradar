# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.MapHelpers do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
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

      defp geo_point_or_country(lon, lat, country_code) do
        geo_point(lon, lat) || ServiceRadar.Observability.CountryCentroids.point(country_code)
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
          "logical" -> [62, 207, 135, 170]
          # brand green when active (was sky cyan)
          _ -> if to_int(bps) > 0, do: [62, 207, 135, 190], else: [107, 127, 120, 130]
        end
      end

      defp topology_color(_link, bps), do: if(to_int(bps) > 0, do: [62, 207, 135, 190], else: [107, 127, 120, 130])

      defp map_value_any(%{} = map, keys) when is_list(keys) do
        Enum.find_value(keys, fn key -> Map.get(map, key) end)
      end

      defp flow_color(idx, magnitude) do
        opacity = 130 + min(round(:math.log10(max(magnitude, 10)) * 12), 95)

        # Brand greens only (no sky/cyan)
        case rem(idx, 3) do
          0 -> [62, 207, 135, opacity]
          1 -> [91, 222, 155, opacity]
          _ -> [52, 180, 140, opacity]
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

      defp map_empty_title(:loading), do: "Checking traffic sources"
      defp map_empty_title(:configured_empty), do: "Awaiting observed NetFlow summaries"
      defp map_empty_title(:unconfigured), do: "NetFlow collector not configured"
      defp map_empty_title(_), do: "No observed flow data"

      defp map_empty_detail(:loading), do: "Dashboard data will load after the LiveView connects."

      defp map_empty_detail(:configured_empty),
        do: "Collector configuration exists, but no recent flow summaries were found."

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

      defp survey_value(%{sample_count: 0, raster_cell_count: cells}) when cells > 0, do: "Persisted raster"
      defp survey_value(%{sample_count: 0}), do: "No survey"
      defp survey_value(%{session_count: sessions}), do: "#{format_count(sessions)} sessions"

      defp survey_detail(%{sample_count: 0, raster_cell_count: cells}) when cells > 0,
        do: "#{format_count(cells)} backend raster cells"

      defp survey_detail(%{sample_count: samples, avg_rssi: rssi}),
        do: "#{format_count(samples)} samples, #{format_float(rssi)} dBm avg"

      defp metric_tone(value, threshold) when value > threshold, do: "error"
      defp metric_tone(_, _), do: "success"
    end
  end
end

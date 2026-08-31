# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.StatesCards do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
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
          fieldsurvey: source_state(false, survey_available?(survey_summary)),
          security_events: source_state(false, event_summary.total > 0),
          siem: source_state(false, alert_summary.total > 0)
        }
      end

      defp netflow_source_state(collector_counts, flow_summary, traffic_links) do
        netflow_configured? = Map.get(collector_counts, "netflow", 0) > 0 or Map.get(collector_counts, "sflow", 0) > 0
        flow_active? = flow_summary.flow_count > 0 or traffic_links != []

        source_state(netflow_configured?, flow_active?)
      end

      defp source_state(_configured?, true), do: :active
      defp source_state(true, false), do: :configured_empty
      defp source_state(false, false), do: :unconfigured

      defp enabled_modules(states) do
        states
        |> Enum.filter(fn {_key, state} -> state in [:active, :configured_empty] end)
        |> Enum.map(&elem(&1, 0))
      end

      defp apply_kpi_loading(cards, loading) when is_map(loading) do
        Enum.map(cards, fn card ->
          Map.put(card, :loading, kpi_title_loading?(card.title, loading))
        end)
      end

      defp apply_kpi_loading(cards, _loading), do: Enum.map(List.wrap(cards), &Map.put(&1, :loading, false))

      defp kpi_title_loading?("Total Assets", loading), do: Map.get(loading, :assets, false)
      defp kpi_title_loading?("Threat Level", loading), do: Map.get(loading, :threat, false)
      defp kpi_title_loading?("Network Health", loading), do: Map.get(loading, :network_health, false)
      defp kpi_title_loading?("Camera Fleet", loading), do: Map.get(loading, :camera, false)
      defp kpi_title_loading?("Wi-Fi Coverage", loading), do: Map.get(loading, :survey, false)
      defp kpi_title_loading?("Active Alerts", loading), do: Map.get(loading, :alerts, false)
      defp kpi_title_loading?("Recent Events", loading), do: Map.get(loading, :events, false)
      defp kpi_title_loading?(_title, _loading), do: false

      defp default_kpi_loading do
        %{
          assets: true,
          threat: true,
          network_health: true,
          camera: true,
          survey: true,
          alerts: true,
          events: true
        }
      end

      defp loaded_kpi_loading do
        Map.new(default_kpi_loading(), fn {key, _value} -> {key, false} end)
      end

      defp kpi_cards(device, services, flows, camera, survey, alerts, events, sparklines) do
        [
          %{
            title: "Total Assets",
            value: format_compact_count(device.total),
            detail: "#{format_count(device.available)} available",
            icon: "hero-server-stack",
            tone: "success",
            sparkline: Map.get(sparklines, :assets, []),
            href: "/devices",
            aria_label: "Open total assets"
          },
          %{
            title: "Threat Level",
            value: threat_level(alerts, events),
            detail: threat_detail(alerts, events),
            icon: "hero-shield-exclamation",
            tone: threat_tone(alerts, events),
            sparkline: Map.get(sparklines, :threats, []),
            href: "/observability/events",
            aria_label: "Open security events"
          },
          %{
            title: "Network Health",
            value: network_health_value(services, flows),
            detail: network_health_detail(services, flows),
            icon: "hero-heart",
            tone: network_health_tone(services),
            sparkline: Map.get(sparklines, :network_health, []),
            href: "/services",
            aria_label: "Open service health"
          },
          %{
            title: "Camera Fleet",
            value: format_compact_count(camera.total),
            detail: "#{format_count(camera.online)} available",
            icon: "hero-video-camera",
            tone: "info",
            sparkline: Map.get(sparklines, :camera, []),
            href: "/cameras",
            aria_label: "Open camera fleet"
          },
          survey_kpi_card(survey, Map.get(sparklines, :survey, [])),
          %{
            title: "Active Alerts",
            value: format_compact_count(active_alert_count(alerts)),
            detail: "#{format_count(alerts.total)} total alerts",
            icon: "hero-bell-alert",
            tone: if(active_alert_count(alerts) > 0, do: "error", else: "success"),
            sparkline: Map.get(sparklines, :threats, []),
            href: "/observability/alerts",
            aria_label: "Open active alerts"
          },
          %{
            title: "Recent Events",
            value: format_compact_count(events.total),
            detail: "#{format_count(priority_event_count(events))} high priority",
            icon: "hero-document-text",
            tone: if(priority_event_count(events) > 0, do: "error", else: "info"),
            sparkline: Map.get(sparklines, :threats, []),
            href: "/observability/events",
            aria_label: "Open recent events"
          }
        ]
      end

      defp active_alert_count(alerts), do: to_int(alerts.pending) + to_int(alerts.escalated)

      defp priority_event_count(events) do
        to_int(events.fatal) + to_int(events.critical) + to_int(events.high)
      end

      defp map_stats(_flows, _mtr, traffic_links) do
        link_count = length(List.wrap(traffic_links))
        window_bytes = traffic_links |> Enum.map(&to_int(Map.get(&1, :bytes, Map.get(&1, "bytes", 0)))) |> Enum.sum()

        window_flows =
          traffic_links |> Enum.map(&to_int(Map.get(&1, :flow_count, Map.get(&1, "flow_count", 0)))) |> Enum.sum()

        geo_mapped = Enum.count(traffic_links, &Map.get(&1, :geo_mapped, Map.get(&1, "geo_mapped", false)))
        geo_pct = if link_count > 0, do: geo_mapped * 100 / link_count, else: 0

        [
          %{
            label: "Window",
            value: netflow_map_window_label(),
            href: netflow_observability_path("traffic"),
            aria_label: "Open NetFlow traffic window"
          },
          %{
            label: "Conversations",
            value: format_count(link_count),
            href: netflow_observability_path("topology", %{"graph" => "sankey"}),
            aria_label: "Open NetFlow conversations"
          },
          %{
            label: "Flow Records",
            value: format_count(window_flows),
            href: netflow_observability_path("explorer"),
            aria_label: "Open NetFlow flow records"
          },
          %{
            label: "Traffic",
            value: format_bytes(window_bytes),
            href: netflow_observability_path("traffic"),
            aria_label: "Open NetFlow traffic analytics"
          },
          %{
            label: "Geo Mapped",
            value: "#{format_percent(geo_pct)}%",
            href: netflow_observability_path("topology", %{"geo" => "dst"}),
            aria_label: "Open geo-mapped NetFlow analytics"
          }
        ]
      end

      defp netflow_observability_path(view, extra_params \\ %{}) do
        params =
          Map.merge(
            %{"view" => view, "q" => "in:flows time:last_15m sort:timestamp:desc limit:100"},
            extra_params
          )

        ServiceRadarWebNGWeb.ObservabilityPaths.path("netflows", params)
      end

      defp observability_metrics(flows, mtr, traces, services, sparklines) do
        latency_available? = to_int(Map.get(mtr, :latency_sample_count, 0)) > 0
        loss_available? = to_int(Map.get(mtr, :loss_sample_count, 0)) > 0
        flows_available? = to_int(flows.flow_count) > 0 or to_int(flows.bytes_total) > 0
        service_available? = to_int(services.total) > 0 or to_int(traces.total) > 0

        [
          %{
            label: "Destination Latency",
            value: if(latency_available?, do: format_float(mtr.avg_latency_ms), else: "No endpoint sample"),
            scale: if(latency_available?, do: "ms", else: ""),
            available: latency_available?,
            tone: metric_tone(mtr.avg_latency_ms, 150),
            sparkline: Map.get(sparklines, :latency, []),
            axis_min: if(latency_available?, do: "0", else: ""),
            axis_mid: if(latency_available?, do: "75", else: ""),
            axis_max: if(latency_available?, do: "150", else: ""),
            href: "/diagnostics/mtr",
            aria_label: "Open MTR destination latency diagnostics"
          },
          %{
            label: "Destination Loss",
            value: if(loss_available?, do: format_float(mtr.avg_loss_pct), else: "No endpoint sample"),
            scale: if(loss_available?, do: "%", else: ""),
            available: loss_available?,
            tone: metric_tone(mtr.avg_loss_pct, 1),
            sparkline: Map.get(sparklines, :packet_loss, []),
            axis_min: if(loss_available?, do: "0%", else: ""),
            axis_mid:
              if(loss_available?,
                do: packet_loss_axis_mid(Map.get(sparklines, :packet_loss, []), mtr.avg_loss_pct),
                else: ""
              ),
            axis_max:
              if(loss_available?,
                do: packet_loss_axis_max(Map.get(sparklines, :packet_loss, []), mtr.avg_loss_pct),
                else: ""
              ),
            href: "/diagnostics/mtr",
            aria_label: "Open MTR destination loss diagnostics"
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
            axis_max: "10G",
            href: netflow_observability_path("traffic"),
            aria_label: "Open throughput flow analytics"
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
            axis_max: "100%",
            href: "/services",
            aria_label: "Open service health metrics"
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
    end
  end
end

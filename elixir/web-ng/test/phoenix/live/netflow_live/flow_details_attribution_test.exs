defmodule ServiceRadarWebNGWeb.NetflowLive.FlowDetailsAttributionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Components.ServicePicker
  alias ServiceRadarWebNGWeb.LogLive.Index, as: LogLiveIndex
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsTable

  @moduletag :db_free

  test "observability netflows flow details modal renders StarRocks top-level process attribution" do
    flow = attributed_starrocks_flow_row()

    html = render_component(&LogLiveIndex.render/1, log_live_netflows_assigns(flow))

    assert html =~ "Flow details"
    assert html =~ "Process attribution"
    assert html =~ "attributed"
    assert html =~ "envoy #42420"
    assert html =~ "agent-alpha-01"
    assert html =~ "lab-partition-a"
    assert html =~ "1001"
    assert html =~ "containerd://0123456789abcdef"
    assert html =~ "edge-ingress/gateway-proxy-7c8d9"
    assert html =~ "/usr/local/bin/envoy --config-path /etc/envoy/envoy.yaml"
    assert html =~ "edge-ingress/gateway-public"
    assert html =~ "gateway public-gw"
    assert html =~ "load_balancer"
    assert html =~ "HTTPRoute/https-ingress"
    assert html =~ "203.0.113.10:8443"
    assert html =~ "/observability/flows/attributed?"
    refute html =~ "No process context is attached to this flow row."
  end

  test "observability netflows flow details modal decodes JSON string workload and public endpoint columns" do
    flow =
      Map.merge(attributed_starrocks_flow_row(), %{
        "workload_identity" =>
          Jason.encode!(%{
            "namespace" => "edge-system",
            "workload_kind" => "DaemonSet",
            "workload_name" => "flow-collector",
            "node_hostname" => "node-alpha.example.com"
          }),
        "public_endpoint" =>
          Jason.encode!(%{
            "service_name" => "collector-ingest",
            "namespace" => "edge-system",
            "exposure_class" => "node_port",
            "external_ip" => "203.0.113.20",
            "external_port" => 30_443
          })
      })

    html = render_component(&LogLiveIndex.render/1, log_live_netflows_assigns(flow))

    assert html =~ "edge-system/DaemonSet/flow-collector @ node-alpha.example.com"
    assert html =~ "edge-system/collector-ingest"
    assert html =~ "node_port"
    assert html =~ "203.0.113.20:30443"
  end

  test "observability netflows flow details modal renders no match for unattributed StarRocks flow rows" do
    flow = unattributed_starrocks_flow_row()

    html = render_component(&LogLiveIndex.render/1, log_live_netflows_assigns(flow))

    assert html =~ "Flow details"
    assert html =~ "Process attribution"
    assert html =~ "no match"
    assert html =~ "No process context is attached to this flow row."
    refute html =~ "envoy #42420"
  end

  test "visualize flow modal and flows table read StarRocks top-level attribution columns" do
    flow = attributed_starrocks_flow_row()

    attribution = FlowAccess.flow_attribution(flow)
    assert attribution.attributed? == true
    assert attribution.process_label == "envoy #42420"
    assert attribution.agent_id == "agent-alpha-01"
    assert attribution.uid == "1001"
    assert attribution.container_id == "containerd://0123456789abcdef"
    assert attribution.cmdline == "/usr/local/bin/envoy --config-path /etc/envoy/envoy.yaml"

    modal_html =
      render_component(&FlowModal.render/1, %{
        flow: flow,
        rdns_map: %{},
        context: %{},
        arin_lookup: nil,
        timezone: "Etc/UTC"
      })

    assert modal_html =~ "Attributed"
    assert modal_html =~ "envoy #42420"
    assert modal_html =~ "agent-alpha-01"
    assert modal_html =~ "1001"
    assert modal_html =~ "containerd://0123456789abcdef"
    assert modal_html =~ "/usr/local/bin/envoy --config-path /etc/envoy/envoy.yaml"

    table_html =
      render_component(&FlowsTable.render/1, %{
        flows: [flow],
        rdns_map: %{},
        geo_iso2_map: %{},
        base_path: "/observability/netflows",
        query: "in:flows time:last_1h",
        limit: 50,
        nf_param: nil,
        unit_mode: "Bps",
        timezone: "Etc/UTC"
      })

    assert table_html =~ "Attributed"
    assert table_html =~ "envoy #42420"
  end

  defp attributed_starrocks_flow_row do
    %{
      "time" => "2026-08-30T18:00:00Z",
      "src_endpoint_ip" => "192.0.2.25",
      "src_endpoint_port" => 51_234,
      "dst_endpoint_ip" => "198.51.100.42",
      "dst_endpoint_port" => 443,
      "protocol_num" => 6,
      "protocol_name" => "TCP",
      "protocol_group" => "TCP",
      "tcp_flags" => 18,
      "tcp_flags_labels" => ["SYN", "ACK"],
      "packets_total" => 24,
      "bytes_total" => 8_192,
      "direction_label" => "egress",
      "dst_service_label" => "HTTPS",
      "src_hosting_provider" => "ExampleNet Corp",
      "dst_hosting_provider" => "TargetHost Example",
      "src_prefix_tags" => ["netbox:tag:edge"],
      "dst_prefix_tags" => ["netbox:tag:upstream"],
      "sampler_address" => "192.0.2.1",
      "flow_source" => "IPFIX",
      "partition" => "lab-partition-a",
      "agent_id" => "agent-alpha-01",
      "pid" => 42_420,
      "uid" => 1001,
      "comm" => "envoy",
      "cmdline" => "/usr/local/bin/envoy --config-path /etc/envoy/envoy.yaml",
      "container_id" => "containerd://0123456789abcdef",
      "workload_identity" => %{
        "pod_namespace" => "edge-ingress",
        "pod_name" => "gateway-proxy-7c8d9",
        "container_name" => "envoy",
        "context_name" => "cluster-example-a"
      },
      "public_endpoint" => %{
        "service_name" => "gateway-public",
        "namespace" => "edge-ingress",
        "gateway_name" => "public-gw",
        "exposure_class" => "load_balancer",
        "route_kind" => "HTTPRoute",
        "route_name" => "https-ingress",
        "external_ip" => "203.0.113.10",
        "external_port" => 8443
      },
      "attribution_status" => "attributed"
    }
  end

  defp unattributed_starrocks_flow_row do
    %{
      "time" => "2026-08-30T18:05:00Z",
      "src_endpoint_ip" => "192.0.2.30",
      "src_endpoint_port" => 54_321,
      "dst_endpoint_ip" => "198.51.100.99",
      "dst_endpoint_port" => 443,
      "protocol_num" => 6,
      "protocol_name" => "TCP",
      "protocol_group" => "TCP",
      "packets_total" => 4,
      "bytes_total" => 512,
      "direction_label" => "egress",
      "dst_service_label" => "HTTPS",
      "partition" => "default",
      "agent_id" => nil,
      "pid" => nil,
      "uid" => nil,
      "comm" => nil,
      "cmdline" => nil,
      "container_id" => nil,
      "workload_identity" => nil,
      "public_endpoint" => nil,
      "attribution_status" => "unmatched"
    }
  end

  defp scope do
    Scope.for_user(%{
      id: "00000000-0000-0000-0000-000000000001",
      email: "operator@example.com",
      role: :admin,
      timezone: "Etc/UTC"
    })
  end

  defp log_live_netflows_assigns(selected_netflow) do
    %{
      flash: %{},
      current_scope: scope(),
      active_tab: "netflows",
      alert_evaluation_mode: :active,
      tab_loading: false,
      logs: [],
      traces: [],
      metrics: [],
      events: [],
      alerts: [],
      netflows: [selected_netflow],
      alert_selection: MapSet.new(),
      alert_bulk_result: nil,
      alert_bulk_duration: "1h",
      can_manage_alerts?: false,
      alert_summary: %{
        total: 0,
        pending: 0,
        acknowledged: 0,
        resolved: 0,
        escalated: 0,
        suppressed: 0
      },
      summary: %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0},
      event_summary: %{total: 0, critical: 0, high: 0, medium: 0, low: 0, time: "last_24h"},
      netflow_summary: %{
        total: 1,
        tcp: 1,
        udp: 0,
        other: 0,
        total_bytes: 8_192,
        total_packets: 24,
        avg_bps: 0.0,
        avg_pps: 0.0,
        window_seconds: 3600
      },
      trace_stats: %{total: 0, error_traces: 0, slow_traces: 0},
      trace_latency: %{
        avg_duration_ms: 0.0,
        p95_duration_ms: 0.0,
        service_count: 0,
        sample_size: 0
      },
      metrics_stats: %{total: 0, slow: 0, error: 0, ok: 0},
      metrics_view: "samples",
      otlp_metric_names: [],
      otlp_selected_metric: nil,
      otlp_metric_series: [],
      logs_live?: false,
      netflows_live?: false,
      events_live?: false,
      traces_live?: false,
      metrics_live?: false,
      alerts_live?: false,
      logs_rollup_status: %{available?: true},
      trace_rollup_status: %{available?: true},
      service_stats_scope: nil,
      service_filter_notice?: false,
      service_filter_allowed?: false,
      service_picker: ServicePicker.initial_state(),
      selected_netflow: selected_netflow,
      netflow_context: %{},
      netflow_arin_lookup: %{},
      netflow_top_talkers: [],
      netflow_top_ports: [],
      netflow_timeseries: %{bucket_seconds: 300, points: []},
      netflow_timeseries_compare: %{bucket_seconds: 300, points: []},
      netflow_timeseries_stacked: %{bucket_seconds: 300, keys: [], points: []},
      netflow_protocol_activity: %{bucket_seconds: 300, keys: [], points: [], colors: %{}},
      netflow_app_activity: %{bucket_seconds: 300, keys: [], points: [], colors: %{}},
      netflow_frequent_talkers_packets: [],
      netflow_frequent_talkers_bytes: [],
      netflow_rdns_map: %{},
      netflow_threat_map: %{},
      netflow_compact?: false,
      netflow_talker_cidr: nil,
      netflow_compare_mode: "off",
      netflow_geo_side: "dst",
      netflow_geo_heatmap: [],
      netflow_sankey_prefix: 24,
      netflow_sankey: %{edges: [], sources: [], mids: [], dests: []},
      netflow_sankey_edges_json: "[]",
      netflow_stack_mode: "ports",
      netflow_graph_mode: "stacked",
      netflow_view: "explorer",
      limit: 50,
      pagination: %{},
      streams: %{logs: [], events: []},
      srql: %{
        enabled: true,
        page_path: "/observability/netflows",
        query: "in:flows time:last_1h sort:time:desc",
        pagination: %{}
      }
    }
  end
end

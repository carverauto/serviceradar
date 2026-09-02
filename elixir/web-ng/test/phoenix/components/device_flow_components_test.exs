defmodule ServiceRadarWebNGWeb.Components.DeviceFlowComponentsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.FlowComponents

  @moduletag :unit
  @moduletag :db_free

  setup_all do
    case start_supervised(ServiceRadarWebNGWeb.Endpoint) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "renders the flow tab table and controls through extracted components" do
    html = render_component(&FlowComponents.flows_tab_content/1, assigns())
    document = LazyHTML.from_fragment(html)

    assert html =~ "Recent Flows"
    assert html =~ "192.0.2.10:51514"
    assert html =~ "198.51.100.20:443"
    assert html =~ "TCP"
    assert html =~ "uplink0"
    assert html =~ "wan0"
    assert html =~ "Open full flows view"
    assert html =~ "Top Peers"
    assert html =~ "Protocol"

    row_time = LazyHTML.query(document, "#device-flow-row-time-0")
    assert LazyHTML.tag(row_time) == ["time"]
    assert LazyHTML.attribute(row_time, "datetime") == ["2026-06-21T18:30:00Z"]
    assert LazyHTML.attribute(row_time, "data-user-time-zone") == ["America/Chicago"]
    assert LazyHTML.attribute(row_time, "data-user-time-style") == ["compact"]
  end

  test "protocol breakdown fills the fourth slot of the top-n grid" do
    html =
      render_component(
        &FlowComponents.flows_tab_content/1,
        assigns(
          proto_json:
            Jason.encode!([
              %{"label" => "TCP", "value" => 50},
              %{"label" => "UDP", "value" => 20}
            ]),
          top_ports_json: Jason.encode!([%{"label" => "443", "value" => 32_768}]),
          top_protocols_json: Jason.encode!([%{"label" => "TCP", "value" => 50_000}])
        )
      )

    grid_html =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[class*='md:grid-cols-2 lg:grid-cols-4']")
      |> LazyHTML.to_html()

    assert grid_html =~ "Top Peers"
    assert grid_html =~ "Top Ports"
    assert grid_html =~ "Top Protocols"
    assert grid_html =~ "Protocol Breakdown"
    assert grid_html =~ "device-proto-donut"
  end

  test "passes the authenticated display zone to the traffic profile without changing points" do
    points =
      Jason.encode!([
        %{"t" => "2026-06-21T18:30:00Z", "tcp" => 65_536},
        %{"t" => "2026-06-21T18:35:00Z", "tcp" => 32_768}
      ])

    html =
      render_component(
        &FlowComponents.flows_tab_content/1,
        assigns(
          flow_chart_keys_json: Jason.encode!(["tcp"]),
          flow_chart_points_json: points,
          timezone: "America/Chicago"
        )
      )

    chart = LazyHTML.query(LazyHTML.from_fragment(html), "#device-flow-traffic-profile")

    assert LazyHTML.attribute(chart, "phx-hook") == ["NetflowStackedAreaChart"]
    assert LazyHTML.attribute(chart, "data-timezone") == ["America/Chicago"]
    assert LazyHTML.attribute(chart, "data-points") == [points]
    assert LazyHTML.attribute(chart, "data-zoomable") == ["true"]
  end

  test "renders zoom endpoints semantically while retaining their canonical source values" do
    start_time = "2026-06-21T18:30:00.123456Z"
    end_time = "2026-06-21T19:00:00.999999Z"

    html =
      render_component(
        &FlowComponents.flows_tab_content/1,
        assigns(zoom_range: %{start: start_time, end: end_time})
      )

    document = LazyHTML.from_fragment(html)

    for {id, instant} <- [
          {"device-flow-zoom-start", start_time},
          {"device-flow-zoom-end", end_time}
        ] do
      time = LazyHTML.query(document, "##{id}")
      assert LazyHTML.tag(time) == ["time"]
      assert LazyHTML.attribute(time, "datetime") == [instant]
      assert LazyHTML.attribute(time, "data-user-time-iso") == [instant]
      assert LazyHTML.attribute(time, "data-user-time-zone") == ["America/Chicago"]
      assert LazyHTML.attribute(time, "data-user-time-style") == ["compact"]
    end
  end

  defp assigns(overrides \\ []) do
    overrides = Map.new(overrides)

    Map.merge(base_assigns(), overrides)
  end

  defp base_assigns do
    %{
      flows: [
        %{
          "time" => "2026-06-21T18:30:00Z",
          "src_endpoint_ip" => "192.0.2.10",
          "src_endpoint_port" => 51_514,
          "dst_endpoint_ip" => "198.51.100.20",
          "dst_endpoint_port" => 443,
          "protocol_num" => 6,
          "protocol_name" => "tcp",
          "packets_total" => 42,
          "bytes_total" => 65_536,
          "in_if_name" => "uplink0",
          "out_if_name" => "wan0",
          "dst_service_label" => "https",
          "ocsf_payload" => %{
            "connection_info" => %{
              "input_snmp" => 10,
              "output_snmp" => 20
            }
          }
        }
      ],
      error: nil,
      pagination: %{},
      rdns_map: %{},
      geo_iso2_map: %{},
      device_uid: "device-1",
      query: "in:flows device:device-1",
      limit: 25,
      flow_stats: %{total_bytes: 65_536, total_packets: 42, flow_count: 1, unique_talkers: 1},
      flow_stats_loading: false,
      sparkline_json: "[]",
      proto_json: "[]",
      flow_chart_keys_json: "[]",
      flow_chart_points_json: "[]",
      top_peers_json: Jason.encode!([%{"label" => "198.51.100.20", "value" => 65_536}]),
      top_ports_json: "[]",
      top_protocols_json: "[]",
      facets: %{
        protocols: [%{label: "TCP", filter_value: "6"}],
        directions: [],
        services: []
      },
      active_facets: %{},
      active_topn: nil,
      zoom_range: nil,
      timezone: "America/Chicago"
    }
  end
end

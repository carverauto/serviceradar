defmodule ServiceRadarWebNGWeb.NetflowLive.TimestampRenderingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Traffic
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsTable

  @moduletag :db_free

  test "flow rows use stable semantic timestamps in the saved timezone" do
    html =
      render_component(&FlowsTable.render/1, %{
        flows: [flow("flow-a", "2026-08-30T18:00:00Z"), flow("flow-b", "2026-08-30T19:00:00Z")],
        rdns_map: %{},
        geo_iso2_map: %{},
        base_path: "/observability/flows",
        query: "in:flows time:last_1h",
        limit: 50,
        nf_param: nil,
        unit_mode: "Bps",
        timezone: "America/Chicago"
      })

    times = html |> LazyHTML.from_fragment() |> LazyHTML.query("time[phx-hook=UserTime]")
    ids = LazyHTML.attribute(times, "id")

    assert ids == ["netflow-row-time-flow-a", "netflow-row-time-flow-b"]
    assert Enum.all?(ids, &(&1 != ""))
    assert length(Enum.uniq(ids)) == 2

    assert LazyHTML.attribute(times, "datetime") == [
             "2026-08-30T18:00:00Z",
             "2026-08-30T19:00:00Z"
           ]

    assert LazyHTML.attribute(times, "data-user-time-zone") == [
             "America/Chicago",
             "America/Chicago"
           ]

    assert LazyHTML.attribute(times, "data-user-time-style") == ["time", "time"]
  end

  test "flow detail uses the same semantic presentation boundary" do
    html =
      render_component(&FlowModal.render/1, %{
        flow: flow("flow-a", "2026-08-30T18:00:00Z"),
        rdns_map: %{},
        context: %{},
        arin_lookup: nil,
        timezone: "America/Chicago"
      })

    time = html |> LazyHTML.from_fragment() |> LazyHTML.query("#netflow-flow-detail-time")

    assert LazyHTML.attribute(time, "datetime") == ["2026-08-30T18:00:00Z"]
    assert LazyHTML.attribute(time, "data-user-time-zone") == ["America/Chicago"]
  end

  test "absolute windows return canonical endpoints while relative windows stay labels" do
    query = "in:flows time:[2026-08-30T18:00:00Z,2026-08-30T19:00:00Z]"

    assert %{
             type: :absolute,
             start: ~U[2026-08-30 18:00:00Z],
             end: ~U[2026-08-30 19:00:00Z]
           } = TimeWindow.display_window_from_query(query, "last_1h")

    assert %{type: :relative, label: "Last 1h"} =
             TimeWindow.display_window_from_query("in:flows time:last_1h", "last_1h")

    assert %{type: :relative, label: "Last 6h"} =
             TimeWindow.display_window_from_query("in:flows time:last_6h", "last_1h")
  end

  test "dashboard traffic chart roots carry the saved timezone" do
    html =
      render_component(&Traffic.render/1, %{
        dashboard: %{
          timezone: "America/Chicago",
          section: "traffic",
          top_interfaces: [%{key: "edge-1:2", label: "eth0", sampler: "edge-1", if_index: 2}],
          selected_interface: "edge-1:2",
          iface_chart_points_json: ~s|[{"t":"2026-08-30T18:00:00Z","ingress":1,"egress":2}]|,
          iface_chart_keys_json: ~s|["ingress","egress"]|,
          unit_mode: "Bps",
          loading: false,
          proto_breakdown_json: "[]",
          tcp_flags_json: "[]",
          flow_rate_points_json: ~s|[{"t":"2026-08-30T18:00:00Z","v":1}]|,
          duration_dist_json: "[]"
        }
      })

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(
             LazyHTML.query(document, "[phx-hook=NetflowStackedAreaChart]"),
             "data-timezone"
           ) == ["America/Chicago"]

    assert LazyHTML.attribute(LazyHTML.query(document, "[phx-hook=FlowRateChart]"), "data-timezone") == [
             "America/Chicago"
           ]
  end

  defp flow(id, time) do
    %{
      "id" => id,
      "time" => time,
      "src_endpoint_ip" => "192.0.2.10",
      "dst_endpoint_ip" => "198.51.100.20",
      "src_endpoint_port" => 12_345,
      "dst_endpoint_port" => 443,
      "protocol_num" => 6,
      "protocol_name" => "tcp",
      "packets_total" => 1,
      "bytes_total" => 64,
      "ocsf_payload" => %{}
    }
  end
end

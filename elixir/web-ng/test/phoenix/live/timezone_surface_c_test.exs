defmodule ServiceRadarWebNGWeb.TimezoneSurfaceCTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComponents
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.TraceTable

  @moduletag :unit
  @moduletag :db_free

  @compare_source Path.expand(
                    "../../../lib/serviceradar_web_ng_web/live/diagnostics_live/mtr_compare.ex",
                    __DIR__
                  )
  @external_resource @compare_source

  @plugin_package_source Path.expand(
                           "../../../lib/serviceradar_web_ng_web/live/admin/plugin_package_live/index.ex",
                           __DIR__
                         )
  @external_resource @plugin_package_source

  test "custom MTR datetime controls are visibly UTC and preserve their canonical UTC parser boundary" do
    source = File.read!(@compare_source)

    for label <- [
          "Window A Start (UTC)",
          "Window A End (UTC)",
          "Window B Start (UTC)",
          "Window B End (UTC)"
        ] do
      assert source =~ label
    end

    assert source =~
             ~S|defp window_input_value(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%dT%H:%M")|

    assert source =~ ~S|DateTime.from_naive!("Etc/UTC")|

    assert source =~
             ~S|defp window_param_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)|
  end

  test "MTR trace row time IDs remain attached to trace identities after reordering" do
    traces = [
      %{
        "id" => "trace-a",
        "time" => ~U[2026-08-30 18:00:00Z],
        "target" => "192.0.2.1",
        "target_ip" => "192.0.2.1",
        "target_reached" => true,
        "total_hops" => 2,
        "protocol" => "icmp",
        "ip_version" => 4,
        "agent_id" => "agent-a",
        "check_name" => "check-a"
      },
      %{
        "id" => "trace-b",
        "time" => ~U[2026-08-30 19:00:00Z],
        "target" => "192.0.2.2",
        "target_ip" => "192.0.2.2",
        "target_reached" => false,
        "total_hops" => 3,
        "protocol" => "icmp",
        "ip_version" => 4,
        "agent_id" => "agent-b",
        "check_name" => "check-b"
      }
    ]

    ids = fn rows ->
      (&TraceTable.render/1)
      |> render_component(
        traces: rows,
        pending_jobs: [],
        filter_target: "",
        filter_agent: "",
        timezone: "America/Chicago"
      )
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time")
      |> LazyHTML.attribute("id")
      |> Enum.sort()
    end

    assert ids.(traces) == ids.(Enum.reverse(traces))
    assert ids.(traces) == ["mtr-trace-trace-a-time", "mtr-trace-trace-b-time"]
  end

  test "imported plugin package timestamps use the current user's timezone" do
    source = File.read!(@plugin_package_source)

    assert source =~ ~S|id={"admin-plugin-package-#{package.id}-updated-at"}|
    assert source =~ "value={package.updated_at || package.inserted_at}"
    assert source =~ "timezone={@current_scope.user.timezone || \"Etc/UTC\"}"

    refute source =~ "{format_datetime(package.updated_at || package.inserted_at)}"
  end

  test "authored dashboard row time IDs prefer stable row identity over row order" do
    panel = %{
      id: "panel-1",
      title: "Events",
      srql_query: "in:events",
      visual_type: "table",
      data_binding: %{},
      display_config: %{},
      visual_config: %{},
      refresh_interval_seconds: nil
    }

    rows = [
      %{"id" => "event-a", "time" => ~U[2026-08-30 18:00:00Z]},
      %{"id" => "event-b", "time" => ~U[2026-08-30 19:00:00Z]}
    ]

    fields = [%{name: "time", type: :datetime}]

    ids = fn ordered_rows ->
      (&PanelComponents.panel_result/1)
      |> render_component(
        panel: panel,
        result: {:ok, %{rows: ordered_rows, fields: fields}},
        timezone: "America/Chicago"
      )
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time")
      |> LazyHTML.attribute("id")
      |> Enum.sort()
    end

    assert ids.(rows) == ids.(Enum.reverse(rows))

    assert ids.(rows) == [
             "authored-dashboard-panel-panel-1-row-s-event-a-s-time",
             "authored-dashboard-panel-panel-1-row-s-event-b-s-time"
           ]
  end
end

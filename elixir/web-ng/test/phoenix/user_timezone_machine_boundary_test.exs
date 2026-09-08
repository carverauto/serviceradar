defmodule ServiceRadarWebNGWeb.UserTimezoneMachineBoundaryTest do
  @moduledoc """
  Guards canonical UTC interfaces from the interactive presentation preference.

  These assertions intentionally combine executable fixtures with source-boundary
  checks. Private controller/export encoders remain private; the source checks keep
  the shared UI renderer out of those modules without exposing production helpers for
  tests.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.TimeZone, as: NotificationTimeZone
  alias ServiceRadarWebNG.Api.Access
  alias ServiceRadarWebNGWeb.DashboardLive.EventRange
  alias ServiceRadarWebNGWeb.Netflow.RangeSelection
  alias ServiceRadarWebNGWeb.ObservabilityPaths

  @moduletag :db_free

  @web_ng_root Path.expand("../..", __DIR__)

  test "SRQL, URL, and chart selection bounds remain exact canonical instants" do
    event_points = [
      %{bucket: ~U[2026-08-30 18:00:00Z]},
      %{bucket: ~U[2026-08-30 19:00:00Z]}
    ]

    assert {:ok, event_buckets} = EventRange.buckets(event_points)

    assert event_buckets == [
             %{x: 36, start: "2026-08-30T18:00:00Z", end: "2026-08-30T18:59:59.999999Z"},
             %{x: 616, start: "2026-08-30T19:00:00Z", end: "2026-08-30T19:59:59.999999Z"}
           ]

    flow_points = [
      %{bucket_start: ~U[2026-08-30 18:00:00Z], bucket_end: ~U[2026-08-30 19:00:00Z]},
      %{bucket_start: ~U[2026-08-30 19:00:00Z], bucket_end: ~U[2026-08-30 20:00:00Z]}
    ]

    assert RangeSelection.canonical_intervals(flow_points) == [
             %{start: "2026-08-30T18:00:00Z", end: "2026-08-30T18:59:59.999999Z"},
             %{start: "2026-08-30T19:00:00Z", end: "2026-08-30T19:59:59.999999Z"}
           ]

    assert {:ok, %{start: "2026-08-30T18:00:00Z", end: "2026-08-30T19:59:59.999999Z"}} =
             RangeSelection.validate(
               %{
                 "start" => "2026-08-30T18:00:00Z",
                 "end" => "2026-08-30T19:59:59.999999Z"
               },
               flow_points
             )

    path = ObservabilityPaths.events_range_path(~U[2026-08-30 18:00:00Z], ~U[2026-08-30 19:00:00Z])
    query = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("q")

    assert query ==
             "in:events time:[2026-08-30T18:00:00Z,2026-08-30T19:00:00Z] sort:time:desc limit:20"

    refute query =~ "GMT"
    refute query =~ "America/Chicago"
  end

  test "REST-facing device serialization remains canonical ISO" do
    device = %{
      uid: "device-1",
      type: "network",
      name: "edge-1",
      hostname: "edge-1.example.test",
      ip: "192.0.2.10",
      mac: "00:11:22:33:44:55",
      vendor_name: "Example",
      gateway_id: "gateway-1",
      is_available: true,
      last_seen_time: ~U[2026-08-30 18:00:00.123456Z],
      first_seen_time: ~N[2026-08-29 17:00:00.654321]
    }

    assert %{
             "last_seen_time" => "2026-08-30T18:00:00.123456Z",
             "first_seen_time" => "2026-08-29T17:00:00.654321"
           } = Access.device_to_map(device)
  end

  test "notification timezone validation and wall-clock conversion continue to use the schedule timezone" do
    validation_query = fn sql, [timezone] ->
      send(self(), {:timezone_validation_query, sql, timezone})
      {:ok, %{rows: [[timezone == "America/Chicago"]]}}
    end

    assert NotificationTimeZone.supported?("America/Chicago", query: validation_query)
    refute NotificationTimeZone.supported?("Mars/Olympus", query: validation_query)
    refute NotificationTimeZone.supported?("", query: validation_query)

    assert_received {:timezone_validation_query, validation_sql, "America/Chicago"}
    assert_received {:timezone_validation_query, ^validation_sql, "Mars/Olympus"}
    refute_received {:timezone_validation_query, _, ""}
    assert validation_sql =~ "pg_timezone_names"

    now = ~U[2026-11-01 06:30:00Z]
    expected_local = ~N[2026-11-01 01:30:00]

    query = fn sql, params ->
      send(self(), {:timezone_query, sql, params})
      {:ok, %{rows: [[expected_local]]}}
    end

    assert {:ok, ^expected_local} =
             NotificationTimeZone.local_datetime(now, "America/Chicago", query: query)

    assert_received {:timezone_query, sql, [^now, "America/Chicago"]}
    assert sql =~ "AT TIME ZONE"

    assert {:ok, ~N[2026-11-01 06:30:00]} =
             NotificationTimeZone.local_datetime(now, "Etc/UTC", query: query)

    refute_received {:timezone_query, _, _}
  end

  test "exports, reports, and schedule evaluation do not import the presentation contract" do
    machine_paths = [
      "lib/serviceradar_web_ng/api/access.ex",
      "lib/serviceradar_web_ng/dashboards/report_delivery_worker.ex",
      "lib/serviceradar_web_ng_web/controllers/api/device_controller.ex",
      "lib/serviceradar_web_ng_web/controllers/authored_dashboard_export_controller.ex",
      "lib/serviceradar_web_ng_web/controllers/topology_snapshot_controller.ex"
    ]

    for relative <- machine_paths do
      source = read_web_ng(relative)

      refute source =~ "<.user_time", "#{relative} must not render localized UI timestamps"
      refute source =~ "formatUserTime", "#{relative} must not call the browser presentation formatter"
      refute source =~ "UserTime", "#{relative} must not depend on the presentation hook"
      refute source =~ "current_scope.user.timezone", "#{relative} must not read the UI preference"
    end

    device_controller = read_web_ng("lib/serviceradar_web_ng_web/controllers/api/device_controller.ex")
    report_worker = read_web_ng("lib/serviceradar_web_ng/dashboards/report_delivery_worker.ex")
    csv_controller = read_web_ng("lib/serviceradar_web_ng_web/controllers/authored_dashboard_export_controller.ex")

    assert device_controller =~ "DateTime.to_iso8601(value)"
    assert report_worker =~ "DateTime.shift_zone!(\"Etc/UTC\")"
    assert report_worker =~ "DateTime.from_naive!(\"Etc/UTC\")"
    assert report_worker =~ "DateTime.to_iso8601()"

    assert csv_controller =~
             "defp format_value(value) when is_binary(value), do: value"

    for relative <- [
          "lib/serviceradar_web_ng/jobs.ex",
          "lib/serviceradar_web_ng/dashboards/authored/validation.ex",
          "lib/serviceradar_web_ng/dashboards/report_scanner_worker.ex"
        ] do
      source = read_web_ng(relative)

      refute source =~ "current_scope.user.timezone"
      refute source =~ "user.timezone"
      refute source =~ "UserTime"
    end
  end

  test "relative labels remain durations rather than wall-clock timestamps" do
    alias ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow

    assert TimeWindow.human_time_token("last_1h") == "Last 1h"
    assert TimeWindow.human_time_token("last_7d") == "Last 7d"

    assert TimeWindow.human_time_token("[2026-08-30T18:00:00Z,2026-08-30T19:00:00Z]") ==
             "Custom range"
  end

  test "profile typing does not query the PostgreSQL timezone catalog" do
    source = read_web_ng("lib/serviceradar_web_ng_web/live/user_live/settings.ex")

    refute source =~ ~s(phx-change="validate_timezone")
    refute source =~ ~s(def handle_event("validate_timezone")
    assert source =~ ~s(def handle_event("update_timezone")
    assert source =~ "AshPhoenix.Form.submit"
  end

  defp read_web_ng(relative), do: File.read!(Path.join(@web_ng_root, relative))
end

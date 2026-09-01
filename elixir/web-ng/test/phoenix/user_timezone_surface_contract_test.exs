defmodule ServiceRadarWebNGWeb.UserTimezoneSurfaceContractTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNGWeb.AnalyticsLive.Index, as: AnalyticsIndex
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.WorkbenchComponents
  alias ServiceRadarWebNGWeb.BmpLive.Index, as: BmpIndex
  alias ServiceRadarWebNGWeb.DashboardLive.Index.EventsPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.ThreatPanel
  alias ServiceRadarWebNGWeb.DeviceLive.AvailabilityComponents
  alias ServiceRadarWebNGWeb.DeviceLive.BumblebeeComponents
  alias ServiceRadarWebNGWeb.DeviceLive.DiscoverySourcesComponents
  alias ServiceRadarWebNGWeb.DeviceLive.HealthcheckComponents
  alias ServiceRadarWebNGWeb.DeviceLive.LogComponents
  alias ServiceRadarWebNGWeb.DeviceLive.MtrComponents
  alias ServiceRadarWebNGWeb.DeviceLive.ProcessMetricsComponents
  alias ServiceRadarWebNGWeb.DeviceLive.SweepComponents
  alias ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents
  alias ServiceRadarWebNGWeb.NorthboundActionComponents
  alias ServiceRadarWebNGWeb.ObservabilityHealthLive.Index, as: ObservabilityHealthIndex
  alias ServiceRadarWebNGWeb.SecurityLive.Index, as: SecurityIndex
  alias ServiceRadarWebNGWeb.ServiceLive.Show.HistoryTable
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewTemplate
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewTemplateComponents

  @moduletag :db_free

  @canonical "2026-08-30T18:00:00Z"
  @timezone "America/Chicago"

  test "topology template forwards the saved timezone to both rendering boundaries" do
    html = render_component(&GodViewTemplate.render/1, god_view_template_assigns())
    document = LazyHTML.from_fragment(html)

    surface = LazyHTML.query(document, "#god-view-binary-stream")
    generated_at = LazyHTML.query(document, "time#god-view-stream-generated-at")

    assert LazyHTML.attribute(surface, "data-timezone") == [@timezone]
    assert LazyHTML.attribute(generated_at, "datetime") == [@canonical]
    assert LazyHTML.attribute(generated_at, "data-user-time-zone") == [@timezone]
  end

  test "topology stream contract localizes the generated-at instant" do
    html =
      render_component(&GodViewTemplateComponents.stream_contract/1,
        schema_version: 1,
        stream_state: :ok,
        last_revision: 42,
        last_generated_at: @canonical,
        last_bytes: 1_024,
        last_node_count: 2,
        last_edge_count: 1,
        last_network_ms: 3.5,
        last_renderer_mode: "webgl",
        last_zoom_tier: "near",
        last_zoom_mode: "local",
        last_decode_ms: 1.5,
        last_render_ms: 2.5,
        last_bitmap_metadata: nil,
        timezone: @timezone
      )

    document = LazyHTML.from_fragment(html)
    time = LazyHTML.query(document, "time#god-view-stream-generated-at[phx-hook='UserTime']")

    assert LazyHTML.attribute(time, "datetime") == [@canonical]
    assert LazyHTML.attribute(time, "data-user-time-zone") == [@timezone]
    assert LazyHTML.text(time) == @canonical

    surface_html =
      render_component(&GodViewTemplateComponents.surface/1,
        snapshot_url: "/topology/snapshot/latest",
        stream_state: :ok,
        last_node_count: 2,
        last_edge_count: 1,
        pipeline_stats: %{},
        controls_collapsed: true,
        visual_layers: %{mantle: true, crust: true, atmosphere: true, security: true},
        zoom_mode: "local",
        causal_filters: %{root_cause: true, affected: true, healthy: true, unknown: true},
        topology_layers: %{backbone: true, inferred: false, endpoints: false, mtr_paths: true},
        timezone: @timezone
      )

    surface =
      surface_html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#god-view-binary-stream")

    assert LazyHTML.attribute(surface, "data-timezone") == [@timezone]
  end

  test "authored dashboard source schema localizes only datetime samples" do
    form =
      Phoenix.Component.to_form(
        %{
          "name" => "Recent events",
          "title" => "Recent events",
          "srql_query" => "in:events limit:10",
          "display_label" => "",
          "unit" => "",
          "lookback_days" => "",
          "caption" => ""
        },
        as: :source_query
      )

    html =
      render_component(&WorkbenchComponents.dashboard_workbench/1,
        dashboard: %{
          id: "dashboard-timezone-preview",
          owner_id: "user-1",
          panels: [],
          metadata: %{},
          visibility: :private
        },
        settings_open?: true,
        source_query_form: form,
        source_query_preview: %{
          row_count: 1,
          fields: [
            %{name: "observed_at", type: :datetime, sample: @canonical},
            %{name: "note", type: :string, sample: @canonical}
          ],
          outputs: []
        },
        panel_results: %{},
        editing_panel_id: nil,
        access_grants: [],
        user_grant_form: nil,
        group_grant_form: nil,
        users: [],
        user_groups: [],
        can_view_groups?: false,
        can_edit?: false,
        can_share?: false,
        can_schedule_reports?: false,
        report_schedule_form: nil,
        current_scope: %{user: %{id: "user-1", timezone: @timezone}}
      )

    document = LazyHTML.from_fragment(html)
    time = LazyHTML.query(document, "time[phx-hook='UserTime']")

    assert LazyHTML.attribute(time, "datetime") == [@canonical]
    assert LazyHTML.attribute(time, "data-user-time-zone") == [@timezone]

    note_sample =
      LazyHTML.query(document, "tr[data-source-field='note'] td:nth-child(3)")

    assert note_sample |> LazyHTML.text() |> String.trim() == @canonical
    assert note_sample |> LazyHTML.query("time") |> LazyHTML.attribute("datetime") == []

    [canvas_props] =
      document
      |> LazyHTML.query("[phx-hook='DashboardBuilderCanvas']")
      |> LazyHTML.attribute("data-props")
      |> Enum.map(&Jason.decode!/1)

    assert canvas_props["timezone"] == @timezone
  end

  test "dashboard threat instants stay canonical and carry the saved zone" do
    html =
      render_component(&ThreatPanel.render/1,
        timezone: @timezone,
        dashboard: %{
          threat_intel_summary: %{
            imported_indicators: 2,
            source_objects: 1,
            matched_ips: 2,
            indicator_matches: 2,
            max_severity: 5,
            latest_provider: "alienvault_otx",
            latest_source: "alienvault_otx",
            latest_status: "ok",
            latest_message: "sync complete",
            latest_success_at: ~U[2026-08-30 18:00:00Z],
            latest_attempt_at: nil,
            recent_matches: [
              threat_match("198.51.100.1"),
              threat_match("198.51.100.2")
            ]
          }
        }
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time[data-user-time-zone='#{@timezone}']")

    assert LazyHTML.attribute(times, "id") == [
             "dashboard-threat-last-success-at",
             "dashboard-threat-match-198-51-100-1-looked-up-at",
             "dashboard-threat-match-198-51-100-2-looked-up-at"
           ]

    assert LazyHTML.attribute(times, "datetime") == List.duplicate(@canonical, 3)
    assert times |> LazyHTML.attribute("id") |> Enum.uniq() |> length() == 3
  end

  test "analytics absolute event times are semantic without changing the event query" do
    query =
      "in:events log_level:(FATAL,fatal,CRITICAL,critical,ERROR,error) time:last_24h sort:time:desc limit:100"

    html =
      render_component(&AnalyticsIndex.critical_events_widget/1,
        timezone: @timezone,
        loading: false,
        summary: %{
          total: 2,
          critical: 2,
          error: 0,
          warning: 0,
          info: 0,
          recent: [analytics_event("event-a"), analytics_event("event-b")]
        }
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time[data-user-time-zone='#{@timezone}']")

    assert LazyHTML.attribute(times, "id") == [
             "analytics-event-event-a-observed-at",
             "analytics-event-event-b-observed-at"
           ]

    assert LazyHTML.attribute(times, "datetime") == [
             "2026-08-20T18:00:00Z",
             "2026-08-20T18:00:00Z"
           ]

    assert times |> LazyHTML.attribute("id") |> Enum.uniq() |> length() == 2

    assert html =~ URI.encode_query(%{"q" => query})
  end

  test "device alias rows use stable resource-derived ids for repeated instants" do
    aliases = [
      alias_row("192.0.2.10", :ip),
      alias_row("192.0.2.11", :interface_ip)
    ]

    html =
      render_component(&SweepComponents.ip_aliases_section/1,
        aliases: aliases,
        error: nil,
        show_stale: false,
        timezone: @timezone
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time[data-user-time-zone='#{@timezone}']")

    assert LazyHTML.attribute(times, "id") == [
             "device-ip-alias-192-0-2-10-last-seen-at",
             "device-ip-alias-192-0-2-11-last-seen-at"
           ]

    assert LazyHTML.attribute(times, "datetime") == [@canonical, @canonical]
    assert times |> LazyHTML.attribute("id") |> Enum.uniq() |> length() == 2
  end

  test "service history derives unique stable ids for repeated service identities" do
    services = [
      %{"service_id" => "check-a", "timestamp" => @canonical, "available" => true},
      %{
        "service_id" => "check-a",
        "timestamp" => "2026-08-30T18:01:00Z",
        "available" => false
      }
    ]

    render = fn rows ->
      render_component(&HistoryTable.render/1,
        services: rows,
        timezone: @timezone,
        page: 1,
        per_page: 20
      )
    end

    html = render.(services)
    document = LazyHTML.from_fragment(html)
    rows = LazyHTML.query(document, "tr[id^='service-history-row-']")
    times = LazyHTML.query(document, "time[data-user-time-zone='#{@timezone}']")

    row_ids = LazyHTML.attribute(rows, "id")
    time_ids = LazyHTML.attribute(times, "id")

    assert length(row_ids) == 2
    assert length(Enum.uniq(row_ids)) == 2
    assert length(time_ids) == 2
    assert length(Enum.uniq(time_ids)) == 2

    rerendered_document = services |> Enum.reverse() |> render.() |> LazyHTML.from_fragment()

    assert MapSet.new(row_ids) ==
             rerendered_document
             |> LazyHTML.query("tr[id^='service-history-row-']")
             |> LazyHTML.attribute("id")
             |> MapSet.new()

    assert MapSet.new(time_ids) == user_time_id_set(render.(Enum.reverse(services)))

    assert LazyHTML.attribute(times, "datetime") == [
             @canonical,
             "2026-08-30T18:01:00Z"
           ]
  end

  test "northbound device action history keeps resource ids when rows reorder" do
    polling_entry =
      "invocation-a"
      |> northbound_entry()
      |> Map.merge(%{
        state: :polling,
        target_status: :result_fetching,
        next_poll_at: ~U[2026-08-30 18:00:00Z],
        poll_attempt_count: 2
      })

    entries = [polling_entry, northbound_entry("invocation-b")]

    render = fn rows ->
      render_component(&NorthboundActionComponents.northbound_action_history/1,
        entries: rows,
        timezone: @timezone
      )
    end

    html = render.(entries)
    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time[data-user-time-zone='#{@timezone}']")

    expected_ids = [
      "northbound-action-invocation-a-inserted-at",
      "northbound-action-invocation-a-next-poll-at",
      "northbound-action-invocation-b-inserted-at"
    ]

    assert LazyHTML.attribute(times, "id") == expected_ids
    assert user_time_id_set(render.(Enum.reverse(entries))) == MapSet.new(expected_ids)
    assert LazyHTML.attribute(times, "datetime") == [@canonical, @canonical, @canonical]
  end

  test "availability and log row ids survive row reordering" do
    availability_rows = [availability_row("availability-a", "agent-a"), availability_row("availability-b", "agent-b")]

    render_availability = fn rows ->
      render_component(&AvailabilityComponents.agent_availability_section/1,
        rows: rows,
        device_row: %{},
        sweep_results: nil,
        timezone: @timezone
      )
    end

    availability_ids = [
      "device-agent-availability-agent-a-checked-at",
      "device-agent-availability-agent-b-checked-at"
    ]

    assert user_time_ids(render_availability.(availability_rows)) == availability_ids

    assert user_time_id_set(render_availability.(Enum.reverse(availability_rows))) ==
             MapSet.new(availability_ids)

    logs = [log_row("log-a"), log_row("log-b")]

    render_logs = fn rows ->
      render_component(&LogComponents.device_logs_tab_content/1,
        logs: rows,
        device_uid: "device-a",
        query: "in:logs device_uid:device-a",
        limit: 20,
        timezone: @timezone
      )
    end

    log_ids = ["device-log-log-a-timestamp", "device-log-log-b-timestamp"]

    assert user_time_ids(render_logs.(logs)) == log_ids
    assert user_time_id_set(render_logs.(Enum.reverse(logs))) == MapSet.new(log_ids)
  end

  test "MTR trace and job ids survive row reordering" do
    traces = [mtr_trace("trace-a", "192.0.2.1"), mtr_trace("trace-b", "192.0.2.2")]
    jobs = [mtr_job("job-a", "192.0.2.1"), mtr_job("job-b", "192.0.2.2")]

    render = fn trace_rows, job_rows ->
      render_component(&MtrComponents.mtr_tab_content/1,
        device_uid: "device-a",
        traces: trace_rows,
        recent_traces: trace_rows,
        pending_jobs: job_rows,
        total_count: 2,
        timezone: @timezone
      )
    end

    expected_ids = [
      "device-mtr-outcome-trace-a-time",
      "device-mtr-outcome-trace-b-time",
      "device-mtr-job-job-a-inserted-at",
      "device-mtr-job-job-b-inserted-at",
      "device-mtr-trace-trace-a-time",
      "device-mtr-trace-trace-b-time"
    ]

    assert MapSet.new(user_time_ids(render.(traces, jobs))) == MapSet.new(expected_ids)

    assert user_time_id_set(render.(Enum.reverse(traces), Enum.reverse(jobs))) ==
             MapSet.new(expected_ids)
  end

  test "observability health ids use the first stable identity across reordered rows" do
    capacity_rows = [capacity_row("forecast-a"), capacity_row("forecast-b")]
    anomaly_rows = [anomaly_row("anomaly-a"), anomaly_row("anomaly-b")]

    render = fn capacity, anomalies ->
      render_component(&ObservabilityHealthIndex.render/1,
        flash: %{},
        current_scope: %{
          user: %{
            id: "user-a",
            email: "user@example.com",
            role: :admin,
            timezone: @timezone
          }
        },
        srql: %{},
        loading?: false,
        capacity_query: "in:capacity_forecasts status:projected",
        selected_capacity: nil,
        overview: observability_overview(capacity, anomalies)
      )
    end

    expected_ids = [
      "observability-capacity-forecast-a-projected-exhaustion-at",
      "observability-capacity-forecast-b-projected-exhaustion-at",
      "observability-forecast-forecast-a-projected-exhaustion-at",
      "observability-forecast-forecast-b-projected-exhaustion-at",
      "observability-anomaly-anomaly-a-time",
      "observability-anomaly-anomaly-b-time"
    ]

    assert MapSet.new(user_time_ids(render.(capacity_rows, anomaly_rows))) == MapSet.new(expected_ids)

    assert user_time_id_set(render.(Enum.reverse(capacity_rows), Enum.reverse(anomaly_rows))) ==
             MapSet.new(expected_ids)
  end

  test "other repeated device rows use stable identities instead of list positions" do
    finding_ids = [
      "device-bumblebee-finding-catalog-a-last-seen-at",
      "device-bumblebee-finding-catalog-b-last-seen-at"
    ]

    findings = [bumblebee_finding("catalog-a"), bumblebee_finding("catalog-b")]

    render_findings = fn rows ->
      render_component(&BumblebeeComponents.bumblebee_section/1,
        findings: rows,
        postures: [],
        has_exposure: true,
        timezone: @timezone
      )
    end

    assert user_time_id_set(render_findings.(findings)) == MapSet.new(finding_ids)
    assert user_time_id_set(render_findings.(Enum.reverse(findings))) == MapSet.new(finding_ids)

    services = [healthcheck_row("service-a"), healthcheck_row("service-b")]
    healthcheck_ids = ["device-healthcheck-service-a-timestamp", "device-healthcheck-service-b-timestamp"]

    render_healthchecks = fn rows ->
      render_component(&HealthcheckComponents.healthcheck_section/1,
        summary: %{services: rows, total: 2, available: 2, unavailable: 0},
        timezone: @timezone
      )
    end

    assert user_time_id_set(render_healthchecks.(services)) == MapSet.new(healthcheck_ids)

    assert user_time_id_set(render_healthchecks.(Enum.reverse(services))) ==
             MapSet.new(healthcheck_ids)

    processes = [process_row("101", "process-a"), process_row("202", "process-b")]
    process_ids = ["device-process-metric-101-timestamp", "device-process-metric-202-timestamp"]

    render_processes = fn rows ->
      render_component(&ProcessMetricsComponents.process_metrics_section/1,
        metrics: rows,
        timezone: @timezone
      )
    end

    assert user_time_id_set(render_processes.(processes)) ==
             MapSet.new(["device-process-metrics-last-sampled-at" | process_ids])

    assert user_time_id_set(render_processes.(Enum.reverse(processes))) ==
             MapSet.new(["device-process-metrics-last-sampled-at" | process_ids])

    sweeps = [sweep_row("sweep-a", "agent-a"), sweep_row("sweep-b", "agent-b")]

    sweep_ids = [
      "device-sweep-latest-inserted-at",
      "device-sweep-history-sweep-a-inserted-at",
      "device-sweep-history-sweep-b-inserted-at"
    ]

    render_sweeps = fn rows ->
      render_component(&SweepComponents.sweep_status_section/1,
        sweep_results: %{results: rows},
        timezone: @timezone
      )
    end

    assert user_time_id_set(render_sweeps.(sweeps)) == MapSet.new(sweep_ids)
    assert user_time_id_set(render_sweeps.(Enum.reverse(sweeps))) == MapSet.new(sweep_ids)
  end

  test "derived active fingerprint and dashboard axis ids do not append list positions" do
    fingerprint_html =
      render_component(&VisibilityComponents.active_fingerprint_tab_content/1,
        device_row: active_fingerprint_device(),
        timezone: @timezone
      )

    assert MapSet.subset?(
             MapSet.new([
               "device-active-fingerprint-device-a-SSH-observed-at",
               "device-active-fingerprint-device-a-HTTP-observed-at"
             ]),
             user_time_id_set(fingerprint_html)
           )

    points = [event_point(~U[2026-08-27 10:00:00Z]), event_point(~U[2026-08-27 12:00:00Z])]

    render_events = fn rows ->
      render_component(&EventsPanel.render/1,
        dashboard: %{security_trend: rows, security_trend_max: 4, time_window_label: "24h"},
        embedded: true,
        timezone: @timezone
      )
    end

    expected_axis_ids = MapSet.new(["dashboard-events-axis-1787824800", "dashboard-events-axis-1787832000"])

    assert axis_id_set(render_events.(points)) == expected_axis_ids
    assert axis_id_set(render_events.(Enum.reverse(points))) == expected_axis_ids
  end

  test "rows without a stable identity use their list position as the final fallback" do
    html =
      render_component(&LogComponents.device_logs_tab_content/1,
        logs: [log_row(nil), log_row(nil)],
        device_uid: "device-a",
        query: "in:logs device_uid:device-a",
        limit: 20,
        timezone: @timezone
      )

    assert user_time_ids(html) == ["device-log-0-timestamp", "device-log-1-timestamp"]
  end

  test "BMP and security overview instants use the saved timezone contract" do
    bmp_html =
      render_component(&BmpIndex.bmp_event_time/1,
        id: "bmp-event-event-a-time",
        value: @canonical,
        timezone: @timezone
      )

    security_html =
      render_component(&SecurityIndex.security_finding_time/1,
        id: "security-finding-finding-a-time",
        value: @canonical,
        timezone: @timezone
      )

    for html <- [bmp_html, security_html] do
      document = LazyHTML.from_fragment(html)
      time = LazyHTML.query(document, "time[data-user-time-zone='#{@timezone}']")

      assert LazyHTML.attribute(time, "datetime") == [@canonical]
      assert LazyHTML.attribute(time, "data-user-time-fallback") == [@canonical]
    end
  end

  test "device discovery instants remain semantic and stable when observations reorder" do
    observations = [
      %{
        "source" => "example-inventory",
        "source_instance" => "inventory-a",
        "source_object_id" => "object-a",
        "collection_id" => "collection-a",
        "last_observed_at" => @canonical,
        "present" => true
      },
      %{
        "source" => "example-inventory",
        "source_instance" => "inventory-a",
        "source_object_id" => "object-b",
        "collection_id" => "collection-b",
        "last_observed_at" => "2026-08-30T19:00:00Z",
        "present" => false
      }
    ]

    render_discovery = fn rows ->
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          "discovery_sources" => ["sighting"],
          "metadata" => %{"discovery_time" => @canonical}
        },
        source_observations: rows,
        timezone: @timezone
      )
    end

    html = render_discovery.(observations)
    ids = user_time_id_set(html)

    assert MapSet.member?(ids, "discovery-source-sighting-discovery-time")
    assert MapSet.size(ids) == 3
    assert ids == user_time_id_set(render_discovery.(Enum.reverse(observations)))

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(
             LazyHTML.query(document, "time[data-user-time-zone='#{@timezone}']"),
             "datetime"
           ) == [@canonical, @canonical, "2026-08-30T19:00:00Z"]
  end

  defp availability_row(id, agent_id) do
    %{
      id: id,
      agent_id: agent_id,
      agent_name: nil,
      is_available: true,
      checked_at: ~U[2026-08-30 18:00:00Z],
      response_time_ms: 12,
      open_ports: [],
      sweep_modes_results: %{}
    }
  end

  defp log_row(id) do
    %{
      "id" => id,
      "observed_timestamp" => @canonical,
      "severity_text" => "info",
      "service_name" => "collector",
      "body" => "message"
    }
  end

  defp mtr_trace(id, target) do
    %{
      "id" => id,
      "target" => target,
      "time" => @canonical,
      "target_reached" => true,
      "total_hops" => 2,
      "protocol" => "icmp",
      "check_name" => "edge"
    }
  end

  defp mtr_job(id, target) do
    %{
      id: id,
      inserted_at: ~U[2026-08-30 18:00:00Z],
      payload: %{"target" => target},
      status: :queued
    }
  end

  defp capacity_row(id) do
    %{
      "id" => id,
      "resource_key" => "disk:/",
      "resource_id" => "device-a",
      "metric_name" => "disk.used_percent",
      "status" => "projected",
      "current_value" => 70,
      "projected_value" => 90,
      "exhaustion_threshold" => 95,
      "projected_exhaustion_at" => @canonical,
      "forecasted_at" => @canonical
    }
  end

  defp anomaly_row(id) do
    %{
      "id" => id,
      "time" => @canonical,
      "finding_title" => "Threshold exceeded",
      "source_type" => "anomaly_detection",
      "severity" => "High"
    }
  end

  defp observability_overview(capacity_rows, anomaly_rows) do
    %{
      status: :ok,
      anomaly_query: "in:events event_type:anomaly",
      health_query: "in:events rollup_stats:anomaly_findings",
      capacity_query: "in:capacity_forecasts status:projected",
      anomaly_rows: anomaly_rows,
      health_rows: [],
      capacity_rows: capacity_rows,
      capacity_skipped: %{count: 0, top_reasons: []},
      anomaly_count: length(anomaly_rows),
      health_count: 0,
      capacity_count: length(capacity_rows)
    }
  end

  defp bumblebee_finding(id) do
    %{
      catalog_id: id,
      package_name: "openssl",
      package_version: "3.0",
      severity: "high",
      last_seen_at: ~U[2026-08-30 18:00:00Z]
    }
  end

  defp healthcheck_row(id) do
    %{
      id: id,
      service_name: id,
      service_type: "grpc",
      available: true,
      message: "healthy",
      timestamp: @canonical
    }
  end

  defp process_row(pid, name) do
    %{
      "pid" => pid,
      "name" => name,
      "cpu_usage" => 1.0,
      "memory_usage" => 1024,
      "status" => "running",
      "timestamp" => @canonical,
      "_cpu_sparkline" => []
    }
  end

  defp sweep_row(id, agent_id) do
    %{
      id: id,
      inserted_at: ~U[2026-08-30 18:00:00Z],
      status: :available,
      response_time_ms: 12,
      open_ports: [],
      sweep_modes_results: %{},
      execution: %{agent_id: agent_id}
    }
  end

  defp active_fingerprint_device do
    %{
      "uid" => "device-a",
      "metadata" => %{
        "active_fingerprint" => %{
          "observed_at" => @canonical,
          "recog" => %{
            "ssh" => %{"product" => "OpenSSH", "observed_at" => @canonical},
            "http" => %{"product" => "nginx", "observed_at" => @canonical}
          }
        }
      }
    }
  end

  defp event_point(bucket) do
    %{bucket: bucket, label: "bucket", total: 4, low: 4, medium: 0, high: 0, critical: 0}
  end

  defp user_time_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("time[phx-hook='UserTime']")
    |> LazyHTML.attribute("id")
  end

  defp user_time_id_set(html), do: html |> user_time_ids() |> MapSet.new()

  defp axis_id_set(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".sr-ops-events-axis text[phx-hook='UserTime']")
    |> LazyHTML.attribute("id")
    |> MapSet.new()
  end

  defp threat_match(ip) do
    %{
      ip: ip,
      match_count: 1,
      looked_up_at: ~U[2026-08-30 18:00:00Z],
      device_uid: nil,
      hostname: nil
    }
  end

  defp analytics_event(uid) do
    %{
      "uid" => uid,
      "host" => "edge-1",
      "message" => "threshold exceeded",
      "severity" => "Critical",
      "time" => "2026-08-20T18:00:00Z"
    }
  end

  defp alias_row(value, type) do
    %{
      alias_value: value,
      alias_type: type,
      state: :confirmed,
      sighting_count: 2,
      last_seen_at: ~U[2026-08-30 18:00:00Z]
    }
  end

  defp northbound_entry(invocation_id) do
    %{
      invocation_id: invocation_id,
      action_label: "Device lookup",
      state: :succeeded,
      target_status: :succeeded,
      target_kind: :device,
      device_uid: "device-1",
      inserted_at: ~U[2026-08-30 18:00:00Z],
      redacted_input_values: %{}
    }
  end

  defp god_view_template_assigns do
    %{
      flash: %{},
      current_scope: %{
        user: %{email: "operator@example.com", role: :admin, timezone: @timezone}
      },
      current_path: "/topology",
      snapshot_url: "/topology/snapshot/latest",
      schema_version: 1,
      stream_state: :ok,
      last_revision: 42,
      last_generated_at: @canonical,
      last_bytes: 1_024,
      last_node_count: 2,
      last_edge_count: 1,
      last_network_ms: 3.5,
      last_renderer_mode: "webgl",
      last_zoom_tier: "near",
      last_zoom_mode: "local",
      last_decode_ms: 1.5,
      last_render_ms: 2.5,
      last_bitmap_metadata: nil,
      pipeline_stats: %{},
      controls_collapsed: true,
      visual_layers: %{mantle: true, crust: true, atmosphere: true, security: true},
      zoom_mode: "local",
      causal_filters: %{root_cause: true, affected: true, healthy: true, unknown: true},
      topology_layers: %{backbone: true, inferred: false, endpoints: false, mtr_paths: true},
      selected_camera_context: nil,
      active_camera_relay_session: nil,
      last_camera_relay_session: nil,
      camera_relay_viewer_state: nil,
      camera_relay_tiles: [],
      camera_relay_tile_notice: nil
    }
  end
end

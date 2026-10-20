defmodule ServiceRadarWebNGWeb.AlertEvaluationModeUITest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.DashboardLive.Data
  alias ServiceRadarWebNGWeb.DashboardLive.Index.AlertsPanel
  alias ServiceRadarWebNGWeb.LogLive.Index, as: LogLiveIndex
  alias ServiceRadarWebNGWeb.Settings.RulesLive.Index, as: RulesLiveIndex

  @moduletag :db_free

  setup do
    previous_mode = Application.get_env(:serviceradar_core, :alert_evaluation_mode)

    on_exit(fn ->
      if is_nil(previous_mode) do
        Application.delete_env(:serviceradar_core, :alert_evaluation_mode)
      else
        Application.put_env(:serviceradar_core, :alert_evaluation_mode, previous_mode)
      end
    end)

    :ok
  end

  test "dashboard alerts panel surfaces not-activated state when rollout mode is not active" do
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :prepared)

    prepared_html =
      render_component(&AlertsPanel.render/1,
        dashboard: Data.empty(),
        timezone: "Etc/UTC"
      )

    prepared_doc = LazyHTML.from_fragment(prepared_html)

    assert prepared_doc |> LazyHTML.query("[data-testid='alerts-feed-not-activated']") |> Enum.count() == 1
    assert prepared_doc |> LazyHTML.query("[data-testid='alerts-feed-empty']") |> Enum.count() == 0
    assert prepared_html =~ "Alert evaluation is not activated"
    assert prepared_html =~ "prepared"
    assert prepared_html =~ "core.alertEvaluation.mode"

    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :active)

    active_html =
      render_component(&AlertsPanel.render/1,
        dashboard: Data.empty(),
        timezone: "Etc/UTC"
      )

    active_doc = LazyHTML.from_fragment(active_html)

    assert active_doc |> LazyHTML.query("[data-testid='alerts-feed-empty']") |> Enum.count() == 1
    assert active_doc |> LazyHTML.query("[data-testid='alerts-feed-not-activated']") |> Enum.count() == 0
  end

  test "dashboard alerts panel keeps not-activated notice alongside retained alerts" do
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :draining)

    retained_alert = %{
      id: "00000000-0000-0000-0000-0000000000a1",
      severity: "warning",
      title: "Interface down",
      status: "pending",
      source_type: "snmp",
      device_uid: "device-01",
      observed_at: ~U[2026-01-01 00:00:00Z]
    }

    draining_html =
      render_component(&AlertsPanel.render/1,
        dashboard: Map.put(Data.empty(), :alert_feed, [retained_alert]),
        timezone: "Etc/UTC"
      )

    draining_doc = LazyHTML.from_fragment(draining_html)

    assert draining_doc |> LazyHTML.query("[data-testid='alerts-feed']") |> Enum.count() == 1

    assert draining_doc
           |> LazyHTML.query("[data-testid='alerts-feed-not-activated-notice']")
           |> Enum.count() == 1

    assert draining_html =~ "draining"
    assert draining_html =~ "core.alertEvaluation.mode"

    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :active)

    active_html =
      render_component(&AlertsPanel.render/1,
        dashboard: Map.put(Data.empty(), :alert_feed, [retained_alert]),
        timezone: "Etc/UTC"
      )

    active_doc = LazyHTML.from_fragment(active_html)

    assert active_doc
           |> LazyHTML.query("[data-testid='alerts-feed-not-activated-notice']")
           |> Enum.count() == 0
  end

  test "observability alerts list surfaces not-activated notice instead of no alerts when rollout mode is not active" do
    prepared_html = render_component(&LogLiveIndex.render/1, log_live_alerts_assigns(:prepared))
    prepared_doc = LazyHTML.from_fragment(prepared_html)

    assert prepared_doc
           |> LazyHTML.query("[data-testid='alerts-evaluation-not-activated']")
           |> Enum.count() == 1

    assert prepared_doc
           |> LazyHTML.query("[data-testid='alerts-table-not-activated']")
           |> Enum.count() == 1

    assert prepared_html =~ "Alert evaluation is not activated"
    assert prepared_html =~ "prepared"
    assert prepared_html =~ "core.alertEvaluation.mode"
    assert prepared_html =~ "/settings/rules?tab=alerts"
    refute prepared_html =~ "No alerts found."

    active_html = render_component(&LogLiveIndex.render/1, log_live_alerts_assigns(:active))
    active_doc = LazyHTML.from_fragment(active_html)

    assert active_doc
           |> LazyHTML.query("[data-testid='alerts-evaluation-not-activated']")
           |> Enum.count() == 0

    assert active_html =~ "No alerts found."
  end

  test "settings alert rules tab surfaces not-activated banner when rollout mode is not active" do
    draining_html = render_component(&RulesLiveIndex.render/1, rules_live_alerts_assigns(:draining))
    draining_doc = LazyHTML.from_fragment(draining_html)

    assert draining_doc
           |> LazyHTML.query("[data-testid='alert-rules-evaluation-not-activated']")
           |> Enum.count() == 1

    assert draining_html =~ "Alert evaluation is not activated"
    assert draining_html =~ "draining"
    assert draining_html =~ "core.alertEvaluation.mode"
    assert draining_html =~ "/observability/alerts"

    active_html = render_component(&RulesLiveIndex.render/1, rules_live_alerts_assigns(:active))
    active_doc = LazyHTML.from_fragment(active_html)

    assert active_doc
           |> LazyHTML.query("[data-testid='alert-rules-evaluation-not-activated']")
           |> Enum.count() == 0
  end

  defp scope do
    Scope.for_user(%{
      id: "00000000-0000-0000-0000-000000000001",
      email: "operator@example.com",
      role: :admin,
      timezone: "Etc/UTC"
    })
  end

  defp log_live_alerts_assigns(alert_evaluation_mode) do
    %{
      flash: %{},
      current_scope: scope(),
      active_tab: "alerts",
      alert_evaluation_mode: alert_evaluation_mode,
      tab_loading: false,
      logs: [],
      traces: [],
      metrics: [],
      events: [],
      alerts: [],
      netflows: [],
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
      netflow_summary: %{total: 0, tcp: 0, udp: 0, other: 0, total_bytes: 0},
      trace_stats: %{total: 0, error_traces: 0, slow_traces: 0},
      trace_latency: %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, service_count: 0, sample_size: 0},
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
      service_picker: ServiceRadarWebNGWeb.Components.ServicePicker.initial_state(),
      selected_netflow: nil,
      netflow_context: nil,
      netflow_arin_lookup: %{},
      netflow_top_talkers: [],
      netflow_top_ports: [],
      netflow_timeseries: %{bucket_seconds: 300, points: []},
      netflow_timeseries_compare: %{bucket_seconds: 300, points: []},
      netflow_timeseries_stacked: %{bucket_seconds: 300, points: []},
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
      netflow_view: "overview",
      limit: 25,
      streams: %{logs: [], events: []},
      srql: %{enabled: true, page_path: "/observability/alerts", query: "in:alerts", pagination: %{}}
    }
  end

  defp rules_live_alerts_assigns(alert_evaluation_mode) do
    %{
      flash: %{},
      current_scope: scope(),
      active_tab: "alerts",
      alert_evaluation_mode: alert_evaluation_mode,
      zen_rules: [],
      event_rules: [],
      stateful_rules: [],
      show_stateful_rule_editor: false,
      editing_stateful_rule: nil,
      stateful_rule_error: nil,
      stateful_rule_form: %{},
      show_rule_builder: false,
      editing_rule: nil,
      settings_active_view: nil,
      settings_active_category: nil,
      settings_breadcrumbs: [],
      settings_nav_tree: %{categories: [], groups: []},
      settings_palette: [],
      settings_stats: []
    }
  end
end

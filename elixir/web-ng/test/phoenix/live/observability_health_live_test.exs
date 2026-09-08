defmodule ServiceRadarWebNGWeb.ObservabilityHealthLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    old_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.SRQLStub)
    Application.put_env(:serviceradar_web_ng, :observability_health_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :observability_health_test_pid)

      if is_nil(old_srql_module) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old_srql_module)
      end
    end)

    :ok
  end

  @doc false
  def notify_skipped_query(query) do
    case Application.get_env(:serviceradar_web_ng, :observability_health_test_pid) do
      pid when is_pid(pid) -> send(pid, {:skipped_query_executed, query})
      _ -> :ok
    end
  end

  test "renders fleet observability health from anomaly and capacity sources", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/health")
    html = render_async(view, 5_000)

    assert html =~ "Observability Health"
    assert html =~ "Anomaly findings"
    assert html =~ "At-risk capacity"
    assert html =~ "Capacity Runway"
    assert html =~ "Interface utilization anomaly"
    assert html =~ "WAN uplink"
    assert html =~ "Projected"
    refute html =~ "Impossible disk"
    refute html =~ "Negative disk"
    refute html =~ "No runway disk"
    assert has_element?(view, "a[href='/observability/health']", "Health")
    assert has_element?(view, "a[href*='has_exhaustion%3Atrue']", "Open SRQL")
    assert has_element?(view, "a[href*='status%3Aprojected']", "Open SRQL")
    refute html =~ "at_risk%2Cexhaustion_projected"
    assert has_element?(view, "a[href*='event_type%3A%28anomaly%2Canomaly_detection%29']", "Open events")

    assert html =~ "3 series skipped in last 24h (top: no_projected_exhaustion 2, trend_not_significant 1)"
  end

  test "hides the skipped-series summary when no series were skipped", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.SRQLStubNoSkips)

    {:ok, view, _html} = live(conn, ~p"/observability/health")
    html = render_async(view, 5_000)

    assert html =~ "Capacity Runway"
    refute html =~ "series skipped in last 24h"
    # The runway table is small, so the skipped query still runs.
    assert_received {:skipped_query_executed, "in:capacity_forecasts status:skipped" <> _rest}
  end

  test "does not run the skipped-series query when the runway table is large", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.SRQLStubLargeRunwayNoSkips)

    {:ok, view, _html} = live(conn, ~p"/observability/health")
    html = render_async(view, 5_000)

    assert html =~ "Capacity Runway"
    assert html =~ "WAN uplink 5"
    refute html =~ "series skipped in last 24h"
    refute_received {:skipped_query_executed, _query}
  end

  defmodule SRQLStub do
    @moduledoc false

    def query("in:events event_type:(anomaly,anomaly_detection)" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "time" => "2026-06-13T10:00:00Z",
             "severity" => "High",
             "source_type" => "anomaly_detection",
             "finding_title" => "Interface utilization anomaly",
             "device" => %{"name" => "edge-rtr-1"}
           }
         ]
       }}
    end

    def query("in:events rollup_stats:anomaly_findings" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{"total" => 2, "anomalies" => 1, "at_risk" => 1, "critical" => 0, "high" => 1}
         ]
       }}
    end

    def query("in:capacity_forecasts status:skipped" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "forecasted_at" => "2026-06-13T09:30:00Z",
             "resource_id" => "dev-1",
             "resource_key" => "disk:/",
             "metric_name" => "disk.used_percent",
             "status" => "skipped",
             "skip_reason" => "no_projected_exhaustion"
           },
           # Second run for the same series must not double-count.
           %{
             "forecasted_at" => "2026-06-13T08:30:00Z",
             "resource_id" => "dev-1",
             "resource_key" => "disk:/",
             "metric_name" => "disk.used_percent",
             "status" => "skipped",
             "skip_reason" => "no_projected_exhaustion"
           },
           %{
             "forecasted_at" => "2026-06-13T09:30:00Z",
             "resource_id" => "dev-2",
             "resource_key" => "memory:host",
             "metric_name" => "memory.used_percent",
             "status" => "skipped",
             "skip_reason" => "no_projected_exhaustion"
           },
           %{
             "forecasted_at" => "2026-06-13T09:30:00Z",
             "resource_id" => "dev-3",
             "resource_key" => "cpu:host",
             "metric_name" => "cpu.usage_percent",
             "status" => "skipped",
             "skip_reason" => "trend_not_significant"
           }
         ]
       }}
    end

    def query("in:capacity_forecasts status:projected" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "forecasted_at" => "2026-06-13T09:00:00Z",
             "resource_key" => "interface:edge-rtr-1:wan",
             "resource_label" => "WAN uplink",
             "metric_name" => "ifHCOutOctets",
             "status" => "projected",
             "current_value" => 72.4,
             "projected_value" => 96.8,
             "exhaustion_threshold" => 95.0,
             "projected_exhaustion_at" => "2026-06-20T12:00:00Z"
           },
           %{
             "forecasted_at" => "2026-06-13T09:00:00Z",
             "resource_key" => "disk:bad-high",
             "resource_label" => "Impossible disk",
             "metric_name" => "usage_percent",
             "status" => "projected",
             "current_value" => 73.61,
             "projected_value" => 239.18,
             "exhaustion_threshold" => 80.0,
             "projected_exhaustion_at" => "2026-06-20T12:00:00Z",
             "metadata" => %{"forecast_value_unit" => "percent"}
           },
           %{
             "forecasted_at" => "2026-06-13T09:00:00Z",
             "resource_key" => "disk:bad-negative",
             "resource_label" => "Negative disk",
             "metric_name" => "usage_percent",
             "status" => "projected",
             "current_value" => 75.85,
             "projected_value" => -400.45,
             "exhaustion_threshold" => 80.0,
             "projected_exhaustion_at" => "2026-06-20T12:00:00Z",
             "metadata" => %{"forecast_value_unit" => "percent"}
           },
           %{
             "forecasted_at" => "2026-06-13T09:00:00Z",
             "resource_key" => "disk:no-runway",
             "resource_label" => "No runway disk",
             "metric_name" => "usage_percent",
             "status" => "projected",
             "current_value" => 75.85,
             "projected_value" => 70.45,
             "exhaustion_threshold" => 80.0,
             "projected_exhaustion_at" => nil,
             "metadata" => %{"forecast_value_unit" => "percent"}
           }
         ]
       }}
    end
  end

  defmodule SRQLStubNoSkips do
    @moduledoc false

    def query("in:capacity_forecasts status:skipped" <> _rest = query, _opts) do
      ServiceRadarWebNGWeb.ObservabilityHealthLiveTest.notify_skipped_query(query)
      {:ok, %{"results" => []}}
    end

    def query(query, opts), do: ServiceRadarWebNGWeb.ObservabilityHealthLiveTest.SRQLStub.query(query, opts)
  end

  defmodule SRQLStubLargeRunwayNoSkips do
    @moduledoc false

    def query("in:capacity_forecasts status:skipped" <> _rest = query, _opts) do
      ServiceRadarWebNGWeb.ObservabilityHealthLiveTest.notify_skipped_query(query)
      {:ok, %{"results" => []}}
    end

    def query("in:capacity_forecasts status:projected" <> _rest, _opts) do
      results =
        Enum.map(1..5, fn index ->
          %{
            "forecasted_at" => "2026-06-13T09:00:00Z",
            "resource_key" => "interface:edge-rtr-#{index}:wan",
            "resource_label" => "WAN uplink #{index}",
            "metric_name" => "ifHCOutOctets",
            "status" => "projected",
            "current_value" => 72.4,
            "projected_value" => 96.8,
            "exhaustion_threshold" => 95.0,
            "projected_exhaustion_at" => "2026-06-20T12:00:00Z"
          }
        end)

      {:ok, %{"results" => results}}
    end

    def query(query, opts), do: ServiceRadarWebNGWeb.ObservabilityHealthLiveTest.SRQLStub.query(query, opts)
  end
end

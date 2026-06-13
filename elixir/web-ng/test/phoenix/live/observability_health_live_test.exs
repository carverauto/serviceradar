defmodule ServiceRadarWebNGWeb.ObservabilityHealthLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    old_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.SRQLStub)

    on_exit(fn ->
      if is_nil(old_srql_module) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old_srql_module)
      end
    end)

    :ok
  end

  test "renders fleet observability health from anomaly and capacity sources", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/health")
    html = render(view)

    assert html =~ "Observability Health"
    assert html =~ "Anomaly findings"
    assert html =~ "At-risk capacity"
    assert html =~ "Capacity Runway"
    assert html =~ "Interface utilization anomaly"
    assert html =~ "WAN uplink"
    assert html =~ "Projected"
    assert has_element?(view, "a[href='/observability/health']", "Health")
    assert has_element?(view, "a[href*='in%3Acapacity_forecasts']", "Open SRQL")
    assert has_element?(view, "a[href*='source_type%3Aanomaly_detection']", "Open events")
  end

  defmodule SRQLStub do
    @moduledoc false

    def query("in:events source_type:anomaly_detection" <> _rest, _opts) do
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

    def query("in:events source_type:(anomaly_detection,capacity_forecasting)" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{"severity" => "High", "source_type" => "anomaly_detection"},
           %{"severity" => "Critical", "source_type" => "capacity_forecasting"}
         ]
       }}
    end

    def query("in:capacity_forecasts" <> _rest, _opts) do
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
           }
         ]
       }}
    end
  end
end

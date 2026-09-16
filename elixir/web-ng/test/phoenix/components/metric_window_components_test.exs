defmodule ServiceRadarWebNGWeb.MetricWindowComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.MetricWindowComponents
  alias ServiceRadarWebNGWeb.SRQL.Builder

  @moduletag :db_free

  test "renders all explicit presets and a UTC custom range form" do
    html =
      render_component(&MetricWindowComponents.metric_window_controls/1,
        id: "synthetic-window",
        range: "last_24h",
        event: "set_window",
        custom_event: "custom_window",
        custom_options: [{"CPU", "cpu"}, {"Memory", "memory"}]
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(LazyHTML.query(document, "button[phx-value-range]"), "phx-value-range") ==
             MetricWindowComponents.ranges()

    assert html =~ "Custom"
    assert html =~ "Start (UTC)"
    assert html =~ "End (UTC)"
    assert html =~ ~s(phx-submit="custom_window")
    assert html =~ ~s(value="memory")
  end

  test "validates ordered UTC input before creating an absolute SRQL token" do
    assert {:ok, "[2025-01-01T10:30:00Z,2025-01-02T10:30:00Z]"} =
             MetricWindowComponents.custom_range(%{"start" => "2025-01-01T10:30", "end" => "2025-01-02T10:30"})

    for {start_time, end_time} <- [
          {"bad", "2025-01-02T00:00"},
          {"2025-01-02T00:00", "2025-01-01T00:00"},
          {"2025-01-02T00:00", "2025-01-02T00:00"},
          {"2025-01-01T00:00:00+03:00", "2025-01-02T00:00"}
        ] do
      assert {:error, _} = MetricWindowComponents.custom_range(%{"start" => start_time, "end" => end_time})
    end
  end

  test "replaces only window and bucket while preserving quoted filters and lists" do
    query =
      ~s(in:timeseries_metrics device_id:"synthetic time:device" metric_name:["cpu_usage", "load"] note:'keep time:inside' TIME:last_1h timeframe:[2025-01-01T00:00:00Z, 2025-01-02T00:00:00Z] bucket:1m agg:avg series:metric_name limit:900)

    assert MetricWindowComponents.query_for_range(query, "last_90d") ==
             ~s(in:timeseries_metrics device_id:"synthetic time:device" metric_name:["cpu_usage", "load"] note:'keep time:inside' agg:avg series:metric_name limit:900 time:last_90d bucket:12h)

    assert Builder.with_time_range("in:flows src_ip:192.0.2.9 time:last_1h", "last_30d") ==
             "in:flows src_ip:192.0.2.9 time:last_30d"
  end
end

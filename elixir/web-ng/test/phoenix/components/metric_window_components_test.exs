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

  test "replaces only window and bucket while preserving quoted filters" do
    assert {:ok, custom} =
             MetricWindowComponents.custom_range(%{
               "start" => "2025-01-01T00:00",
               "end" => "2025-01-02T00:00"
             })

    query =
      ~s(in:timeseries_metrics device_id:"synthetic time:device" TIME:last_1h timeframe:#{custom} bucket:1m agg:avg series:metric_name limit:900)

    assert MetricWindowComponents.query_for_range(query, "last_90d") ==
             ~s(in:timeseries_metrics device_id:"synthetic time:device" agg:avg series:metric_name limit:900 time:last_90d bucket:12h)

    assert Builder.with_time_range(
             ~s(in:timeseries_metrics device_id:synthetic time:last_1h bucket:1m),
             custom
           ) == ~s(in:timeseries_metrics device_id:synthetic bucket:1m time:#{custom})

    assert Builder.with_time_range("in:flows src_ip:192.0.2.9 time:last_1h", "last_30d") ==
             "in:flows src_ip:192.0.2.9 time:last_30d"
  end

  test "a page can relabel the custom form and sees its absolute range as the active window" do
    range = "[2025-01-01T00:00:00Z,2025-01-08T00:00:00Z]"

    render = fn range ->
      render_component(&MetricWindowComponents.metric_window_controls/1,
        id: "synthetic-window",
        range: range,
        event: "set_window",
        custom_event: "custom_window",
        custom_submit_label: "Apply",
        custom_hint: "Show these charts for a specific period."
      )
    end

    custom = render.(range)
    assert custom =~ "Apply"
    assert custom =~ "Show these charts for a specific period."
    refute custom =~ "Open SRQL"
    assert summary_class(custom) =~ "font-semibold"

    refute summary_class(render.("last_24h")) =~ "font-semibold"
  end

  test "accepts only a well-formed, ordered absolute range" do
    assert MetricWindowComponents.absolute_range?("[2025-01-01T00:00:00Z,2025-01-08T00:00:00Z]")

    for range <- [
          "[2025-01-08T00:00:00Z,2025-01-01T00:00:00Z]",
          "[2025-01-01T00:00:00Z,2025-01-01T00:00:00Z]",
          "[2025-01-01T00:00:00Z,2025-01-08T00:00:00Z",
          "[2025-01-01T00:00:00Z]",
          "[2025-01-01T00:00:00Z,2025-01-08T00:00:00Z] limit:1",
          "[2025-01-01T00:00:00+03:00,2025-01-08T00:00:00Z]",
          "last_24h",
          "",
          nil,
          42
        ] do
      refute MetricWindowComponents.absolute_range?(range), "accepted #{inspect(range)}"
    end
  end

  defp summary_class(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("summary") |> LazyHTML.attribute("class") |> Enum.join(" ")
  end
end

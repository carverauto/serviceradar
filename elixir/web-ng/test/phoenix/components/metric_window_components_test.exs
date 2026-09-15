defmodule ServiceRadarWebNGWeb.MetricWindowComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceMetricsRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.MetricSectionComponents
  alias ServiceRadarWebNGWeb.DeviceLive.Show, as: DeviceShow
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query
  alias ServiceRadarWebNGWeb.InterfaceLive.MetricsQuery
  alias ServiceRadarWebNGWeb.InterfaceLive.Show, as: InterfaceShow
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

  test "sysmon Custom opens the selected server-owned query with device and metric context" do
    query =
      ~s(in:timeseries_metrics device_id:"synthetic-device" metric_type:sysmon metric_name:cpu_usage time:last_24h bucket:5m agg:avg)

    socket = socket(%{metric_sections: [%{key: "cpu", query: query}]})

    params = %{
      "window" => %{
        "start" => "2025-01-01T00:00",
        "end" => "2025-01-31T00:00",
        "metric" => "cpu",
        "query" => "in:devices"
      }
    }

    assert {:noreply, result} = DeviceShow.handle_event("sysmon_custom_range", params, socket)
    query = redirected_metrics_query(result)
    assert query =~ ~s(device_id:"synthetic-device")
    assert query =~ "metric_type:sysmon metric_name:cpu_usage"
    assert query =~ "time:[2025-01-01T00:00:00Z,2025-01-31T00:00:00Z] bucket:6h"
    refute query =~ "in:devices"
  end

  test "interface Custom preserves the interface and selected counter filters" do
    socket =
      socket(%{
        device_uid: "synthetic-device",
        interface: %{"if_index" => 7},
        settings: %{metrics_selected: ["ifInOctets"], metric_groups: []}
      })

    params = %{"window" => %{"start" => "2025-01-01T00:00", "end" => "2025-04-01T00:00"}}
    assert {:noreply, result} = InterfaceShow.handle_event("interface_custom_range", params, socket)
    query = redirected_metrics_query(result)
    assert query =~ ~s(device_id:"synthetic-device" if_index:7)
    assert query =~ ~s(metric_name:["ifHCInOctets","ifInOctets"])
    assert query =~ "agg:rate series:metric_name"
    assert query =~ "bucket:12h"
  end

  test "native translator accepts long and custom windows in both dialects with bound metric context" do
    windows = [{"last_30d", 30}, {"last_90d", 90}, {"[2025-01-01T00:00:00Z,2025-04-01T00:00:00Z]", 90}]

    for {range, days} <- windows, driver <- ["timescale", "pg_duckdb"] do
      bucket = Query.bucket_for_time_range(range)

      interface_query =
        MetricsQuery.build_snmp_counter_query("synthetic-device", 7, ["ifInOctets"], time_range: range, bucket: bucket)

      sysmon_query =
        Query.timeseries_metric_query("sysmon", "cpu_usage", [~s(device_id:"synthetic-device")], nil, 900,
          time_range: range,
          bucket: bucket
        )

      for query <- [interface_query, sysmon_query] do
        assert {:ok, json} =
                 Native.translate(query, 3600, nil, "next", nil, Jason.encode!(%{"timeseries_metrics" => driver}))

        translated = Jason.decode!(json)
        params = translated["params"]
        assert Enum.any?(params, &(&1["v"] == "synthetic-device"))
        assert translated["sql"] =~ "timestamp"
        if query == interface_query, do: assert(Enum.any?(params, &(&1["t"] == "int" and &1["v"] == 7)))
        [start_param, end_param | _] = Enum.filter(params, &(&1["t"] == "timestamptz"))
        {:ok, start_time, _} = DateTime.from_iso8601(start_param["v"])
        {:ok, end_time, _} = DateTime.from_iso8601(end_param["v"])
        assert DateTime.diff(end_time, start_time) == days * 86_400
      end
    end
  end

  test "native hybrid routing keeps the exact 30-day preset on the hot store" do
    drivers = Jason.encode!(%{"timeseries_metrics" => %{"driver" => "hybrid", "hot_window_days" => 30}})

    for {range, expected_store} <- [{"last_30d", "timescale"}, {"last_90d", "pg_duckdb"}] do
      query =
        MetricsQuery.build_snmp_counter_query("synthetic-device", 7, ["ifInOctets"], MetricsQuery.window_opts(range))

      assert {:ok, json} = Native.translate(query, 3600, nil, "next", nil, drivers)
      assert Jason.decode!(json)["read_store"] == expected_store
    end
  end

  test "sysmon loading and failure retain presets without exposing stale charts or Custom queries" do
    old_ref = make_ref()
    current_ref = make_ref()

    socket =
      socket(%{
        device_uid: "synthetic-window-device",
        sysmon_time_range: "last_7d",
        device_metrics_request_ref: current_ref,
        metrics_loading: true,
        metrics_error: nil,
        metric_sections: []
      })

    assert {:noreply, ^socket} =
             DeviceShow.handle_async({:device_metrics, "synthetic-window-device", old_ref}, {:exit, :timeout}, socket)

    assert DeviceMetricsRuntime.current_request?(socket, "synthetic-window-device", current_ref)

    loading_html =
      render_component(&MetricSectionComponents.metric_sections_content/1,
        sections: socket.assigns.metric_sections,
        loading: socket.assigns.metrics_loading,
        device_uid: socket.assigns.device_uid,
        time_range: socket.assigns.sysmon_time_range,
        timezone: "Etc/UTC"
      )

    assert loading_html =~ "sysmon-metrics-loading"
    assert loading_html =~ "sysmon-window-last_7d"
    refute loading_html =~ "sysmon-window-custom-form"
    refute loading_html =~ "last 24h"

    {:noreply, failed} =
      DeviceShow.handle_async({:device_metrics, "synthetic-window-device", current_ref}, {:exit, :timeout}, socket)

    assert failed.assigns.metric_sections == []
    refute failed.assigns.metrics_loading
    assert failed.assigns.device_metrics_request_ref == nil
    assert failed.assigns.metrics_error =~ "retry"

    error_html =
      render_component(&MetricSectionComponents.metric_sections_content/1,
        sections: failed.assigns.metric_sections,
        error: failed.assigns.metrics_error,
        device_uid: failed.assigns.device_uid,
        time_range: failed.assigns.sysmon_time_range,
        timezone: "Etc/UTC"
      )

    assert error_html =~ "sysmon-metrics-error"
    assert error_html =~ "sysmon-window-last_7d"
    refute error_html =~ "sysmon-window-custom-form"
    refute error_html =~ "last 24h"
  end

  test "interface metric results cannot replace a newer window or a newer settings request" do
    old_ref = make_ref()
    current_ref = make_ref()
    pending = %{panels: [], error: nil, message: nil}
    socket = socket(%{metrics_request_ref: current_ref, metrics_loading: true, metrics: pending})
    old_metrics = %{panels: [%{id: "old-window"}], error: nil, message: nil}

    assert {:noreply, ^socket} = InterfaceShow.handle_async({:interface_metrics, old_ref}, {:ok, old_metrics}, socket)
    assert {:noreply, ^socket} = InterfaceShow.handle_async({:interface_metrics, old_ref}, {:exit, :cancelled}, socket)

    current_metrics = %{panels: [%{id: "current-window"}], error: nil, message: nil}

    assert {:noreply, ready} =
             InterfaceShow.handle_async({:interface_metrics, current_ref}, {:ok, current_metrics}, socket)

    assert ready.assigns.metrics == current_metrics
    refute ready.assigns.metrics_loading
    assert ready.assigns.metrics_request_ref == nil
    assert {:noreply, ^ready} = InterfaceShow.handle_async({:interface_metrics, old_ref}, {:ok, old_metrics}, ready)
  end

  test "failed interface metric task exits the loading state and permits retry" do
    request_ref = make_ref()
    socket = socket(%{metrics_request_ref: request_ref, metrics_loading: true})
    assert {:noreply, result} = InterfaceShow.handle_async({:interface_metrics, request_ref}, {:exit, :timeout}, socket)
    refute result.assigns.metrics_loading
    assert result.assigns.metrics.panels == []
    assert result.assigns.metrics.error =~ "retry"
    assert result.assigns.metrics_request_ref == nil
  end

  defp socket(assigns) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp redirected_metrics_query(%Socket{redirected: {:live, :redirect, %{to: "/observability/metrics?" <> query}}}),
    do: URI.decode_query(query)["q"]
end

defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetricsTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries, as: TimeseriesPlugin
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics

  @moduletag :db_free

  defmodule RecordingSRQLStub do
    @moduledoc false

    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})
    def query(_query), do: {:error, :invalid_query}

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    @impl true
    def query(query, opts) when is_binary(query) do
      responder = Application.fetch_env!(:serviceradar_web_ng, :sysmon_metrics_test_responder)
      responder.(query, opts)
    end
  end

  test "CPU section renders overall utilization plus top-core drilldown" do
    previous_responder = Application.get_env(:serviceradar_web_ng, :sysmon_metrics_test_responder)
    now = DateTime.truncate(DateTime.utc_now(), :second)
    older = DateTime.add(now, -300, :second)

    Application.put_env(:serviceradar_web_ng, :sysmon_metrics_test_responder, fn query, _opts ->
      cond do
        String.contains?(query, ~s|metric_type:"sysmon.cpu"|) and String.contains?(query, "series:core_id") ->
          assert query =~ "bucket:5m"
          assert query =~ "agg:max"
          assert query =~ "series:core_id"
          assert query =~ ~s|device_id:"sysmon-core-test"|
          assert query =~ "limit:20000"

          {:ok,
           %{
             "results" =>
               [
                 %{
                   "timestamp" => DateTime.to_iso8601(now),
                   "value" => 42.4,
                   "core_id" => 0
                 },
                 %{
                   "timestamp" => DateTime.to_iso8601(now),
                   "value" => 91.2,
                   "core_id" => 1
                 },
                 %{
                   "timestamp" => DateTime.to_iso8601(older),
                   "value" => 99.9,
                   "core_id" => 0
                 }
               ] ++
                 Enum.map(2..7, fn core_id ->
                   %{
                     "timestamp" => DateTime.to_iso8601(now),
                     "value" => 10.0 + core_id,
                     "core_id" => core_id
                   }
                 end),
             "pagination" => %{}
           }}

        String.contains?(query, ~s|metric_type:"sysmon.cpu"|) ->
          assert query =~ "bucket:5m"
          assert query =~ "agg:avg"
          refute query =~ "series:core_id"
          assert query =~ ~s|device_id:"sysmon-core-test"|
          assert query =~ "limit:300"

          {:ok,
           %{
             "results" => [
               %{
                 "timestamp" => DateTime.to_iso8601(older),
                 "value" => 25.0
               },
               %{
                 "timestamp" => DateTime.to_iso8601(now),
                 "value" => 33.3
               }
             ],
             "pagination" => %{}
           }}

        String.contains?(query, "in:timeseries_metrics") ->
          {:ok, %{"results" => [], "pagination" => %{}}}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}}}
      end
    end)

    on_exit(fn ->
      restore_env(:sysmon_metrics_test_responder, previous_responder)
    end)

    [cpu | _] =
      SysmonMetrics.load_metric_sections(
        RecordingSRQLStub,
        [~s|device_id:"sysmon-core-test"|],
        :scope,
        thresholds: %{"cpu_warning" => "80", "cpu_critical" => "95"}
      )

    assert cpu.key == "cpu"
    assert cpu.subtitle == "last 24h · 5m buckets · overall + top 6 of 8 cores by max"
    assert cpu.query =~ "agg:avg"
    refute cpu.query =~ "series:core_id"
    assert cpu.query =~ "limit:300"
    assert cpu.header_value == 33.3
    assert cpu.header_stats == %{min: 25.0, max: 33.3, avg: 29.15}

    timeseries_panels = Enum.filter(cpu.panels, &(&1.plugin == TimeseriesPlugin))
    assert length(timeseries_panels) == 2

    [overall_panel, core_panel] = timeseries_panels
    assert MapSet.new(overall_panel.assigns.series_points, &elem(&1, 0)) == MapSet.new(["Overall utilization"])
    refute Map.get(core_panel.assigns, :combine_all_series, false)
    assert core_panel.assigns.compact_title == "Top cores"

    displayed_cores = MapSet.new(core_panel.assigns.series_points, &elem(&1, 0))
    assert displayed_cores == MapSet.new(~w(0 1 4 5 6 7))

    assert %{
             value: 95.0,
             label: "CPU critical",
             severity: :critical,
             series: nil
           } in core_panel.assigns.reference_lines

    assert %{
             value: 80.0,
             label: "CPU warning",
             severity: :warning,
             series: nil
           } in core_panel.assigns.reference_lines
  end

  test "metric sections honor a caller-provided absolute time range" do
    previous_responder = Application.get_env(:serviceradar_web_ng, :sysmon_metrics_test_responder)

    Application.put_env(:serviceradar_web_ng, :sysmon_metrics_test_responder, fn query, _opts ->
      if String.contains?(query, "in:timeseries_metrics") do
        assert query =~ "time:[2026-06-26T06:30:00Z,2026-06-26T08:30:00Z]"
        assert query =~ "bucket:1m"
        send(self(), {:detail_metric_query, query})
      end

      {:ok, %{"results" => [], "pagination" => %{}}}
    end)

    on_exit(fn ->
      restore_env(:sysmon_metrics_test_responder, previous_responder)
    end)

    sections =
      SysmonMetrics.load_metric_sections(
        RecordingSRQLStub,
        [~s|device_id:"sysmon-detail-test"|],
        :scope,
        time_range: "[2026-06-26T06:30:00Z,2026-06-26T08:30:00Z]",
        bucket: "1m",
        window_label: "around Jun 26 07:30 UTC"
      )

    assert Enum.map(sections, & &1.subtitle) == [
             "around Jun 26 07:30 UTC · overall utilization",
             "around Jun 26 07:30 UTC · used percent",
             "around Jun 26 07:30 UTC · used percent"
           ]
  end

  test "CPU section attributes a failed per-core query to the core response" do
    previous_responder = Application.get_env(:serviceradar_web_ng, :sysmon_metrics_test_responder)

    Application.put_env(:serviceradar_web_ng, :sysmon_metrics_test_responder, fn query, _opts ->
      cond do
        String.contains?(query, ~s|metric_type:"sysmon.cpu"|) and String.contains?(query, "series:core_id") ->
          {:error, :statement_timeout}

        String.contains?(query, ~s|metric_type:"sysmon.cpu"|) ->
          {:ok, %{"results" => [%{"timestamp" => "2026-07-18T04:05:00Z", "value" => 12.5}]}}

        true ->
          {:ok, %{"results" => []}}
      end
    end)

    on_exit(fn ->
      restore_env(:sysmon_metrics_test_responder, previous_responder)
    end)

    [cpu | _] =
      SysmonMetrics.load_metric_sections(
        RecordingSRQLStub,
        [~s|device_id:"sysmon-core-timeout"|],
        :scope
      )

    assert cpu.error == "CPU core SRQL error: :statement_timeout"
    refute cpu.error =~ "unexpected CPU overall"
  end

  test "process metrics carry a per-process CPU history series for sparklines" do
    previous_responder = Application.get_env(:serviceradar_web_ng, :sysmon_metrics_test_responder)
    now = DateTime.truncate(DateTime.utc_now(), :second)
    # Several CPU samples spread across the window for one process so the
    # sparkline has a real history series; a single latest-only sample (the
    # pre-§31.1 behavior) hides process spikes.
    cpu_offsets_values = [{-480, 5.0}, {-360, 22.0}, {-240, 41.0}, {-120, 13.0}, {0, 64.0}]

    Application.put_env(:serviceradar_web_ng, :sysmon_metrics_test_responder, fn query, _opts ->
      cond do
        String.contains?(query, ~s|metric_name:"process.cpu_usage"|) ->
          cpu_rows =
            Enum.map(cpu_offsets_values, fn {offset, value} ->
              dt = now |> DateTime.add(offset, :second) |> DateTime.truncate(:second)

              %{
                "timestamp" => DateTime.to_iso8601(dt),
                "value" => value,
                "tags" => %{"pid" => "4242", "name" => "nginx", "status" => "Running"}
              }
            end)

          {:ok, %{"results" => cpu_rows, "pagination" => %{}}}

        String.contains?(query, ~s|metric_name:"process.memory_usage"|) ->
          {:ok,
           %{
             "results" => [
               %{
                 "timestamp" => DateTime.to_iso8601(now),
                 "value" => 1_048_576,
                 "tags" => %{"pid" => "4242", "name" => "nginx", "status" => "Running"}
               }
             ],
             "pagination" => %{}
           }}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}}}
      end
    end)

    on_exit(fn ->
      restore_env(:sysmon_metrics_test_responder, previous_responder)
    end)

    [row] =
      SysmonMetrics.load_process_metrics(
        RecordingSRQLStub,
        [~s|device_id:"sysmon-process-sparkline-test"|],
        :scope
      )

    assert Map.get(row, "name") == "nginx"
    assert Map.get(row, "pid") == "4242"

    # The latest CPU sample is retained as the headline value…
    assert parse_number(Map.get(row, "cpu_usage")) == 64.0
    # …and the full history series is attached for the sparkline, time-sorted
    # ascending so the line renders oldest → newest.
    sparkline = Map.get(row, "_cpu_sparkline")
    assert is_list(sparkline) and length(sparkline) == 5
    assert Enum.map(sparkline, &elem(&1, 1)) == [5.0, 22.0, 41.0, 13.0, 64.0]

    unix_list = Enum.map(sparkline, fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)
    assert unix_list == Enum.sort(unix_list)
  end

  test "anomaly annotations prefer the edge episode peak time over the emitted finding time" do
    start_dt = ~U[2026-06-19 12:01:00Z]
    peak_dt = ~U[2026-06-19 12:03:00Z]
    end_dt = ~U[2026-06-19 12:08:00Z]

    section = %{
      key: "cpu",
      panels: [
        %{
          id: "cpu",
          assigns: %{series_points: [{"usage_percent", []}]}
        }
      ]
    }

    row = %{
      "time" => "2026-06-19T12:05:00Z",
      "severity" => "High",
      "metric_name" => "cpu.usage_percent",
      "message" => "CPU saturation anomaly",
      "anomaly_disposition" => %{"action" => "escalate"},
      "metadata" => %{
        "finding_info" => %{
          "dimensions" => %{
            "episode_started_at_unix_nano" => DateTime.to_unix(start_dt, :nanosecond),
            "episode_ended_at_unix_nano" => DateTime.to_unix(end_dt, :nanosecond),
            "episode_peak_at_unix_nano" => DateTime.to_unix(peak_dt, :nanosecond)
          }
        },
        "source_identity" => %{"series_key" => "sysmon.cpu:host:CPU1"}
      }
    }

    [%{panels: [%{assigns: assigns}]}] =
      SysmonMetrics.annotate_metric_sections([section], %{anomaly_rows: [row]}, row)

    assert [
             %{
               dt: selected_dt,
               start_dt: selected_start_dt,
               end_dt: selected_end_dt,
               label: "Selected peak: CPU saturation anomaly",
               severity: "High",
               series: nil
             },
             %{
               dt: row_dt,
               start_dt: row_start_dt,
               end_dt: row_end_dt,
               label: "Peak: CPU saturation anomaly",
               severity: "High",
               series: nil
             }
           ] = assigns.annotations

    assert DateTime.compare(selected_dt, peak_dt) == :eq
    assert DateTime.compare(row_dt, peak_dt) == :eq
    assert DateTime.compare(selected_start_dt, start_dt) == :eq
    assert DateTime.compare(row_start_dt, start_dt) == :eq
    assert DateTime.compare(selected_end_dt, end_dt) == :eq
    assert DateTime.compare(row_end_dt, end_dt) == :eq
  end

  test "anomaly annotations fall back to emitted finding time without episode peak metadata" do
    section = %{
      key: "cpu",
      panels: [
        %{
          id: "cpu",
          assigns: %{series_points: [{"avg", []}]}
        }
      ]
    }

    row = %{
      "time" => "2026-06-19T12:05:00Z",
      "severity" => "warning",
      "metric_name" => "cpu.usage_percent",
      "message" => "CPU saturation anomaly",
      "anomaly_disposition" => %{"action" => "escalate"},
      "metadata" => %{
        "source_identity" => %{"series_key" => "sysmon.cpu:host:CPU1"}
      }
    }

    [%{panels: [%{assigns: assigns}]}] =
      SysmonMetrics.annotate_metric_sections([section], %{anomaly_rows: [row]})

    assert [
             %{
               dt: ~U[2026-06-19 12:05:00Z],
               label: "CPU saturation anomaly",
               series: nil
             }
           ] = assigns.annotations
  end

  test "CPU annotations ignore edge-only findings without central escalation" do
    section = %{
      key: "cpu",
      panels: [
        %{
          id: "cpu",
          assigns: %{series_points: [{"avg", []}]}
        }
      ]
    }

    row = %{
      "time" => "2026-06-19T12:05:00Z",
      "severity" => "warning",
      "metric_name" => "cpu.usage_percent",
      "message" => "CPU edge spike without central disposition",
      "metadata" => %{
        "source_identity" => %{"series_key" => "sysmon.cpu:host:CPU1"}
      }
    }

    [%{panels: [%{assigns: assigns}]}] =
      SysmonMetrics.annotate_metric_sections([section], %{anomaly_rows: [row]})

    assert Map.get(assigns, :annotations, []) == []
  end

  defp parse_number(value) when is_number(value), do: value * 1.0
  defp parse_number(_), do: nil

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end

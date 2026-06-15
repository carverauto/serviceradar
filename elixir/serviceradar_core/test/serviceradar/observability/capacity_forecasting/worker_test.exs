defmodule ServiceRadar.Observability.CapacityForecasting.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.CapacityForecasting.Source
  alias ServiceRadar.Observability.CapacityForecasting.Worker

  @forecasted_at ~U[2026-06-12 12:00:00Z]

  setup do
    AnomalyConfigRuntime.clear_cache_for_test()

    on_exit(fn ->
      AnomalyConfigRuntime.clear_cache_for_test()
    end)
  end

  defmodule Runner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(query, _opts) do
      send(self(), {:capacity_forecast_query, query})

      rows =
        for hour <- 0..47 do
          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "host_id" => "host-a",
            "avg_usage_percent" => 20.0 + hour
          }
        end

      {:ok, rows}
    end
  end

  defmodule RecentRunner do
    @moduledoc false
    @start ~U[2026-06-10 13:00:00Z]

    def query(query, _opts) do
      send(self(), {:capacity_forecast_query, query})

      rows =
        for hour <- 0..47 do
          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "host_id" => "host-a",
            "avg_usage_percent" => 20.0 + hour
          }
        end

      {:ok, rows}
    end
  end

  defmodule PagedRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query_page(query, opts) do
      cursor = Keyword.get(opts, :cursor)
      send(self(), {:capacity_forecast_query_page, query, cursor})

      case cursor do
        nil ->
          {:ok, %{rows: rows("device-a", 0..23), next_cursor: "page-2"}}

        "page-2" ->
          {:ok, %{rows: rows("device-b", 0..23), next_cursor: nil}}
      end
    end

    defp rows(device_id, hours) do
      for hour <- hours do
        %{
          "bucket" => DateTime.add(@start, hour * 3_600, :second),
          "device_id" => device_id,
          "host_id" => "#{device_id}-host",
          "avg_usage_percent" => 20.0 + hour
        }
      end
    end
  end

  defmodule VerdictEmitter do
    @moduledoc false

    def emit(attrs, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:capacity_forecast_verdict, attrs})
      :ok
    end
  end

  defmodule FailingVerdictEmitter do
    @moduledoc false

    def emit(attrs, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:capacity_forecast_verdict_attempt, attrs})
      {:error, {:nats_not_connected, :reconnecting}}
    end
  end

  test "worker reads aggregate history through SRQL and upserts projected forecasts" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query:
        "in:cpu_metrics time:last_180d bucket:1h stats:avg(usage_percent) as avg_usage_percent",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 100.0,
      model: "linear"
    }

    upsert_fun = fn attrs, actor ->
      send(self(), {:capacity_forecast_upsert, attrs, actor})
      {:ok, attrs}
    end

    job = %Oban.Job{
      args: %{"trigger" => "cron"},
      inserted_at: @forecasted_at,
      scheduled_at: @forecasted_at
    }

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: Runner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_query, query}
    assert query =~ "in:cpu_metrics"
    assert query =~ "bucket:1h"

    assert_received {:capacity_forecast_upsert, attrs, %{role: :system}}
    assert attrs.forecasted_at == @forecasted_at
    assert attrs.resource_key == "cpu_usage:device-a:host-a"
    assert attrs.resource_type == "cpu"
    assert attrs.resource_id == "device-a"
    assert attrs.resource_label == "host-a / device-a"
    assert attrs.metric_class == "cpu"
    assert attrs.metric_name == "usage_percent"
    assert attrs.status == "projected"
    assert attrs.projected_value > attrs.current_value
    assert attrs.projected_exhaustion_at
    assert attrs.metadata["query"] == source.query
  end

  test "worker pages capacity history instead of truncating at the first SRQL limit page" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query:
        "in:cpu_metrics time:last_180d bucket:1h stats:avg(usage_percent) as avg_usage_percent by bucket,device_id,host_id sort:bucket:desc limit:2",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 100.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_upsert, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{
      args: %{"trigger" => "cron"},
      inserted_at: @forecasted_at,
      scheduled_at: @forecasted_at
    }

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: PagedRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_query_page, _query, nil}
    assert_received {:capacity_forecast_query_page, _query, "page-2"}

    assert_received {:capacity_forecast_upsert,
                     %{resource_key: "cpu_usage:device-a:device-a-host"}}

    assert_received {:capacity_forecast_upsert,
                     %{resource_key: "cpu_usage:device-b:device-b-host"}}
  end

  test "worker records skipped forecasts for insufficient history" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 100.0
    }

    runner = __MODULE__.ShortRunner

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_skip, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: runner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               min_points: 3
             )

    assert_received {:capacity_forecast_skip, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "insufficient_history"
    assert attrs.sample_count == 2
    assert attrs.window_started_at == ~U[2026-06-01 00:00:00Z]
    assert attrs.window_ended_at == ~U[2026-06-01 01:00:00Z]
    assert attrs.slope_per_second == nil
  end

  test "skipped forecast windows are stable when SRQL returns newest buckets first" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h sort:bucket:desc",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 100.0
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_skip, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: __MODULE__.DescShortRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               min_points: 3
             )

    assert_received {:capacity_forecast_skip, attrs}
    assert attrs.status == "skipped"
    assert attrs.window_started_at == ~U[2026-06-01 00:00:00Z]
    assert attrs.window_ended_at == ~U[2026-06-01 01:00:00Z]
  end

  test "worker merges hot-reloaded forecast settings into each run" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      capacity_forecasting_opts: [
        horizon_seconds: 12 * 3_600,
        warning_horizon_seconds: 6 * 3_600,
        warning_threshold_percent: 75.0,
        forecast_model: "linear",
        min_points: 24,
        capacity_metric_class_overrides: %{
          "cpu" => %{"minimum_history_points" => 30}
        }
      ]
    })

    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query:
        "in:cpu_metrics time:last_180d bucket:1h stats:avg(usage_percent) as avg_usage_percent",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 100.0,
      model: "auto"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_runtime_config, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{
      args: %{"trigger" => "cron"},
      inserted_at: @forecasted_at,
      scheduled_at: @forecasted_at
    }

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: Runner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false
             )

    assert_received {:capacity_forecast_runtime_config, attrs}
    assert attrs.horizon_seconds == 12 * 3_600
    assert attrs.horizon_ends_at == DateTime.add(@forecasted_at, 12 * 3_600, :second)
    assert attrs.exhaustion_threshold == 75.0
    assert attrs.model == "linear"
  end

  test "runtime default forecast settings preserve source model" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      capacity_forecasting_opts: [
        horizon_seconds: 12 * 3_600,
        warning_horizon_seconds: 6 * 3_600,
        warning_threshold_percent: 75.0,
        min_points: 24,
        capacity_metric_class_overrides: %{}
      ]
    })

    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query:
        "in:cpu_metrics time:last_180d bucket:1h stats:avg(usage_percent) as avg_usage_percent",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 100.0,
      model: "holt_winters"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_runtime_auto_model, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{
      args: %{"trigger" => "cron"},
      inserted_at: @forecasted_at,
      scheduled_at: @forecasted_at
    }

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: Runner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false
             )

    assert_received {:capacity_forecast_runtime_auto_model, attrs}
    assert attrs.exhaustion_threshold == 75.0
    assert attrs.model == "holt_winters_additive"
  end

  test "default sources cover long-horizon resource, interface, and flow aggregates" do
    sources = Source.defaults()
    queries = Enum.map(sources, & &1.query)

    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.memory"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.disk"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_name:"process.count"|))
    assert Enum.any?(queries, &String.contains?(&1, "in:timeseries_metric_interface_hourly"))
    assert Enum.any?(queries, &String.contains?(&1, "in:flows"))
    refute Enum.any?(sources, &(&1.name == "timeseries_value"))

    cpu_source = Enum.find(sources, &(&1.name == "cpu_usage"))
    assert cpu_source.value_field == "value"
    assert cpu_source.bucket_field == "timestamp"
    assert cpu_source.key_fields == ["series"]

    interface_source = Enum.find(sources, &(&1.resource_type == "interface"))
    assert interface_source.metric_name == "utilization_percent"
    assert interface_source.threshold == 100.0
  end

  test "interface forecasts convert byte rates to utilization percent using live speed" do
    source = interface_source()

    resolver = fn row, _opts ->
      send(self(), {:interface_capacity_row, row})

      {:ok,
       %{
         speed_bps: 10_000_000,
         source: "discovered_interfaces",
         timestamp: @forecasted_at
       }}
    end

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_interface, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: __MODULE__.InterfaceRunner,
               interface_capacity_resolver: resolver,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:interface_capacity_row, %{"if_index" => 7}}
    assert_received {:capacity_forecast_interface, attrs}

    assert attrs.metric_name == "utilization_percent"
    assert attrs.exhaustion_threshold == 100.0
    assert attrs.status == "projected"
    assert_in_delta attrs.current_value, 11.76, 0.01
    assert attrs.projected_value > attrs.current_value
    assert attrs.metadata["capacity_bps"] == 10_000_000
    assert attrs.metadata["forecast_value_unit"] == "percent"
    assert attrs.metadata["raw_value_unit"] == "bytes_per_second"
  end

  test "interface forecasts drop SNMP counter-wrap spikes instead of projecting impossible utilization" do
    source = interface_source()

    resolver = fn _row, _opts ->
      {:ok, %{speed_bps: 10_000_000, source: "discovered_interfaces", timestamp: @forecasted_at}}
    end

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_interface, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: __MODULE__.InterfaceWrapRunner,
               interface_capacity_resolver: resolver,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_interface, attrs}

    # With the wrap sample dropped, the projection stays in the real ~10% range — never an
    # 8e8% value, and no millennia-out / past-dated exhaustion.
    assert attrs.status == "projected"
    assert attrs.projected_value < 100.0
    assert attrs.current_value < 100.0
  end

  test "interface forecasts are skipped when live speed is missing" do
    source = interface_source()
    resolver = fn _row, _opts -> {:ok, nil} end

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_interface_skip, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: __MODULE__.InterfaceRunner,
               interface_capacity_resolver: resolver,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               min_points: 24
             )

    assert_received {:capacity_forecast_interface_skip, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "missing_interface_capacity"
    assert attrs.sample_count == 48
    assert attrs.current_value == nil
    assert attrs.metadata["capacity_skip_reason"] == "missing_interface_capacity"
  end

  test "interface forecasts are skipped when matched live speed is not positive" do
    source = interface_source()
    resolver = fn _row, _opts -> {:ok, %{speed_bps: nil, source: "discovered_interfaces"}} end

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_interface_skip, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: __MODULE__.InterfaceRunner,
               interface_capacity_resolver: resolver,
               upsert_fun: upsert_fun,
               min_points: 24
             )

    assert_received {:capacity_forecast_interface_skip, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "missing_interface_capacity"
    assert attrs.sample_count == 48
    assert attrs.current_value == nil
    assert attrs.metadata["capacity_skip_reason"] == "missing_interface_capacity"
  end

  test "interface forecasts skip non-octet metrics instead of converting packets to percent" do
    source = interface_source()

    resolver = fn _row, _opts ->
      flunk("capacity resolver should not run for non-octet interface metrics")
    end

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_interface_skip, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: __MODULE__.InterfacePacketRunner,
               interface_capacity_resolver: resolver,
               upsert_fun: upsert_fun,
               min_points: 24
             )

    assert_received {:capacity_forecast_interface_skip, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "unsupported_interface_metric"
    assert attrs.metric_name == "utilization_percent"
    assert attrs.resource_key =~ "ifHCInUcastPkts"
    assert attrs.resource_label =~ "ifHCInUcastPkts"
    assert attrs.current_value == nil
    assert attrs.metadata["capacity_skip_reason"] == "unsupported_interface_metric"
  end

  test "worker returns an error when forecast persistence fails" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query: "in:cpu_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id"],
      threshold: 100.0
    }

    upsert_fun = fn _attrs, _actor -> {:error, :db_down} end
    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert {:error, :db_down} =
             Worker.run(job,
               sources: [source],
               runner: Runner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               min_points: 24
             )
  end

  test "worker emits a causal capacity forecast verdict for at-risk projections" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query: "in:cpu_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 100.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor -> {:ok, attrs} end
    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: Runner,
               upsert_fun: upsert_fun,
               verdict_emitter: VerdictEmitter,
               test_pid: self(),
               horizon_seconds: 24 * 3_600,
               warning_horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_verdict, attrs}
    assert attrs.status == "projected"
    assert attrs.projected_exhaustion_at
    assert DateTime.compare(attrs.projected_exhaustion_at, attrs.horizon_ends_at) != :gt
  end

  test "worker keeps persisted forecasts when verdict emission fails" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query: "in:cpu_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 100.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_upsert, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    log =
      capture_log(fn ->
        assert :ok =
                 Worker.run(job,
                   sources: [source],
                   runner: Runner,
                   upsert_fun: upsert_fun,
                   verdict_emitter: FailingVerdictEmitter,
                   test_pid: self(),
                   horizon_seconds: 24 * 3_600,
                   warning_horizon_seconds: 24 * 3_600,
                   min_points: 24
                 )
      end)

    assert_received {:capacity_forecast_upsert, %{status: "projected"}}
    assert_received {:capacity_forecast_verdict_attempt, %{status: "projected"}}
    assert log =~ "Capacity forecast verdict emit failed"
    assert log =~ "nats_not_connected"
  end

  test "worker emits an inactive verdict for projections outside the warning horizon" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query: "in:cpu_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 100.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_outside_warning, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: RecentRunner,
               upsert_fun: upsert_fun,
               verdict_emitter: VerdictEmitter,
               test_pid: self(),
               horizon_seconds: 48 * 3_600,
               warning_horizon_seconds: 60,
               min_points: 24
             )

    assert_received {:capacity_forecast_outside_warning, attrs}
    assert attrs.status == "projected"
    assert attrs.projected_exhaustion_at
    assert_received {:capacity_forecast_verdict, verdict_attrs}
    assert verdict_attrs.status == "inactive"
    assert verdict_attrs.resource_key == attrs.resource_key
  end

  test "worker emits a skipped verdict to clear stale capacity evidence" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 100.0
    }

    upsert_fun = fn attrs, _actor -> {:ok, attrs} end
    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: __MODULE__.ShortRunner,
               upsert_fun: upsert_fun,
               verdict_emitter: VerdictEmitter,
               test_pid: self(),
               min_points: 3
             )

    assert_received {:capacity_forecast_verdict, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason
  end

  defmodule ShortRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      {:ok,
       [
         %{
           "bucket" => @start,
           "device_id" => "device-a",
           "mount_point" => "/",
           "avg_usage_percent" => 42.0
         },
         %{
           "bucket" => DateTime.add(@start, 3_600, :second),
           "device_id" => "device-a",
           "mount_point" => "/",
           "avg_usage_percent" => 43.0
         }
       ]}
    end
  end

  defmodule DescShortRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      {:ok,
       [
         %{
           "bucket" => DateTime.add(@start, 3_600, :second),
           "device_id" => "device-a",
           "mount_point" => "/",
           "avg_usage_percent" => 43.0
         },
         %{
           "bucket" => @start,
           "device_id" => "device-a",
           "mount_point" => "/",
           "avg_usage_percent" => 42.0
         }
       ]}
    end
  end

  defmodule InterfaceRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      rows =
        for hour <- 0..47 do
          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "target_device_ip" => "10.0.0.10",
            "if_index" => 7,
            "metric_name" => "ifHCInOctets",
            "series_key" => "snmp:device-a:7:ifHCInOctets",
            "avg_rate_per_second" => 100_000.0 + hour * 1_000.0
          }
        end

      {:ok, rows}
    end
  end

  defmodule InterfacePacketRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      rows =
        for hour <- 0..47 do
          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "target_device_ip" => "10.0.0.10",
            "if_index" => 7,
            "metric_name" => "ifHCInUcastPkts",
            "series_key" => "snmp:device-a:7:ifHCInUcastPkts",
            "avg_rate_per_second" => 100_000.0 + hour * 1_000.0
          }
        end

      {:ok, rows}
    end
  end

  defmodule InterfaceWrapRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    # Clean ~8-12% utilization at 10 Mbps, except one bucket carrying a counter-wrap spike
    # (1.728e14 B/s) — the exact artifact that poisoned Holt-Winters in production.
    def query(_query, _opts) do
      rows =
        for hour <- 0..47 do
          rate = if hour == 24, do: 1.728e14, else: 100_000.0 + hour * 1_000.0

          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "target_device_ip" => "10.0.0.10",
            "if_index" => 7,
            "metric_name" => "ifHCInOctets",
            "series_key" => "snmp:device-a:7:ifHCInOctets",
            "avg_rate_per_second" => rate
          }
        end

      {:ok, rows}
    end
  end

  defp interface_source do
    %Source{
      name: "interface_rate",
      resource_type: "interface",
      metric_class: "interface",
      metric_name: "utilization_percent",
      query: "in:timeseries_metric_interface_hourly time:last_180d",
      value_field: "avg_rate_per_second",
      key_fields: ["device_id", "target_device_ip", "if_index", "metric_name", "series_key"],
      label_fields: ["target_device_ip", "if_index", "metric_name"],
      threshold: 100.0,
      model: "linear"
    }
  end
end

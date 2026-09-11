defmodule ServiceRadar.Observability.CapacityForecasting.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.CapacityForecastConfig
  alias ServiceRadar.Observability.CapacityForecasting.Source
  alias ServiceRadar.Observability.CapacityForecasting.Worker

  @moduletag :requires_app

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

  defmodule ThreeDayRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(query, _opts) do
      send(self(), {:capacity_forecast_query, query})

      rows =
        for hour <- 0..71 do
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

  defmodule EmptyRunner do
    @moduledoc false

    def query(query, _opts) do
      send(self(), {:capacity_forecast_query, query})
      {:ok, []}
    end
  end

  defmodule BlankSeriesRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(query, _opts) do
      send(self(), {:capacity_forecast_query, query})

      rows =
        for series <- ["", "sr:device-a"], hour <- 0..23 do
          %{
            "timestamp" => DateTime.add(@start, hour * 3_600, :second),
            "series" => series,
            "value" => 20.0 + hour
          }
        end

      {:ok, rows}
    end
  end

  defmodule FlowRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(query, _opts) do
      send(self(), {:capacity_forecast_query, query})

      rows =
        for hour <- 0..47 do
          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "bytes_total" => 500_000_000_000.0 + hour * 10_000_000_000.0
          }
        end

      {:ok, rows}
    end
  end

  defmodule NoisyTrendRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      rows =
        for hour <- 0..71 do
          noise = if rem(hour, 2) == 0, do: 18.0, else: -18.0

          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "mount_point" => "/",
            "avg_usage_percent" => 28.0 + hour * 0.55 + noise
          }
        end

      {:ok, rows}
    end
  end

  defmodule OutOfDomainPercentRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      rows =
        for hour <- 0..47 do
          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "mount_point" => "/",
            "avg_usage_percent" => 20.0 + 1.25 * hour
          }
        end

      {:ok, rows}
    end
  end

  defmodule DecliningPercentRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      rows =
        for hour <- 0..47 do
          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "mount_point" => "/",
            "avg_usage_percent" => 75.0 - hour * 1.25
          }
        end

      {:ok, rows}
    end
  end

  defmodule SlowGrowthPercentRunner do
    @moduledoc false
    # 24 days of clean linear growth (0.57 points/day, 33 -> 46.7): the 80 percent
    # crossing is 58 days out, beyond twice the observed span.
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      rows =
        for hour <- 0..575 do
          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "mount_point" => "/var/lib/checkers",
            "avg_usage_percent" => 33.0 + hour * (0.57 / 24)
          }
        end

      {:ok, rows}
    end
  end

  defmodule OutOfDomainGaugePercentRunner do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query(_query, _opts) do
      rows =
        for hour <- 0..47 do
          value =
            case hour do
              24 -> 239.0
              _ -> 70.0 + hour * 0.1
            end

          %{
            "bucket" => DateTime.add(@start, hour * 3_600, :second),
            "device_id" => "device-a",
            "mount_point" => "/",
            "avg_usage_percent" => value
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

  defp previous_forecasts_loader(forecasts) when is_list(forecasts) do
    fn _attrs, _actor, _limit -> {:ok, forecasts} end
  end

  defp previous_projected_forecast(hours_ago \\ 1, overrides \\ %{}) do
    forecasted_at = DateTime.add(@forecasted_at, -hours_ago * 3_600, :second)

    Map.merge(
      %{
        status: "projected",
        forecasted_at: forecasted_at,
        projected_exhaustion_at: DateTime.add(forecasted_at, 50, :second)
      },
      overrides
    )
  end

  defp previous_inactive_forecast(hours_ago), do: previous_inactive_forecast(hours_ago, %{})

  defp previous_inactive_forecast(hours_ago, overrides) do
    Map.merge(
      %{
        status: "inactive",
        forecasted_at: DateTime.add(@forecasted_at, -hours_ago * 3_600, :second),
        projected_exhaustion_at: DateTime.add(@forecasted_at, 2 * 3_600, :second)
      },
      overrides
    )
  end

  defp previous_skipped_forecast(hours_ago), do: previous_skipped_forecast(hours_ago, %{})

  defp previous_skipped_forecast(hours_ago, overrides) do
    Map.merge(
      %{
        status: "skipped",
        skip_reason: "no_projected_exhaustion",
        forecasted_at: DateTime.add(@forecasted_at, -hours_ago * 3_600, :second)
      },
      overrides
    )
  end

  test "worker reads aggregate history through SRQL and upserts projected forecasts" do
    event = [:serviceradar, :observability, :capacity_forecasting, :source]
    handler_id = {:capacity_source_projected, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

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
      threshold: 80.0,
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

    result =
      try do
        Worker.run(job,
          sources: [source],
          runner: Runner,
          upsert_fun: upsert_fun,
          emit_verdicts?: false,
          horizon_seconds: 24 * 3_600,
          min_points: 24
        )
      after
        :telemetry.detach(handler_id)
      end

    assert result == :ok

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

    assert_receive {^handler_id, %{count: 1, rows: 48, sample_count: 48},
                    %{
                      source: "cpu_usage",
                      metric_class: "cpu",
                      metric_name: "usage_percent",
                      status: "projected",
                      skip_reason: "none",
                      result: :ok
                    }}
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
      threshold: 80.0,
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

  test "worker skips rows whose configured resource key is blank" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query:
        ~s|in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_180d bucket:1h agg:avg series:uid sort:timestamp:desc limit:50000|,
      value_field: "value",
      bucket_field: "timestamp",
      key_fields: ["series"],
      label_fields: ["series"],
      threshold: 80.0,
      model: "linear",
      value_unit: "percent"
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
               runner: BlankSeriesRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_upsert, %{resource_key: "cpu_usage:sr:device-a"}}
    refute_received {:capacity_forecast_upsert, %{resource_key: "cpu_usage"}}
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

  test "worker reads forecast settings at run start instead of trusting stale cache" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      capacity_forecasting_opts: [
        horizon_seconds: 90 * 24 * 3_600,
        warning_horizon_seconds: 30 * 24 * 3_600,
        warning_threshold_percent: 100.0,
        forecast_model: "seasonal_linear",
        min_points: 24,
        capacity_metric_class_overrides: %{}
      ]
    })

    settings = %CapacityForecastConfig{
      forecast_horizon_seconds: 12 * 3_600,
      warning_horizon_seconds: 6 * 3_600,
      warning_threshold_percent: 75.0,
      model: :linear,
      minimum_history_points: 24,
      metric_class_overrides: %{
        "cpu" => %{"minimum_history_points" => 30}
      }
    }

    runtime_opts_fetcher = fn actor ->
      send(self(), {:capacity_forecast_runtime_config_fetch, actor})
      {:ok, settings}
    end

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
      threshold: 80.0,
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
               emit_verdicts?: false,
               runtime_config_source: :database,
               runtime_opts_fetcher: runtime_opts_fetcher
             )

    assert_received {:capacity_forecast_runtime_config_fetch, %{role: :system}}
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
      threshold: 80.0,
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

  test "default sources cover only monotone long-horizon consumables" do
    sources = Source.defaults()
    queries = Enum.map(sources, & &1.query)

    refute Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.memory"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.disk"|))
    refute Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.process"|))
    refute Enum.any?(queries, &String.contains?(&1, ~s|metric_name:"process.count"|))
    refute Enum.any?(queries, &String.contains?(&1, "in:timeseries_metric_interface_hourly"))
    refute Enum.any?(queries, &String.contains?(&1, "in:flows"))
    refute Enum.any?(sources, &(&1.name == "timeseries_value"))

    memory_source = Enum.find(sources, &(&1.name == "memory_usage"))
    assert memory_source.value_field == "value"
    assert memory_source.bucket_field == "timestamp"
    assert memory_source.key_fields == ["series"]
  end

  test "bursty and non-consumable default sources are explicit opt-ins" do
    sources =
      Source.defaults(include_sources: ["cpu_usage", "interface_rate", "flow_bytes_per_hour"])

    queries = Enum.map(sources, & &1.query)

    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    assert Enum.any?(queries, &String.contains?(&1, "in:timeseries_metric_interface_hourly"))
    assert Enum.any?(queries, &String.contains?(&1, "in:flows"))

    interface_source = Enum.find(sources, &(&1.resource_type == "interface"))
    assert interface_source.metric_name == "utilization_percent"
    assert interface_source.threshold == 90.0
    assert interface_source.sustained_statistic == "daily_p95"

    flow_source = Enum.find(sources, &(&1.resource_type == "flow"))
    assert flow_source.name == "flow_bytes_per_hour"
    assert flow_source.metric_name == "bytes_per_hour"
    assert flow_source.value_field == "bytes_total"
    assert flow_source.threshold == 1_000_000_000_000.0
  end

  test "worker default source opt-ins add bursty sources without explicit source list" do
    job = %Oban.Job{args: %{"trigger" => "cron"}, inserted_at: @forecasted_at}

    assert :ok =
             Worker.run(job,
               runner: EmptyRunner,
               emit_verdicts?: false,
               default_source_opt_ins: ["cpu_usage", "interface_rate"]
             )

    queries =
      for _ <- 1..4 do
        assert_receive {:capacity_forecast_query, query}
        query
      end

    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.memory"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.disk"|))
    assert Enum.any?(queries, &String.contains?(&1, "in:timeseries_metric_interface_hourly"))
    refute Enum.any?(queries, &String.contains?(&1, "in:flows"))
  end

  test "env source opt-ins from worker config reach the default source list" do
    put_worker_env(default_source_opt_ins: ["cpu_usage"])
    job = %Oban.Job{args: %{"trigger" => "cron"}, inserted_at: @forecasted_at}

    assert :ok =
             Worker.run(job,
               runner: EmptyRunner,
               emit_verdicts?: false,
               runtime_config_source: :none
             )

    queries = collect_queries(3)
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    refute_receive {:capacity_forecast_query, _query}
  end

  test "empty Settings opt-in list preserves env opt-ins" do
    put_worker_env(default_source_opt_ins: ["cpu_usage"])

    runtime_opts_fetcher = fn _actor ->
      {:ok, forecast_settings(default_source_opt_ins: [])}
    end

    job = %Oban.Job{args: %{"trigger" => "cron"}, inserted_at: @forecasted_at}

    assert :ok =
             Worker.run(job,
               runner: EmptyRunner,
               emit_verdicts?: false,
               runtime_config_source: :database,
               runtime_opts_fetcher: runtime_opts_fetcher
             )

    queries = collect_queries(3)
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    refute Enum.any?(queries, &String.contains?(&1, "in:timeseries_metric_interface_hourly"))
    refute_receive {:capacity_forecast_query, _query}
  end

  test "non-empty Settings opt-ins override env opt-ins" do
    put_worker_env(default_source_opt_ins: ["cpu_usage"])

    runtime_opts_fetcher = fn _actor ->
      {:ok, forecast_settings(default_source_opt_ins: ["interface_rate"])}
    end

    job = %Oban.Job{args: %{"trigger" => "cron"}, inserted_at: @forecasted_at}

    assert :ok =
             Worker.run(job,
               runner: EmptyRunner,
               emit_verdicts?: false,
               runtime_config_source: :database,
               runtime_opts_fetcher: runtime_opts_fetcher
             )

    queries = collect_queries(3)
    assert Enum.any?(queries, &String.contains?(&1, "in:timeseries_metric_interface_hourly"))
    refute Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    refute_receive {:capacity_forecast_query, _query}
  end

  test "unknown source opt-ins warn and the valid subset still applies" do
    job = %Oban.Job{args: %{"trigger" => "cron"}, inserted_at: @forecasted_at}

    log =
      capture_log(fn ->
        assert :ok =
                 Worker.run(job,
                   runner: EmptyRunner,
                   emit_verdicts?: false,
                   runtime_config_source: :none,
                   default_source_opt_ins: ["cpu_usage", "bogus_source"]
                 )
      end)

    assert log =~ "Ignoring unknown capacity forecasting source opt-ins: bogus_source"

    queries = collect_queries(3)
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    refute_receive {:capacity_forecast_query, _query}
  end

  test "runtime percent threshold does not override non-percent flow capacity source" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      capacity_forecasting_opts: [
        horizon_seconds: 12 * 3_600,
        warning_threshold_percent: 75.0,
        min_points: 24,
        capacity_metric_class_overrides: %{}
      ]
    })

    source = %Source{
      name: "flow_bytes_per_hour",
      resource_type: "flow",
      metric_class: "flow",
      metric_name: "bytes_per_hour",
      query: "in:flows time:last_180d bucket:1h stats:sum(bytes_total) as bytes_total by bucket",
      value_field: "bytes_total",
      threshold: 1_000_000_000_000.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_flow, attrs})
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
               runner: FlowRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false
             )

    assert_received {:capacity_forecast_flow, attrs}
    assert attrs.metric_name == "bytes_per_hour"
    assert attrs.exhaustion_threshold == 1_000_000_000_000.0
  end

  test "runtime flow threshold override controls non-percent flow capacity source" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      capacity_forecasting_opts: [
        horizon_seconds: 12 * 3_600,
        warning_threshold_percent: 75.0,
        min_points: 24,
        capacity_metric_class_overrides: %{
          "flow" => %{"threshold" => 250_000_000_000.0}
        }
      ]
    })

    source = %Source{
      name: "flow_bytes_per_hour",
      resource_type: "flow",
      metric_class: "flow",
      metric_name: "bytes_per_hour",
      query: "in:flows time:last_180d bucket:1h stats:sum(bytes_total) as bytes_total by bucket",
      value_field: "bytes_total",
      threshold: 1_000_000_000_000.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_flow, attrs})
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
               runner: FlowRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false
             )

    assert_received {:capacity_forecast_flow, attrs}
    assert attrs.metric_name == "bytes_per_hour"
    assert attrs.exhaustion_threshold == 250_000_000_000.0
  end

  test "worker forecasts sustained daily p95 instead of raw hourly averages when configured" do
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
      threshold: 95.0,
      model: "linear",
      value_unit: "percent",
      sustained_statistic: "daily_p95"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_sustained_daily_p95, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: ThreeDayRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               min_points: 3,
               horizon_seconds: 10 * 24 * 3_600
             )

    assert_received {:capacity_forecast_sustained_daily_p95, attrs}

    assert attrs.sample_count == 3
    assert_in_delta attrs.current_value, 89.85, 0.001
    assert DateTime.truncate(attrs.window_started_at, :second) == ~U[2026-06-01 23:00:00Z]
    assert DateTime.truncate(attrs.window_ended_at, :second) == ~U[2026-06-03 23:00:00Z]
    assert attrs.metadata["sustained_statistic"] == "daily_p95"
    assert attrs.metadata["sustained_input_points"] == 72
    assert attrs.status == "projected"
  end

  test "worker gates weak noisy trends when the prediction lower bound misses threshold" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 80.0,
      model: "linear",
      value_unit: "percent"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_noisy_trend, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: NoisyTrendRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 48 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_noisy_trend, attrs}

    assert attrs.status == "skipped"
    assert attrs.skip_reason == "no_projected_exhaustion"
    assert attrs.projected_exhaustion_at == nil
    assert attrs.metadata["diagnostics"]["lower_bound"] < 80.0
  end

  test "percent forecasts keep threshold ETA and clamp projected percent values in the kernel" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 80.0,
      model: "linear",
      value_unit: "percent"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_percent_out_of_domain, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: OutOfDomainPercentRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_percent_out_of_domain, attrs}
    assert attrs.status == "projected"
    assert attrs.projected_exhaustion_at
    assert attrs.projected_value == 100.0
    assert attrs.lower_bound == 100.0
    assert attrs.upper_bound == 100.0
    assert attrs.metadata["forecast_value_unit"] == "percent"
    assert attrs.metadata["diagnostics"]["model"] == "linear"
    assert attrs.metadata["diagnostics"]["projection_bounded"] == true
    assert attrs.metadata["diagnostics"]["raw_projected_value"] > 100.0
  end

  test "worker keeps steep bounded percent forecasts and clamps horizon display value" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 80.0,
      model: "linear",
      value_unit: "percent"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_steep_percent, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: Runner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 1_000 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_steep_percent, attrs}
    assert attrs.status == "projected"
    assert attrs.skip_reason == nil
    assert attrs.projected_value == 100.0
    assert attrs.projected_exhaustion_at
    assert attrs.lower_bound == 100.0
    assert attrs.upper_bound == 100.0
    assert attrs.metadata["diagnostics"]["projection_bounded"] == true
    assert attrs.metadata["diagnostics"]["raw_projected_value"] > 1_000.0
  end

  test "worker splits gauge percent series at out-of-domain samples" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 80.0,
      model: "linear",
      value_unit: "percent"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_out_of_domain_gauge_percent, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: OutOfDomainGaugePercentRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_out_of_domain_gauge_percent, attrs}

    assert attrs.status == "skipped"
    assert attrs.skip_reason == "insufficient_history"
    assert attrs.sample_count == 23
    assert attrs.current_value == nil
    assert attrs.metadata["gap_count"] == 1
    assert attrs.window_started_at == ~U[2026-06-02 01:00:00Z]
  end

  test "worker skips bounded percent forecasts that never cross the threshold" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 80.0,
      model: "linear",
      value_unit: "percent"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_declining_percent, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: DecliningPercentRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_declining_percent, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "trend_not_significant"
    assert attrs.projected_value == nil
    assert attrs.projected_exhaustion_at == nil
    assert attrs.metadata["forecast_value_unit"] == "percent"
    assert attrs.metadata["diagnostics"]["sample_count"] == 48
  end

  test "worker records a crossing beyond the history cap distinctly from no crossing" do
    source = %Source{
      name: "disk_usage",
      resource_type: "disk",
      metric_class: "disk",
      metric_name: "usage_percent",
      query: "in:disk_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "mount_point"],
      label_fields: ["mount_point"],
      threshold: 80.0,
      model: "linear",
      value_unit: "percent"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_history_capped, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: SlowGrowthPercentRunner,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 90 * 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_history_capped, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "exhaustion_beyond_history_cap"
    assert attrs.projected_exhaustion_at == nil

    diagnostics = attrs.metadata["diagnostics"]
    assert diagnostics["model"] == "linear"
    assert diagnostics["history_span_seconds"] == 575 * 3_600
    assert diagnostics["extrapolation_cap_seconds"] == 2 * 575 * 3_600
    assert diagnostics["lower_bound"] > 80.0

    # (80 - 33) / (0.57 / 24 per hour) = 1978.9 h after the window start.
    assert {:ok, raw_crossing, _offset} =
             DateTime.from_iso8601(diagnostics["raw_projected_exhaustion_at"])

    assert abs(DateTime.diff(raw_crossing, ~U[2026-08-22 10:57:30Z], :second)) < 120
  end

  test "interface forecasts convert byte rates to utilization percent before no-risk skip" do
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

    assert_received {:interface_capacity_row, %{"if_index" => 7, "partition" => "edge-a"}}
    assert_received {:capacity_forecast_interface, attrs}

    assert attrs.metric_name == "utilization_percent"
    assert attrs.resource_id == "device-a:if7"
    assert attrs.exhaustion_threshold == 100.0
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "no_projected_exhaustion"
    assert attrs.projected_value == nil
    assert attrs.projected_exhaustion_at == nil
    assert attrs.metadata["capacity_bps"] == 10_000_000
    assert attrs.metadata["forecast_value_unit"] == "percent"
    assert attrs.metadata["raw_value_unit"] == "bytes_per_second"
    assert attrs.metadata["diagnostics"]["raw_projected_value"] > 0.0
  end

  test "interface forecasts insert a gap for SNMP counter-wrap spikes" do
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

    # The wrap bucket becomes a gap, so the model does not stitch together the
    # pre-wrap and post-wrap segments as one continuous time series.
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "insufficient_history"
    assert attrs.sample_count == 23
    assert attrs.current_value == nil
    assert attrs.metadata["gap_count"] == 1
    assert attrs.window_started_at == ~U[2026-06-02 01:00:00Z]
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
               emit_verdicts?: false,
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
      threshold: 80.0,
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
               previous_forecasts_loader:
                 previous_forecasts_loader([previous_projected_forecast()]),
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

  test "worker persists but does not emit the first unconfirmed projected forecast" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query: "in:cpu_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 80.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_upsert, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: Runner,
               upsert_fun: upsert_fun,
               verdict_emitter: VerdictEmitter,
               previous_forecasts_loader: previous_forecasts_loader([]),
               test_pid: self(),
               horizon_seconds: 24 * 3_600,
               warning_horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_upsert, %{status: "projected"}}
    refute_received {:capacity_forecast_verdict, _attrs}
  end

  test "worker suppresses unchanged capacity forecast verdict states" do
    source = %Source{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query: "in:cpu_metrics time:last_180d bucket:1h",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 80.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_upsert, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: Runner,
               upsert_fun: upsert_fun,
               verdict_emitter: VerdictEmitter,
               previous_forecasts_loader:
                 previous_forecasts_loader([
                   previous_projected_forecast(1),
                   previous_projected_forecast(2)
                 ]),
               test_pid: self(),
               horizon_seconds: 24 * 3_600,
               warning_horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_upsert, %{status: "projected"}}
    refute_received {:capacity_forecast_verdict, _attrs}
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
      threshold: 80.0,
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
                   previous_forecasts_loader:
                     previous_forecasts_loader([previous_projected_forecast()]),
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
               previous_forecasts_loader:
                 previous_forecasts_loader([
                   previous_inactive_forecast(1),
                   previous_projected_forecast(2),
                   previous_projected_forecast(3)
                 ]),
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

  test "worker skips forecasts whose PI lower bound misses the threshold horizon" do
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
      send(self(), {:capacity_forecast_clamped_warning, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: RecentRunner,
               upsert_fun: upsert_fun,
               verdict_emitter: VerdictEmitter,
               previous_forecasts_loader:
                 previous_forecasts_loader([
                   previous_skipped_forecast(1),
                   previous_projected_forecast(2),
                   previous_projected_forecast(3)
                 ]),
               test_pid: self(),
               horizon_seconds: 24 * 3_600,
               warning_horizon_seconds: 48 * 3_600,
               min_points: 24
             )

    assert_received {:capacity_forecast_clamped_warning, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "no_projected_exhaustion"
    assert attrs.projected_exhaustion_at == nil
    assert attrs.metadata["diagnostics"]["lower_bound"] < attrs.exhaustion_threshold
    assert_received {:capacity_forecast_verdict, verdict_attrs}
    assert verdict_attrs.status == "skipped"
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
               previous_forecasts_loader:
                 previous_forecasts_loader([
                   previous_skipped_forecast(1, %{skip_reason: "insufficient_history"}),
                   previous_projected_forecast(2),
                   previous_projected_forecast(3)
                 ]),
               test_pid: self(),
               min_points: 3
             )

    assert_received {:capacity_forecast_verdict, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason
  end

  test "worker suppresses initial cleared capacity forecast verdicts" do
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

    upsert_fun = fn attrs, _actor ->
      send(self(), {:capacity_forecast_upsert, attrs})
      {:ok, attrs}
    end

    job = %Oban.Job{args: %{"forecasted_at" => DateTime.to_iso8601(@forecasted_at)}}

    assert :ok =
             Worker.run(job,
               sources: [source],
               runner: __MODULE__.ShortRunner,
               upsert_fun: upsert_fun,
               verdict_emitter: VerdictEmitter,
               previous_forecasts_loader: previous_forecasts_loader([]),
               test_pid: self(),
               min_points: 3
             )

    assert_received {:capacity_forecast_upsert, %{status: "skipped"}}
    refute_received {:capacity_forecast_verdict, _attrs}
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
            "partition" => "edge-a",
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
            "partition" => "edge-a",
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
            "partition" => "edge-a",
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
      key_fields: [
        "partition",
        "device_id",
        "target_device_ip",
        "if_index",
        "metric_name",
        "series_key"
      ],
      label_fields: ["target_device_ip", "if_index", "metric_name"],
      threshold: 100.0,
      model: "linear"
    }
  end

  defp put_worker_env(config) do
    previous = Application.get_env(:serviceradar_core, Worker)
    Application.put_env(:serviceradar_core, Worker, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:serviceradar_core, Worker)
        _ -> Application.put_env(:serviceradar_core, Worker, previous)
      end
    end)
  end

  defp collect_queries(count) do
    for _ <- 1..count do
      assert_receive {:capacity_forecast_query, query}
      query
    end
  end

  defp forecast_settings(overrides) do
    struct!(
      %CapacityForecastConfig{
        forecast_horizon_seconds: 7_776_000,
        warning_horizon_seconds: 2_592_000,
        warning_threshold_percent: 80.0,
        model: :linear,
        minimum_history_points: 24,
        metric_class_overrides: %{}
      },
      overrides
    )
  end
end

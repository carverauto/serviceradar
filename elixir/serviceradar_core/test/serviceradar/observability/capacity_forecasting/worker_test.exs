defmodule ServiceRadar.Observability.CapacityForecasting.WorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CapacityForecasting.Source
  alias ServiceRadar.Observability.CapacityForecasting.Worker

  @forecasted_at ~U[2026-06-12 12:00:00Z]

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
               min_points: 3
             )

    assert_received {:capacity_forecast_skip, attrs}
    assert attrs.status == "skipped"
    assert attrs.skip_reason == "insufficient_history"
    assert attrs.sample_count == 2
    assert attrs.slope_per_second == nil
  end

  test "default sources cover long-horizon metric, interface, and flow aggregates" do
    queries = Enum.map(Source.defaults(), & &1.query)

    assert Enum.any?(queries, &String.contains?(&1, "in:cpu_metrics"))
    assert Enum.any?(queries, &String.contains?(&1, "in:memory_metrics"))
    assert Enum.any?(queries, &String.contains?(&1, "in:disk_metrics"))
    assert Enum.any?(queries, &String.contains?(&1, "in:process_metrics"))
    assert Enum.any?(queries, &String.contains?(&1, "in:timeseries_metrics"))
    assert Enum.any?(queries, &String.contains?(&1, "in:timeseries_metric_interface_hourly"))
    assert Enum.any?(queries, &String.contains?(&1, "in:flows"))
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
               min_points: 24
             )
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
end

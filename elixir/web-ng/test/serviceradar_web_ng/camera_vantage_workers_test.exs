defmodule ServiceRadarWebNG.CameraVantageWorkersTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.CameraVantageWorkers

  @moduletag :db_free

  @now ~U[2026-11-26 08:00:00Z]

  test "summarizes worker health, routing mode, and queue lag counts accurately" do
    online_worker = %{
      worker_id: "alpr-worker-01",
      worker_kind: :external_rust,
      protocol_version: "vantage.worker.v1",
      capabilities: ["vantage.alpr.v1"],
      supported_source_modes: ["recorded_block"],
      execution_backend: "onnx",
      architecture: "arm64",
      model_id: "fast-alpr",
      model_version: "1.0.0",
      active_jobs: 1,
      max_concurrency: 4,
      health: :ready,
      last_heartbeat_at: DateTime.shift(@now, second: -5),
      expires_at: DateTime.shift(@now, second: 25)
    }

    stale_worker = %{
      worker_id: "alpr-worker-stale",
      worker_kind: :external_python,
      protocol_version: "vantage.worker.v1",
      capabilities: ["vantage.alpr.v1"],
      supported_source_modes: ["recorded_block"],
      execution_backend: "onnx",
      architecture: "amd64",
      model_id: "fast-alpr",
      model_version: "1.0.0",
      active_jobs: 0,
      max_concurrency: 2,
      health: :ready,
      last_heartbeat_at: DateTime.shift(@now, second: -40),
      expires_at: DateTime.shift(@now, second: -10)
    }

    pipelines = [
      %{
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        version: "1.0.0",
        runner: :external_worker,
        capability: "vantage.alpr.v1",
        fallback_runner: "camera_vlm",
        source_mode: :recorded_block
      },
      %{
        pipeline_id: "io.serviceradar.vantage.vlm-only",
        version: "1.0.0",
        runner: :camera_vlm,
        capability: nil,
        fallback_runner: nil,
        source_mode: :recorded_block
      }
    ]

    jobs = [
      %{state: :pending, inserted_at: DateTime.shift(@now, second: -45)},
      %{state: :pending, inserted_at: DateTime.shift(@now, second: -10)},
      %{state: :dispatched, inserted_at: DateTime.shift(@now, second: -5)}
    ]

    summary =
      CameraVantageWorkers.summary(%{user: %{id: "viewer"}},
        now: @now,
        workers: [online_worker, stale_worker],
        pipelines: pipelines,
        jobs: jobs
      )

    assert summary.online_count == 1
    assert summary.stale_count == 1
    assert summary.routing_mode == :mixed
    assert summary.queue_lag.accessible? == true
    assert summary.queue_lag.pending_count == 2
    assert summary.queue_lag.dispatched_count == 1
    assert summary.queue_lag.oldest_pending_age_seconds == 45
  end

  test "reports held routing mode and inaccessible queue lag when unauthorized" do
    held_pipeline = %{
      pipeline_id: "io.serviceradar.vantage.strict",
      version: "1.0.0",
      runner: :external_worker,
      capability: "vantage.strict.v1",
      fallback_runner: nil,
      source_mode: :recorded_block
    }

    summary =
      CameraVantageWorkers.summary(%{user: %{id: "viewer"}},
        now: @now,
        workers: [],
        pipelines: [held_pipeline],
        jobs_loader: fn _scope -> {:error, :forbidden} end
      )

    assert summary.routing_mode == :held
    assert summary.queue_lag.accessible? == false
    assert summary.queue_lag.pending_count == 0
    assert summary.queue_lag.dispatched_count == 0
  end
end

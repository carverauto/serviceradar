defmodule ServiceRadar.Camera.VantageWorkerHeartbeatTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.VantageWorkerHeartbeat

  @now ~U[2026-11-25 00:00:00Z]

  test "validates vantage.heartbeat.v1 JSON and derives bounded expires_at TTL" do
    raw = Jason.encode!(valid_heartbeat())
    parent = self()

    assert {:ok, record} =
             VantageWorkerHeartbeat.ingest_heartbeat(raw,
               now: @now,
               ttl_us: 30_000_000,
               broadcast?: false,
               upsert_fn: fn attrs ->
                 send(parent, {:upserted, attrs})
                 {:ok, attrs}
               end
             )

    assert_received {:upserted, attrs}
    assert attrs.worker_id == "vantage-alpr-arm64-01"
    assert attrs.worker_kind == :external_rust
    assert attrs.protocol_version == "vantage.worker.v1"
    assert attrs.capabilities == ["vantage.alpr.v1"]
    assert attrs.supported_source_modes == ["recorded_block", "live_keyframe_tap"]
    assert attrs.execution_backend == "onnx"
    assert attrs.architecture == "arm64"
    assert attrs.max_concurrency == 4
    assert attrs.active_jobs == 1
    assert attrs.health == :ready
    assert attrs.last_heartbeat_at == @now
    assert attrs.expires_at == DateTime.add(@now, 30_000_000, :microsecond)
    assert record == attrs
  end

  test "rejects malformed protocol fields, capability slugs, concurrency bounds, and oversized JSON" do
    for {field, bad_val, expected_err} <- [
          {"schema_version", "vantage.heartbeat.v0", :invalid_schema_version},
          {"protocol_version", "wrong.v1", :invalid_protocol_version},
          {"worker_id", "   ", :invalid_worker_id},
          {"worker_kind", "unknown_kind", :invalid_worker_kind},
          {"capabilities", [], :invalid_capabilities},
          {"capabilities", ["Invalid Caps!"], :invalid_capabilities},
          {"supported_source_modes", [], :invalid_supported_source_modes},
          {"supported_source_modes", ["ftp_pull"], :invalid_supported_source_modes},
          {"execution_backend", "tensorrt_raw", :invalid_execution_backend},
          {"architecture", "ppc64", :invalid_architecture},
          {"max_concurrency", 0, :invalid_max_concurrency},
          {"active_jobs", 5, :invalid_active_jobs},
          {"health", "unknown", :invalid_health},
          {"sent_at_us", -1, :invalid_sent_at_us}
        ] do
      payload = Map.put(valid_heartbeat(), field, bad_val)

      assert {:error, ^expected_err} =
               VantageWorkerHeartbeat.ingest_heartbeat(payload,
                 now: @now,
                 broadcast?: false,
                 upsert_fn: fn _ -> flunk("must not persist invalid heartbeat #{field}") end
               )
    end

    assert {:error, :invalid_json} =
             VantageWorkerHeartbeat.ingest_heartbeat("{not-json", broadcast?: false)

    oversized = ~s({"pad":"#{String.duplicate("a", 17_000)}"})

    assert {:error, :heartbeat_too_large} =
             VantageWorkerHeartbeat.ingest_heartbeat(oversized, broadcast?: false)
  end

  defp valid_heartbeat do
    %{
      "schema_version" => "vantage.heartbeat.v1",
      "worker_id" => "vantage-alpr-arm64-01",
      "worker_kind" => "external_rust",
      "protocol_version" => "vantage.worker.v1",
      "capabilities" => ["vantage.alpr.v1"],
      "supported_source_modes" => ["recorded_block", "live_keyframe_tap"],
      "execution_backend" => "onnx",
      "architecture" => "arm64",
      "model_id" => "fast-alpr-us",
      "model_version" => "1.2.0",
      "max_concurrency" => 4,
      "active_jobs" => 1,
      "health" => "ready",
      "sent_at_us" => 1_760_000_000_000_000
    }
  end
end

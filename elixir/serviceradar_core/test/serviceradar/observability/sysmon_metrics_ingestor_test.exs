defmodule ServiceRadar.Observability.SysmonMetricsIngestorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.SysmonMetricsIngestor

  test "builds metric batches from sysmon samples" do
    sample = %{
      "timestamp" => "2025-04-24T14:15:22Z",
      "host_id" => "host-1",
      "host_ip" => "192.168.1.100",
      "cpus" => [
        %{
          "core_id" => 0,
          "usage_percent" => 10.5,
          "frequency_hz" => 1_000_000,
          "label" => "CPU0",
          "cluster" => "ECPU"
        }
      ],
      "clusters" => [%{"name" => "ECPU", "frequency_hz" => 2_000_000}],
      "disks" => [%{"mount_point" => "/", "used_bytes" => 50, "total_bytes" => 100}],
      "memory" => %{"used_bytes" => 80, "total_bytes" => 100},
      "processes" => [
        %{
          "pid" => 123,
          "name" => "nginx",
          "cpu_usage" => 1.1,
          "memory_usage" => 2_048,
          "status" => "Running",
          "start_time" => "2025-04-24T14:15:00Z"
        }
      ]
    }

    {:ok, timestamp, _offset} = DateTime.from_iso8601(sample["timestamp"])

    context = %{
      timestamp: DateTime.truncate(timestamp, :microsecond),
      gateway_id: "gateway-1",
      agent_id: "agent-1",
      host_id: "host-1",
      device_id: "device-1",
      partition: "default"
    }

    metrics = SysmonMetricsIngestor.build_metrics(sample, context)

    assert [
             %{
               core_id: 0,
               usage_percent: 10.5,
               frequency_hz: 1_000_000.0,
               label: "CPU0",
               cluster: "ECPU"
             }
           ] =
             metrics.cpu

    assert [%{cluster: "ECPU", frequency_hz: 2_000_000.0}] = metrics.cpu_clusters

    assert [%{total_bytes: 100, used_bytes: 80, available_bytes: 20, usage_percent: 80.0}] =
             metrics.memory

    assert [
             %{
               mount_point: "/",
               total_bytes: 100,
               used_bytes: 50,
               available_bytes: 50,
               usage_percent: 50.0
             }
           ] =
             metrics.disks

    assert [%{pid: 123, name: "nginx", cpu_usage: 1.1, memory_usage: 2_048, status: "Running"}] =
             metrics.processes
  end

  test "extracts corrupted index names from nested Ash errors" do
    errors = [
      %{
        errors: [
          %{
            error:
              "** (Postgrex.Error) ERROR XX002 (index_corrupted) right sibling's left-link doesn't match in index \"_hyper_7_87_chunk_cpu_metrics_timestamp_idx\""
          }
        ]
      }
    ]

    assert "_hyper_7_87_chunk_cpu_metrics_timestamp_idx" =
             SysmonMetricsIngestor.extract_corrupted_index_name(errors)
  end

  test "returns nil when errors do not include index corruption" do
    errors = [%{error: "** (Postgrex.Error) ERROR 23505 (unique_violation) duplicate key"}]

    assert nil == SysmonMetricsIngestor.extract_corrupted_index_name(errors)
  end

  test "chunks large record sets to avoid PostgreSQL parameter limits" do
    large_records = Enum.map(1..2_501, &%{id: &1})

    chunks = SysmonMetricsIngestor.chunk_records(large_records)

    assert length(chunks) == 3
    assert length(Enum.at(chunks, 0)) == 1_000
    assert length(Enum.at(chunks, 1)) == 1_000
    assert length(Enum.at(chunks, 2)) == 501
  end
end

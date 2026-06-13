defmodule ServiceRadar.EventWriter.Processors.MetricsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Processors.Metrics

  setup do
    previous_ingestor = Application.get_env(:serviceradar_core, :metrics_sysmon_ingestor)
    previous_pid = Application.get_env(:serviceradar_core, :metrics_processor_test_pid)

    on_exit(fn ->
      restore_env(:metrics_sysmon_ingestor, previous_ingestor)
      restore_env(:metrics_processor_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_core, :metrics_processor_test_pid, self())

    :ok
  end

  test "parses sysmon metrics envelope into sysmon ingestor input" do
    parsed =
      Metrics.parse_message(%{
        data: Jason.encode!(sysmon_envelope("memory")),
        metadata: %{subject: "metrics.sysmon.memory"}
      })

    assert %{
             family: "memory",
             status: %{
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               partition: "default",
               source: "sysmon-metrics"
             },
             payload: %{
               "status" => %{
                 "timestamp" => "2026-06-12T00:00:00Z",
                 "host_id" => "host-1",
                 "agent_id" => "agent-1",
                 "memory" => %{"used_bytes" => 50, "total_bytes" => 100}
               }
             }
           } = parsed

    refute Map.has_key?(parsed.payload["status"], "cpus")
    refute Map.has_key?(parsed.payload["status"], "disks")
    refute Map.has_key?(parsed.payload["status"], "processes")
  end

  test "keeps parsing legacy sysmon shadow envelopes during cutover" do
    parsed =
      Metrics.parse_message(%{
        data: Jason.encode!(sysmon_envelope("memory", "serviceradar.sysmon.shadow.v1")),
        metadata: %{subject: "metrics.sysmon.memory"}
      })

    assert %{family: "memory", payload: %{"status" => %{"memory" => _memory}}} = parsed
  end

  test "filters each sysmon family before delegating to the sysmon ingestor" do
    Application.put_env(
      :serviceradar_core,
      :metrics_sysmon_ingestor,
      __MODULE__.SysmonIngestorStub
    )

    assert {:ok, 4} =
             Metrics.process_batch([
               sysmon_message("cpu"),
               sysmon_message("memory"),
               sysmon_message("disk"),
               sysmon_message("process")
             ])

    assert_receive {:sysmon_ingest, %{"status" => cpu_sample}, %{gateway_id: "gateway-1"}}
    assert %{"cpus" => [_], "clusters" => [_]} = cpu_sample
    refute Map.has_key?(cpu_sample, "memory")

    assert_receive {:sysmon_ingest, %{"status" => memory_sample}, _status}
    assert %{"memory" => %{"used_bytes" => 50, "total_bytes" => 100}} = memory_sample
    refute Map.has_key?(memory_sample, "cpus")

    assert_receive {:sysmon_ingest, %{"status" => disk_sample}, _status}
    assert %{"disks" => [_]} = disk_sample
    refute Map.has_key?(disk_sample, "processes")

    assert_receive {:sysmon_ingest, %{"status" => process_sample}, _status}
    assert %{"processes" => [_]} = process_sample
    refute Map.has_key?(process_sample, "disks")
  end

  test "continues sysmon batch after one ingestor failure" do
    Application.put_env(
      :serviceradar_core,
      :metrics_sysmon_ingestor,
      __MODULE__.FailingSysmonIngestorStub
    )

    assert {:ok, 3} =
             Metrics.process_batch([
               sysmon_message("cpu"),
               sysmon_message("memory"),
               sysmon_message("disk"),
               sysmon_message("process")
             ])

    assert_receive {:sysmon_ingest, %{"status" => %{"cpus" => [_]}}, %{gateway_id: "gateway-1"}}
    assert_receive {:sysmon_ingest, %{"status" => %{"memory" => _}}, _status}
    assert_receive {:sysmon_ingest, %{"status" => %{"disks" => [_]}}, _status}
    assert_receive {:sysmon_ingest, %{"status" => %{"processes" => [_]}}, _status}
  end

  test "parses SNMP interface metric as a timeseries telemetry row" do
    row =
      Metrics.parse_message(%{
        data: Jason.encode!(snmp_envelope()),
        metadata: %{subject: "metrics.snmp.interface.ifHCInOctets"}
      })

    assert %{
             gateway_id: "gateway-1",
             agent_id: "agent-1",
             metric_name: "ifHCInOctets",
             metric_type: "snmp",
             value: 1234.5,
             target_device_ip: "10.0.0.20",
             if_index: 7,
             series_key: series_key
           } = row

    assert is_binary(series_key)
    assert row.tags["interface_uid"] == "ifindex:7"
    assert row.metadata["schema"] == nil
  end

  test "parses generic scalar metric as a timeseries telemetry row" do
    row =
      Metrics.parse_message(%{
        data: Jason.encode!(plugin_metric_envelope()),
        metadata: %{subject: "metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max"}
      })

    assert %{
             gateway_id: "gateway-1",
             agent_id: "agent-1",
             metric_name: "proxmox_guest_cpu_ratio_max",
             metric_type: "cpu",
             value: 0.91,
             series_key: series_key
           } = row

    assert is_binary(series_key)
    assert row.tags["producer_id"] == "proxmox-inventory"
    assert row.metadata["status"] == "WARNING"
  end

  defmodule SysmonIngestorStub do
    @moduledoc false
    def ingest(payload, status) do
      send(Application.fetch_env!(:serviceradar_core, :metrics_processor_test_pid), {
        :sysmon_ingest,
        payload,
        status
      })

      :ok
    end
  end

  defmodule FailingSysmonIngestorStub do
    @moduledoc false
    def ingest(payload, status) do
      send(Application.fetch_env!(:serviceradar_core, :metrics_processor_test_pid), {
        :sysmon_ingest,
        payload,
        status
      })

      case payload do
        %{"status" => %{"cpus" => _cpus}} -> {:error, :cpu_insert_failed}
        _payload -> :ok
      end
    end
  end

  defp sysmon_message(family) do
    %{
      data: Jason.encode!(sysmon_envelope(family)),
      metadata: %{subject: "metrics.sysmon.#{family}"}
    }
  end

  defp sysmon_envelope(family, schema \\ "serviceradar.sysmon.metrics.v1") do
    %{
      "schema" => schema,
      "source" => "sysmon-metrics",
      "metric_family" => family,
      "agent_id" => "agent-1",
      "gateway_id" => "gateway-1",
      "partition" => "default",
      "service_name" => "sysmon",
      "service_type" => "sysmon",
      "status_timestamp_unix_nano" => 1_765_500_000_000_000_000,
      "agent_timestamp_unix_nano" => 1_765_499_999_000_000_000,
      "sample" => %{
        "timestamp" => "2026-06-12T00:00:00Z",
        "host_id" => "host-1",
        "host_ip" => "10.0.0.10",
        "agent_id" => "agent-1",
        "cpus" => [%{"core_id" => 0, "usage_percent" => 12.5}],
        "clusters" => [%{"name" => "ECPU", "frequency_hz" => 2_000_000}],
        "disks" => [%{"mount_point" => "/", "used_bytes" => 10, "total_bytes" => 100}],
        "memory" => %{"used_bytes" => 50, "total_bytes" => 100},
        "processes" => [%{"pid" => 123, "name" => "beam.smp"}]
      }
    }
  end

  defp snmp_envelope do
    %{
      "schema" => "serviceradar.snmp.interface_metric.v1",
      "source" => "snmp-metrics",
      "timestamp" => "2026-06-12T00:00:00Z",
      "gateway_id" => "gateway-1",
      "agent_id" => "agent-1",
      "partition" => "default",
      "metric_name" => "ifHCInOctets",
      "metric_type" => "snmp",
      "value" => 1234.5,
      "target_device_ip" => "10.0.0.20",
      "if_index" => 7,
      "tags" => %{"target" => "10.0.0.20", "interface_uid" => "ifindex:7"},
      "metadata" => %{"oid" => ".1.3.6.1.2.1.31.1.1.1.6.7"}
    }
  end

  defp plugin_metric_envelope do
    %{
      "schema" => "serviceradar.metric.v1",
      "source" => "plugin-result",
      "timestamp" => "2026-06-13T18:20:00Z",
      "gateway_id" => "gateway-1",
      "agent_id" => "agent-1",
      "partition" => "default",
      "metric_name" => "proxmox_guest_cpu_ratio_max",
      "metric_type" => "cpu",
      "value" => 0.91,
      "unit" => "ratio",
      "tags" => %{"producer_id" => "proxmox-inventory", "producer_kind" => "plugin_result"},
      "metadata" => %{"status" => "WARNING"}
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end

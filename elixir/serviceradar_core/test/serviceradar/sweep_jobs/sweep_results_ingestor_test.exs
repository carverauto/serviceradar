defmodule ServiceRadar.SweepJobs.SweepResultsIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  test "build_host_results leaves device_id nil for unknown sweep hosts" do
    execution_id = Ash.UUID.generate()

    results = [
      %{
        "host_ip" => "10.0.0.1",
        "hostname" => "known-host",
        "icmp_available" => true,
        "tcp_ports_open" => [22, 443]
      },
      %{
        "host_ip" => "10.0.0.2",
        "hostname" => "unknown-host",
        "icmp_available" => false,
        "error" => "timeout"
      }
    ]

    device_map = %{
      "10.0.0.1" => %{canonical_device_id: "device-1"}
    }

    {records, stats} = SweepResultsIngestor.build_host_results(results, execution_id, device_map)

    assert stats.hosts_total == 2
    assert stats.hosts_available == 1
    assert stats.hosts_failed == 1

    known_record = Enum.find(records, &(&1.ip == "10.0.0.1"))
    unknown_record = Enum.find(records, &(&1.ip == "10.0.0.2"))

    assert known_record.device_id == "device-1"
    assert known_record.status == :available

    assert unknown_record.device_id == nil
    assert unknown_record.status == :error
  end
end

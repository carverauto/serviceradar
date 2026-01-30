defmodule ServiceRadar.SweepJobs.SweepResultsIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  describe "build_host_results/3" do
    test "leaves device_id nil for unknown sweep hosts" do
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

    test "parses response_time_ms from icmp_response_time_ns" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => true,
          "icmp_response_time_ns" => 5_000_000  # 5ms in nanoseconds
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.response_time_ms == 5
    end

    test "parses response_time_ms from camelCase icmpResponseTimeNs" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => true,
          "icmpResponseTimeNs" => 8_000_000  # 8ms in nanoseconds
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.response_time_ms == 8
    end

    test "response_time_ms is nil when not provided" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => true
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.response_time_ms == nil
    end

    test "response_time_ms is 0 when response_time_ns is 0" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => false,
          "icmp_response_time_ns" => 0
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.response_time_ms == 0
    end
  end

  describe "availability status" do
    test "marks host as available when icmp_available is true" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => true
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :available
      assert stats.hosts_available == 1
      assert stats.hosts_failed == 0
    end

    test "marks host as unavailable when icmp_available is false" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => false
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :unavailable
      assert stats.hosts_available == 0
      assert stats.hosts_failed == 1
    end

    test "marks host as error when error field is present" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => false,
          "error" => "connection timeout"
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :error
      assert record.error_message == "connection timeout"
    end
  end

  describe "open_ports parsing" do
    test "parses tcp_ports_open array" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => true,
          "tcp_ports_open" => [22, 80, 443]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == [22, 80, 443]
    end

    test "parses camelCase tcpPortsOpen" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => true,
          "tcpPortsOpen" => [3389, 5900]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == [3389, 5900]
    end

    test "returns empty list when no ports are open" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "icmp_available" => true
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == []
    end
  end
end

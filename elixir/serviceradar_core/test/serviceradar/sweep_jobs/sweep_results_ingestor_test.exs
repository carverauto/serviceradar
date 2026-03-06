defmodule ServiceRadar.SweepJobs.SweepResultsIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  describe "build_host_results/3" do
    test "leaves device_id nil for unavailable unknown sweep hosts" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "hostname" => "known-host",
          "available" => true,
          "port_results" => [
            %{"port" => 22, "available" => true, "response_time" => 1_000_000},
            %{"port" => 443, "available" => true, "response_time" => 1_200_000}
          ]
        },
        %{
          "host_ip" => "10.0.0.2",
          "hostname" => "unknown-host",
          "available" => false,
          "error" => "timeout"
        }
      ]

      device_map = %{
        "10.0.0.1" => %{canonical_device_id: "device-1"}
      }

      {records, stats} =
        SweepResultsIngestor.build_host_results(results, execution_id, device_map)

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
          "available" => true,
          # 5ms in nanoseconds
          "icmp_response_time_ns" => 5_000_000
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
          "available" => true,
          # 8ms in nanoseconds
          "icmpResponseTimeNs" => 8_000_000
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.response_time_ms == 8
    end

    test "parses response_time_ms from response_time (HostResult format)" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true,
          # Go's time.Duration serializes to nanoseconds
          # 12ms in nanoseconds
          "response_time" => 12_000_000
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.response_time_ms == 12
    end

    test "response_time_ms is nil when not provided" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.response_time_ms == nil
    end

    test "response_time_ms is nil when response_time_ns is 0" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "icmp_response_time_ns" => 0
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      # 0ns means no response was received, should be nil not 0
      assert record.response_time_ms == nil
    end

    test "sub-millisecond response times round up to 1ms" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true,
          # 500 microseconds = 500,000 nanoseconds (sub-millisecond)
          "icmp_response_time_ns" => 500_000
        },
        %{
          "host_ip" => "10.0.0.2",
          "available" => true,
          # 100 microseconds = 100,000 nanoseconds
          "icmp_response_time_ns" => 100_000
        },
        %{
          "host_ip" => "10.0.0.3",
          "available" => true,
          # 999 microseconds = 999,000 nanoseconds (just under 1ms)
          "icmp_response_time_ns" => 999_000
        }
      ]

      {records, _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      # All sub-millisecond times should round up to 1ms (not 0)
      for record <- records do
        assert record.response_time_ms == 1,
               "Expected 1ms for #{record.ip}, got #{record.response_time_ms}ms"
      end
    end

    test "response times >= 1ms are preserved correctly" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true,
          # Exactly 1ms
          "icmp_response_time_ns" => 1_000_000
        },
        %{
          "host_ip" => "10.0.0.2",
          "available" => true,
          # 1.5ms should truncate to 1ms (integer division)
          "icmp_response_time_ns" => 1_500_000
        },
        %{
          "host_ip" => "10.0.0.3",
          "available" => true,
          # 2ms
          "icmp_response_time_ns" => 2_000_000
        }
      ]

      {records, _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      record1 = Enum.find(records, &(&1.ip == "10.0.0.1"))
      record2 = Enum.find(records, &(&1.ip == "10.0.0.2"))
      record3 = Enum.find(records, &(&1.ip == "10.0.0.3"))

      assert record1.response_time_ms == 1
      assert record2.response_time_ms == 1
      assert record3.response_time_ms == 2
    end
  end

  describe "availability status" do
    test "marks host as available when available is true" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :available
      assert stats.hosts_available == 1
      assert stats.hosts_failed == 0
    end

    test "marks host as unavailable when available is false" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false
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
          "available" => false,
          "error" => "connection timeout"
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :error
      assert record.error_message == "connection timeout"
    end
  end

  describe "open_ports parsing" do
    test "returns empty list when no ports are open" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == []
    end

    test "extracts open ports from Go port_results format" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true,
          "port_results" => [
            %{"port" => 22, "available" => true, "response_time" => 1_000_000},
            %{"port" => 80, "available" => false, "response_time" => 0},
            %{"port" => 443, "available" => true, "response_time" => 2_000_000}
          ]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == [22, 443]
    end

    test "returns empty list when all ports in port_results are unavailable" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "port_results" => [
            %{"port" => 22, "available" => false, "response_time" => 0},
            %{"port" => 80, "available" => false, "response_time" => 0}
          ]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == []
    end

    test "extracts open ports from canonical port_results only" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true,
          "port_results" => [
            %{"port" => 80, "available" => true, "response_time" => 1_000_000}
          ]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == [80]
    end
  end

  describe "composite availability" do
    test "host is available when composite available field is true (Go HostResult format)" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true,
          "icmp_status" => %{"available" => false},
          "port_results" => [
            %{"port" => 80, "available" => true, "response_time" => 1_000_000}
          ]
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :available
      assert stats.hosts_available == 1
    end

    test "host is unavailable when all checks fail" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "icmp_status" => %{"available" => false},
          "port_results" => [
            %{"port" => 22, "available" => false, "response_time" => 0},
            %{"port" => 80, "available" => false, "response_time" => 0}
          ]
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :unavailable
      assert stats.hosts_failed == 1
    end

    test "sweep_modes_results reflects actual ICMP and TCP status" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true,
          "icmp_status" => %{"available" => false, "round_trip" => 0},
          "port_results" => [
            %{"port" => 80, "available" => true, "response_time" => 1_000_000}
          ]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.sweep_modes_results["icmp"] == "failed"
      assert record.sweep_modes_results["tcp"] == "success"
    end

    test "sweep_modes_results shows ICMP success when icmp_status available" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => true,
          "icmp_status" => %{"available" => true, "round_trip" => 5_000_000},
          "port_results" => [
            %{"port" => 22, "available" => false, "response_time" => 0}
          ]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.sweep_modes_results["icmp"] == "success"
      assert record.sweep_modes_results["tcp"] == "no_response"
    end
  end
end

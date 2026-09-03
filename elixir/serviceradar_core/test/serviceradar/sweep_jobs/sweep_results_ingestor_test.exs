defmodule ServiceRadar.SweepJobs.SweepResultsIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  describe "duplicate_device_conflict?/1" do
    test "recognizes active IP unique index conflicts wrapped by Ash unknown errors" do
      reason =
        Ash.Error.Unknown.exception(
          errors: [
            Ash.Error.Unknown.UnknownError.exception(
              error: """
              ** (Ecto.ConstraintError) constraint error when attempting to insert struct:

                  * "ocsf_devices_unique_active_ip_idx" (unique_constraint)
              """
            )
          ]
        )

      assert SweepResultsIngestor.duplicate_device_conflict?(reason)
    end

    test "recognizes identity uniqueness validation errors" do
      assert SweepResultsIngestor.duplicate_device_conflict?([
               %{field: :uid, message: "has already been taken"}
             ])
    end

    test "does not classify unrelated provisional create failures as duplicates" do
      refute SweepResultsIngestor.duplicate_device_conflict?([
               %{field: :hostname, message: "is invalid"}
             ])
    end
  end

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

    test "records scanned ports alongside open ports" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "192.168.1.10",
          "available" => true,
          "port_results" => [
            %{"port" => 443, "available" => true},
            %{"port" => 3001, "available" => false},
            %{"port" => 4502, "available" => false}
          ]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == [443]
      assert record.scanned_ports == [443, 3001, 4502]
    end

    test "a host refusing every port is distinguishable from an ICMP-only host" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "192.168.1.11",
          "available" => false,
          "port_results" => [%{"port" => 3001, "available" => false}]
        },
        %{"host_ip" => "192.168.1.12", "available" => true, "icmp_available" => true}
      ]

      {[refused, icmp_only], _stats} =
        SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert refused.open_ports == []
      assert refused.scanned_ports == [3001]
      assert icmp_only.open_ports == []
      assert icmp_only.scanned_ports == []
    end

    test "stamps the vantage point and sweep group on the result" do
      execution_id = Ash.UUID.generate()
      group_id = Ash.UUID.generate()

      results = [%{"host_ip" => "192.168.1.13", "available" => true}]

      {[record], _stats} =
        SweepResultsIngestor.build_host_results(results, execution_id, %{},
          agent_id: "agent-a",
          sweep_group_id: group_id
        )

      assert record.agent_id == "agent-a"
      assert record.sweep_group_id == group_id
    end

    test "omitted context leaves identity nil rather than crashing" do
      execution_id = Ash.UUID.generate()
      results = [%{"host_ip" => "192.168.1.14", "available" => true}]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.agent_id == nil
      assert record.sweep_group_id == nil
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

    test "extracts open ports from flattened tcp_ports_open fields" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "icmp_status" => %{"available" => false},
          "tcp_ports_open" => [445, "3389", 70_000, "bad"]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == [445, 3389]
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

    test "host is available when ICMP succeeds even if aggregate available is false" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "icmp_status" => %{"available" => true, "round_trip" => 5_000_000},
          "port_results" => [
            %{"port" => 22, "available" => false, "response_time" => 0}
          ]
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :available
      assert record.sweep_modes_results["icmp"] == "success"
      assert stats.hosts_available == 1
      assert stats.hosts_failed == 0
    end

    test "host is available when TCP succeeds even if aggregate available is false" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "icmp_status" => %{"available" => false, "round_trip" => 0},
          "port_results" => [
            %{"port" => 22, "available" => false, "response_time" => 0},
            %{"port" => 443, "available" => true, "response_time" => 1_000_000}
          ]
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :available
      assert record.open_ports == [443]
      assert record.sweep_modes_results["tcp"] == "success"
      assert stats.hosts_available == 1
      assert stats.hosts_failed == 0
    end

    test "host is available when flattened TCP open ports are present" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "icmp_status" => %{"available" => false, "round_trip" => 0},
          "tcp_ports_open" => [445, 3389, 5985]
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :available
      assert record.open_ports == [445, 3389, 5985]
      assert record.sweep_modes_results["tcp"] == "success"
      assert stats.hosts_available == 1
      assert stats.hosts_failed == 0
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

    test "TCP-only failure marks the host unavailable without inventing an ICMP failure" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "sweep_modes" => ["tcp"],
          "port_results" => [
            %{"port" => 22, "available" => false, "response_time" => 0}
          ]
        }
      ]

      {[record], stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :unavailable
      refute Map.has_key?(record.sweep_modes_results, "icmp")
      assert record.sweep_modes_results["tcp"] == "no_response"
      assert stats.hosts_failed == 1
    end

    test "legacy TCP fields do not invent an ICMP failure" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.1",
          "available" => false,
          "tcp_ports_open" => []
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.sweep_modes_results["tcp"] == "no_response"
      refute Map.has_key?(record.sweep_modes_results, "icmp")
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

    test "sweep_modes_results uses icmp_available when icmp_status is omitted" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.2",
          "available" => true,
          "icmp_available" => true,
          "icmp_response_time_ns" => 6_000_000,
          "port_results" => []
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :available
      assert record.response_time_ms == 6
      assert record.sweep_modes_results["icmp"] == "success"
      refute Map.has_key?(record.sweep_modes_results, "tcp")
    end

    test "sweep_modes_results infers legacy ICMP success from host response time" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => "10.0.0.2",
          "available" => true,
          "response_time" => 7_000_000,
          "port_results" => []
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.status == :available
      assert record.response_time_ms == 7
      assert record.sweep_modes_results["icmp"] == "success"
      refute Map.has_key?(record.sweep_modes_results, "tcp")
    end
  end

  describe "banner_grab_audit_summary/1 counter sanitisation" do
    test "drops allowlisted keys whose values fail type validation" do
      summary = %{
        # valid values — kept verbatim
        "sweep_banner_grab_probes_total" => 7,
        "sweep_banner_grab_matches_total" => 0,
        # hostile values on allowlisted keys — must be dropped from `counters`
        "sweep_banner_grab_errors_total" => -1,
        "sweep_banner_grab_bytes_received_total" => 1.5,
        "sweep_banner_grab_timeout_total" => "not-a-number",
        "sweep_banner_grab_connection_reset_total" => %{"$inject" => "payload"},
        "sweep_banner_grab_empty_response_total" => [1, 2, 3],
        # non-allowlisted key — must be filtered out
        "attacker_controlled_blob" => "drop-me"
      }

      audited = SweepResultsIngestor.banner_grab_audit_summary(summary)
      counters = audited["counters"]

      # Valid allowlisted values survive
      assert counters["sweep_banner_grab_probes_total"] == 7
      assert counters["sweep_banner_grab_matches_total"] == 0

      # Hostile values on allowlisted keys are dropped from the persisted map
      refute Map.has_key?(counters, "sweep_banner_grab_errors_total")
      refute Map.has_key?(counters, "sweep_banner_grab_bytes_received_total")
      refute Map.has_key?(counters, "sweep_banner_grab_timeout_total")
      refute Map.has_key?(counters, "sweep_banner_grab_connection_reset_total")
      refute Map.has_key?(counters, "sweep_banner_grab_empty_response_total")

      # Non-allowlisted keys never make it into the persisted map
      refute Map.has_key?(counters, "attacker_controlled_blob")

      # Derived fields stay integers regardless of upstream hostility
      assert is_integer(audited["probe_count"])
      assert is_integer(audited["banner_match_count"])
      assert is_integer(audited["empty_response_count"])
      assert is_integer(audited["error_count"])
      assert is_integer(audited["total_bytes_received"])
    end

    test "emits :counter_dropped telemetry for each hostile allowlisted value" do
      test_pid = self()
      handler_id = "ingestor-counter-dropped-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :sweep, :banner_grab, :counter_dropped],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> _ = :telemetry.detach(handler_id) end)

      summary = %{
        "sweep_banner_grab_errors_total" => -1,
        "sweep_banner_grab_bytes_received_total" => 1.5,
        "sweep_banner_grab_timeout_total" => "not-a-number"
      }

      _ = SweepResultsIngestor.banner_grab_audit_summary(summary)

      assert_receive {:telemetry_event, [:serviceradar, :sweep, :banner_grab, :counter_dropped],
                      %{count: 1, banner_grab_counter_dropped_total: 1},
                      %{
                        counter_key: "sweep_banner_grab_errors_total",
                        expected_type: :non_neg_integer,
                        value_type: :integer
                      }}

      assert_receive {:telemetry_event, [:serviceradar, :sweep, :banner_grab, :counter_dropped],
                      _measurements,
                      %{
                        counter_key: "sweep_banner_grab_bytes_received_total",
                        expected_type: :non_neg_integer,
                        value_type: :float
                      }}

      assert_receive {:telemetry_event, [:serviceradar, :sweep, :banner_grab, :counter_dropped],
                      _measurements,
                      %{
                        counter_key: "sweep_banner_grab_timeout_total",
                        expected_type: :non_neg_integer,
                        value_type: :binary
                      }}
    end
  end

  describe "record_banner_grab_audit_failure/4 telemetry" do
    test "emits :audit_failed event with operation, ids, and reason metadata" do
      test_pid = self()
      handler_id = "ingestor-audit-failed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :sweep, :banner_grab, :audit_failed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> _ = :telemetry.detach(handler_id) end)

      execution_id = Ash.UUID.generate()
      sweep_group_id = Ash.UUID.generate()
      reason = %Ash.Error.Invalid{errors: [%{field: :banner_grab_summary, message: "boom"}]}

      :ok =
        SweepResultsIngestor.record_banner_grab_audit_failure(
          :update_failed,
          execution_id,
          sweep_group_id,
          reason
        )

      assert_receive {:telemetry_event, [:serviceradar, :sweep, :banner_grab, :audit_failed],
                      %{count: 1, banner_grab_audit_failed_total: 1}, metadata}

      assert metadata.operation == :update_failed
      assert metadata.execution_id == execution_id
      assert metadata.sweep_group_id == sweep_group_id
      assert is_binary(metadata.reason)
      assert metadata.reason =~ "boom"
    end
  end
end

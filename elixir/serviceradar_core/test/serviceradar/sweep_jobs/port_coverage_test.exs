defmodule ServiceRadar.SweepJobs.PortCoverageTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.PortCoverage

  @moduletag :db_free

  describe "scanned_ports/1" do
    test "records every attempted port, open or not" do
      result = %{
        "port_results" => [
          %{"port" => 443, "available" => true},
          %{"port" => 3001, "available" => false},
          %{"port" => 4502, "available" => false}
        ]
      }

      assert PortCoverage.scanned_ports(result) == [443, 3001, 4502]
    end

    test "a host that refuses every port still reports coverage" do
      result = %{
        "port_results" => [
          %{"port" => 3001, "available" => false},
          %{"port" => 4502, "available" => false}
        ]
      }

      assert PortCoverage.scanned_ports(result) == [3001, 4502]
    end

    test "an ICMP-only result scans no ports" do
      assert PortCoverage.scanned_ports(%{"icmp_available" => true}) == []
    end

    test "an open port is always a scanned port even without port_results" do
      assert PortCoverage.scanned_ports(%{"tcp_ports_open" => [22, 80]}) == [22, 80]
    end

    test "accepts the camelCase and legacy payload keys" do
      assert PortCoverage.scanned_ports(%{"portScanResults" => [%{"port" => 22}]}) == [22]
      assert PortCoverage.scanned_ports(%{"port_scan_results" => [%{"port" => 23}]}) == [23]
    end

    test "parses string ports and rejects garbage and out-of-range values" do
      result = %{
        "port_results" => [
          %{"port" => "443"},
          %{"port" => "not-a-port"},
          %{"port" => 0},
          %{"port" => 65_536},
          %{"port" => nil},
          %{"available" => true}
        ]
      }

      assert PortCoverage.scanned_ports(result) == [443]
    end

    test "deduplicates and sorts" do
      result = %{
        "port_results" => [%{"port" => 443}, %{"port" => 22}, %{"port" => 443}],
        "tcp_ports_open" => [22]
      }

      assert PortCoverage.scanned_ports(result) == [22, 443]
    end

    test "tolerates a malformed port_results payload" do
      assert PortCoverage.scanned_ports(%{"port_results" => "unexpected"}) == []
      assert PortCoverage.scanned_ports(%{}) == []
    end
  end
end

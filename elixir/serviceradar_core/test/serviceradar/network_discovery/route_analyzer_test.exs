defmodule ServiceRadar.NetworkDiscovery.RouteAnalyzerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.RouteAnalyzer

  test "returns delivered for connected route" do
    routes = %{
      "sr:a" => [
        %{prefix: "192.168.1.0/24", next_hops: []}
      ]
    }

    assert {:ok, result} = RouteAnalyzer.analyze(routes, "sr:a", "192.168.1.40")
    assert result.status == :delivered
    assert result.reason == "connected_or_terminal_route"
    assert length(result.hops) == 1
    assert hd(result.hops).selected_prefix == "192.168.1.0/24"
  end

  test "returns delivered with ECMP branches and deterministic next hop walk" do
    routes = %{
      "sr:a" => [
        %{
          prefix: "10.10.0.0/16",
          next_hops: [
            %{target_device_id: "sr:c", next_hop_ip: "10.0.0.3"},
            %{target_device_id: "sr:b", next_hop_ip: "10.0.0.2"}
          ]
        }
      ],
      "sr:b" => [
        %{prefix: "10.10.20.0/24", next_hops: []}
      ],
      "sr:c" => [
        %{prefix: "10.10.20.0/24", next_hops: []}
      ]
    }

    assert {:ok, result} = RouteAnalyzer.analyze(routes, "sr:a", "10.10.20.8")
    assert result.status == :delivered
    assert length(result.hops) == 2
    [first_hop | _] = result.hops
    assert first_hop.device_id == "sr:a"
    assert length(first_hop.ecmp_branches) == 2
    assert Enum.any?(first_hop.ecmp_branches, &(&1.target_device_id == "sr:b"))
    assert Enum.any?(first_hop.ecmp_branches, &(&1.target_device_id == "sr:c"))
  end

  test "returns loop when recursive path revisits node" do
    routes = %{
      "sr:a" => [
        %{prefix: "172.16.0.0/16", next_hops: [%{target_device_id: "sr:b"}]}
      ],
      "sr:b" => [
        %{prefix: "172.16.0.0/16", next_hops: [%{target_device_id: "sr:a"}]}
      ]
    }

    assert {:ok, result} = RouteAnalyzer.analyze(routes, "sr:a", "172.16.2.5")
    assert result.status == :loop
    assert result.reason == "loop_detected"
    assert length(result.hops) == 2
  end

  test "returns blackhole when no matching route exists" do
    routes = %{
      "sr:a" => [
        %{prefix: "10.0.0.0/24", next_hops: []}
      ]
    }

    assert {:ok, result} = RouteAnalyzer.analyze(routes, "sr:a", "192.0.2.10")
    assert result.status == :blackhole
    assert result.reason == "no_matching_route"
    assert result.terminal_device_id == "sr:a"
  end
end

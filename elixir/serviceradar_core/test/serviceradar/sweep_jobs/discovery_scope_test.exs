defmodule ServiceRadar.SweepJobs.DiscoveryScopeTest do
  @moduledoc """
  Which answering hosts a sweep group may add to inventory. Every address is a
  documentation address (RFC 5737, RFC 3849); IPv6 ones are built from integers.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.DiscoveryScope
  alias ServiceRadar.SweepJobs.SweepGroup

  defp group(attrs) do
    struct!(SweepGroup, Map.merge(%{discover_new_devices: true, static_targets: []}, attrs))
  end

  defp v6(last), do: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, last} |> :inet.ntoa() |> to_string()

  test "a group with no static targets seeds nothing" do
    ips = ["198.51.100.10", "203.0.113.10"]

    assert DiscoveryScope.partition(group(%{}), ips) == {[], ips, :outside_static_targets}
  end

  test "a group with discovery off seeds nothing, even inside its static targets" do
    ips = ["198.51.100.10"]

    assert DiscoveryScope.partition(
             group(%{discover_new_devices: false, static_targets: ["198.51.100.0/24"]}),
             ips
           ) == {[], ips, :discovery_off}
  end

  test "an unresolved group seeds nothing" do
    assert DiscoveryScope.partition(nil, ["198.51.100.10"]) ==
             {[], ["198.51.100.10"], :outside_static_targets}
  end

  test "CIDRs, single addresses and inclusive ranges each cover their hosts" do
    scope =
      group(%{
        static_targets: ["198.51.100.0/25", "203.0.113.7", "192.0.2.10-192.0.2.20"]
      })

    inside = ["198.51.100.1", "198.51.100.127", "203.0.113.7", "192.0.2.10", "192.0.2.20"]
    outside = ["198.51.100.128", "203.0.113.8", "192.0.2.9", "192.0.2.21"]

    assert DiscoveryScope.partition(scope, inside ++ outside) ==
             {inside, outside, :outside_static_targets}
  end

  test "IPv6 CIDRs and ranges cover only same-family hosts" do
    scope =
      group(%{
        static_targets: [v6(0) <> "/120", v6(0x1000) <> "-" <> v6(0x1010)]
      })

    inside = [v6(0x00FF), v6(0x1000), v6(0x1010)]
    outside = [v6(0x0100), v6(0x1011), "198.51.100.10"]

    assert DiscoveryScope.partition(scope, inside ++ outside) ==
             {inside, outside, :outside_static_targets}
  end

  test "entries that do not parse cover nothing" do
    scope =
      group(%{
        static_targets: [
          "not-an-address",
          "192.0.2.20-192.0.2.10",
          "192.0.2.1-" <> v6(1),
          "192.0.2.0/33",
          "192.0.2"
        ]
      })

    ips = ["192.0.2.1", "192.0.2.15", "not-an-ip"]

    assert DiscoveryScope.partition(scope, ips) == {[], ips, :outside_static_targets}
  end
end

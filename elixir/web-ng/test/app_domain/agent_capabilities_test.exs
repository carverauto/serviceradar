defmodule ServiceRadarWebNG.AgentCapabilitiesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.AgentCapabilities

  @moduletag :db_free

  test "separates negative availability markers from usable capabilities" do
    assert AgentCapabilities.summarize([
             :icmp,
             "host-network-visibility",
             "host-network-visibility.dpi.unavailable",
             "sweep.banner_grab.unavailable"
           ]) == %{
             available: ["icmp", "host-network-visibility"],
             unavailable: [
               "host-network-visibility.dpi.unavailable",
               "sweep.banner_grab.unavailable"
             ],
             total: 4
           }
  end

  test "trims, deduplicates, and rejects invalid advertisements" do
    assert AgentCapabilities.summarize([" icmp ", "icmp", "", nil, 42]) == %{
             available: ["icmp"],
             unavailable: [],
             total: 1
           }
  end
end

defmodule ServiceRadarWebNG.Topology.GodViewStreamConversionTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.GodViewStream

  test "octets_rate_to_bps/1 converts bytes-per-second to bits-per-second" do
    assert GodViewStream.octets_rate_to_bps(1) == 8
    assert GodViewStream.octets_rate_to_bps(1_000) == 8_000
    assert GodViewStream.octets_rate_to_bps(125_000) == 1_000_000
  end

  test "octets_rate_to_bps/1 guards invalid values" do
    assert GodViewStream.octets_rate_to_bps(0) == 0
    assert GodViewStream.octets_rate_to_bps(-1) == 0
    assert GodViewStream.octets_rate_to_bps(nil) == 0
  end
end

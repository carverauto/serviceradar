defmodule ServiceRadarWebNGWeb.NetflowVisualizeStateTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState

  test "encode/decode round-trip is deterministic" do
    state = %{
      "graph" => "sankey",
      "units" => "bps",
      "time" => "last_6h",
      "dims" => ["src_ip", "dst_ip"],
      "limit" => 25,
      "limit_type" => "max",
      "truncate_v4" => 24,
      "truncate_v6" => 64,
      "bidirectional" => true,
      "previous_period" => false
    }

    assert {:ok, encoded} = NFState.encode_param(state)
    assert String.starts_with?(encoded, "v1-")

    assert {:ok, decoded} = NFState.decode_param(encoded)
    assert decoded == Map.merge(NFState.default(), state)

    assert {:ok, encoded2} = NFState.encode_param(decoded)
    assert encoded2 == encoded
  end

  test "invalid version falls back to error" do
    assert {:error, :unsupported_version} = NFState.decode_param("v2-abc")
  end
end

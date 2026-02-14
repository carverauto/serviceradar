defmodule ServiceRadarWebNG.Topology.GodViewStreamTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.GodViewStream

  test "latest_snapshot/0 returns binary payload with expected header" do
    assert {:ok, %{snapshot: snapshot, payload: payload}} = GodViewStream.latest_snapshot()

    assert is_binary(payload)
    assert byte_size(payload) > 16
    assert binary_part(payload, 0, 6) == "ARROW1"
    assert binary_part(payload, byte_size(payload) - 6, 6) == "ARROW1"
    assert snapshot.schema_version > 0
    assert snapshot.revision > 0
  end
end

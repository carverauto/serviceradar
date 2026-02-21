defmodule ServiceRadarWebNG.Topology.GodViewSnapshotTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.GodViewSnapshot

  test "validate/1 accepts a valid snapshot envelope" do
    snapshot = %{
      schema_version: GodViewSnapshot.schema_version(),
      revision: 42,
      generated_at: DateTime.utc_now(),
      nodes: [%{"id" => "node-1"}],
      edges: [%{"source" => "node-1", "target" => "node-2"}],
      causal_bitmaps: %{
        root_cause: <<1, 0, 0, 1>>,
        affected: <<0, 1, 1, 0>>,
        healthy: <<1, 1, 1, 1>>,
        unknown: <<0, 0, 0, 0>>
      },
      bitmap_metadata: %{
        root_cause: %{bytes: 4, count: 2},
        affected: %{bytes: 4, count: 2},
        healthy: %{bytes: 4, count: 4},
        unknown: %{bytes: 4, count: 0}
      }
    }

    assert :ok = GodViewSnapshot.validate(snapshot)
  end

  test "validate/1 rejects unsupported schema versions" do
    snapshot = %{
      schema_version: 999,
      revision: 1,
      generated_at: DateTime.utc_now(),
      nodes: [],
      edges: [],
      causal_bitmaps: %{healthy: <<1>>},
      bitmap_metadata: %{}
    }

    assert {:error, {:unsupported_schema, 999}} = GodViewSnapshot.validate(snapshot)
  end

  test "validate/1 rejects missing required keys" do
    snapshot = %{
      schema_version: GodViewSnapshot.schema_version(),
      revision: 1
    }

    assert {:error, {:missing_keys, missing}} = GodViewSnapshot.validate(snapshot)
    assert :generated_at in missing
    assert :causal_bitmaps in missing
    assert :bitmap_metadata in missing
  end
end

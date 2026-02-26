defmodule ServiceRadarWebNG.Topology.GodViewSnapshotTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.GodViewSnapshot

  test "validate/1 accepts a valid snapshot envelope" do
    snapshot = %{
      schema_version: GodViewSnapshot.schema_version(),
      revision: 42,
      generated_at: DateTime.utc_now(),
      nodes: [%{"id" => "node-1"}],
      edges: [
        %{
          source: "node-1",
          target: "node-2",
          flow_pps: 11,
          flow_bps: 1_100,
          flow_pps_ab: 7,
          flow_pps_ba: 4,
          flow_bps_ab: 700,
          flow_bps_ba: 400,
          capacity_bps: 1_000_000_000,
          telemetry_eligible: true,
          protocol: "snmp-l2",
          evidence_class: "direct",
          confidence_tier: "high",
          local_if_index_ab: 1,
          local_if_name_ab: "eth1",
          local_if_index_ba: 2,
          local_if_name_ba: "eth2"
        }
      ],
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

  test "validate/1 rejects edges that miss canonical contract keys" do
    snapshot = %{
      schema_version: GodViewSnapshot.schema_version(),
      revision: 1,
      generated_at: DateTime.utc_now(),
      nodes: [],
      edges: [%{source: "node-1", target: "node-2"}],
      causal_bitmaps: %{healthy: <<1>>},
      bitmap_metadata: %{}
    }

    assert {:error, {:invalid_edge_schema, 0, {:missing_keys, missing}}} =
             GodViewSnapshot.validate(snapshot)

    assert :flow_pps in missing
    assert :flow_pps_ab in missing
    assert :telemetry_eligible in missing
    assert :local_if_index_ab in missing
  end

  test "validate/1 rejects edges with invalid canonical values" do
    snapshot = %{
      schema_version: GodViewSnapshot.schema_version(),
      revision: 1,
      generated_at: DateTime.utc_now(),
      nodes: [],
      edges: [
        %{
          source: "node-1",
          target: "node-1",
          flow_pps: -1,
          flow_bps: 100,
          flow_pps_ab: 1,
          flow_pps_ba: 1,
          flow_bps_ab: 10,
          flow_bps_ba: 10,
          capacity_bps: 1_000,
          telemetry_eligible: "yes",
          protocol: "snmp-l2",
          evidence_class: "direct",
          confidence_tier: "high",
          local_if_index_ab: -2,
          local_if_name_ab: "eth1",
          local_if_index_ba: 1,
          local_if_name_ba: "eth2"
        }
      ],
      causal_bitmaps: %{healthy: <<1>>},
      bitmap_metadata: %{}
    }

    assert {:error, {:invalid_edge_schema, 0, {:invalid_values, reasons}}} =
             GodViewSnapshot.validate(snapshot)

    assert :source_target_equal in reasons
    assert :flow_pps in reasons
    assert :telemetry_eligible in reasons
    assert :local_if_index_ab in reasons
  end
end

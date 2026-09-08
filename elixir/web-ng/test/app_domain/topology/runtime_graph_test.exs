defmodule ServiceRadarWebNG.Topology.RuntimeGraphTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.RuntimeGraph

  @moduletag :db_free

  test "topology_links_query/0 reads canonical layered backbone plus mapper attachment evidence" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
    assert query =~ "MATCH (ai:Interface)-[r]->(bi:Interface)"
    assert query =~ "a.id STARTS WITH 'sr:'"
    assert query =~ "b.id STARTS WITH 'sr:'"
    assert query =~ "toUpper(coalesce(r.relation_type, '')) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON']"
    assert query =~ "type(r) IN ['ATTACHED_TO', 'OBSERVED_TO']"
    assert query =~ "MATCH (a:Device {id: ai.device_id})"
    assert query =~ "MATCH (b:Device {id: bi.device_id})"
    assert query =~ "observed_at: coalesce(r.last_observed_at, r.observed_at, '')"

    assert query =~
             "coalesce(r.relation_type, '') = '' AND toLower(coalesce(r.evidence_class, '')) IN ['direct', 'direct-physical', 'direct-logical', 'hosted-virtual']"
  end

  test "topology_links_query/0 stays on the canonical-plus-mapper read model even if legacy flag is set false" do
    original = Application.get_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology)

    try do
      Application.put_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology, false)
      query = RuntimeGraph.topology_links_query()
      assert query =~ "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
      assert query =~ "MATCH (ai:Interface)-[r]->(bi:Interface)"
    after
      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology)
      else
        Application.put_env(
          :serviceradar_web_ng,
          :god_view_backend_authoritative_topology,
          original
        )
      end
    end
  end

  test "topology_links_query/0 returns relation metadata and interface attribution" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "relation_type: coalesce(r.relation_type, type(r))"
    assert query =~ "WHEN toUpper(coalesce(r.relation_type, '')) = 'LOGICAL_PEER' THEN 'logical'"
    assert query =~ "WHEN toUpper(coalesce(r.relation_type, '')) = 'HOSTED_ON' THEN 'hosted'"
    assert query =~ "topology_plane: 'attachment'"
    assert query =~ "local_if_name: coalesce(r.local_if_name, '')"
    assert query =~ "local_if_index: r.local_if_index"
    assert query =~ "local_if_name_ab: coalesce(r.local_if_name_ab, r.local_if_name, '')"
    assert query =~ "local_if_index_ab: coalesce(r.local_if_index_ab, r.local_if_index)"
    assert query =~ "local_if_name_ba: coalesce(r.local_if_name_ba, r.neighbor_if_name, '')"
    assert query =~ "local_if_index_ba: coalesce(r.local_if_index_ba, r.neighbor_if_index)"
    assert query =~ "neighbor_if_name: coalesce(r.neighbor_if_name, '')"
    assert query =~ "neighbor_if_index: r.neighbor_if_index"
    assert query =~ "confidence_reason: coalesce(r.confidence_reason, '')"
    assert query =~ "flow_pps_ab: coalesce(r.flow_pps_ab, 0)"
    assert query =~ "flow_bps_ab: coalesce(r.flow_bps_ab, 0)"
    assert query =~ "telemetry_eligible: coalesce("
    assert query =~ "telemetry_source: coalesce(r.telemetry_source, 'none')"
    assert query =~ "telemetry_eligible: false"
    assert query =~ "telemetry_source: 'none'"
    assert query =~ "evidence_class: coalesce(r.evidence_class, 'endpoint-attachment')"
  end

  test "projection read action trusts initialized empty projections" do
    assert RuntimeGraph.projection_read_action({:ok, []}) == {:projected, []}

    assert RuntimeGraph.projection_read_action({:error, :projection_uninitialized}) ==
             :fallback_uninitialized

    assert RuntimeGraph.projection_read_action({:error, :boom}) == {:fallback_error, :boom}
  end

  test "topology_diagnostics_query/0 exposes canonical edge health counters" do
    query = RuntimeGraph.topology_diagnostics_query()

    assert query =~ "canonical_edges"
    assert query =~ "backbone_candidates"
    assert query =~ "attachment_candidates"
    assert query =~ "missing_relation_type"
    assert query =~ "missing_evidence_class"
    assert query =~ "missing_endpoint_ids"
    assert query =~ "non_canonical_endpoint_ids"
    assert query =~ "missing_observed_at"
  end

  test "virtualization_inventory_links_query/0 projects host-to-guest inventory as hosted topology" do
    query = RuntimeGraph.virtualization_inventory_links_query()

    assert query =~ "FROM platform.virtualization_guests g"
    assert query =~ "JOIN platform.virtualization_hosts h ON h.id = g.host_id"
    assert query =~ "LEFT JOIN platform.ocsf_devices hd ON hd.uid = h.device_uid"
    assert query =~ "LEFT JOIN platform.ocsf_devices gd ON gd.uid = g.device_uid"
    assert query =~ "'local_device_id', h.device_uid"
    assert query =~ "'neighbor_device_id', g.device_uid"
    assert query =~ "'local_if_name', 'hosted-guests'"
    assert query =~ "'evidence_class', 'hosted-virtual'"
    assert query =~ "'relation_type', 'HOSTED_ON'"
    assert query =~ "'topology_plane', 'hosted'"
    assert query =~ "'confidence_reason', 'authoritative_virtualization_inventory'"
    assert query =~ "'virtualization_provider', h.provider"
    assert query =~ "'virtualization_guest_vmid', g.vmid"

    # Guests can tie on timestamps and device ids, so the unique provider identity must be
    # complete before LIMIT rather than leaving provider_ref ambiguous across providers.
    assert [
             "COALESCE(g.observed_at, h.observed_at, g.updated_at, h.updated_at) DESC",
             "h.device_uid ASC",
             "g.device_uid ASC",
             "h.provider ASC",
             "h.provider_ref ASC",
             "g.provider ASC",
             "g.provider_ref ASC"
           ] = bounded_order_keys(query)

    assert query =~ "LIMIT $1"
  end

  test "runtime graph ingest/get preserves neighbor interface attribution" do
    graph = Native.runtime_graph_new()

    rows = [
      %{
        local_device_id: "sr:a",
        local_device_ip: "192.0.2.1",
        local_if_name: "eth0",
        local_if_index: 7,
        local_if_name_ab: "eth0.100",
        local_if_index_ab: 107,
        local_if_name_ba: "eth1.200",
        local_if_index_ba: 222,
        neighbor_if_name: "eth1",
        neighbor_if_index: 22,
        neighbor_device_id: "sr:b",
        neighbor_mgmt_addr: "192.0.2.2",
        neighbor_system_name: "device-b",
        protocol: "LLDP",
        confidence_tier: "high",
        confidence_reason: "direct_lldp_neighbor",
        flow_pps: 42,
        flow_bps: 4_200,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 30,
        flow_pps_ba: 12,
        flow_bps_ab: 3_000,
        flow_bps_ba: 1_200,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-25T10:00:00Z",
        metadata: %{
          source: "mapper_topology_v1",
          inference: "direct_lldp_neighbor",
          confidence_tier: "high",
          confidence_score: 95.0
        }
      }
    ]

    assert 1 == Native.runtime_graph_ingest_rows(graph, rows)

    [link] = Native.runtime_graph_get_links(graph)
    assert link.local_if_index == 7
    assert link.local_if_index_ab == 107
    assert link.local_if_name_ab == "eth0.100"
    assert link.local_if_index_ba == 222
    assert link.local_if_name_ba == "eth1.200"
    assert link.neighbor_if_index == 22
    assert link.local_if_name == "eth0"
    assert link.neighbor_if_name == "eth1"
    assert link.confidence_reason == "direct_lldp_neighbor"
    assert link.flow_pps == 42
    assert link.flow_bps == 4_200
    assert link.capacity_bps == 1_000_000_000
    assert link.flow_pps_ab == 30
    assert link.flow_pps_ba == 12
    assert link.flow_bps_ab == 3_000
    assert link.flow_bps_ba == 1_200
    assert link.telemetry_eligible == true
    assert link.telemetry_source == "interface"
  end

  test "canonical_runtime_row?/1 accepts canonical layered backbone rows and rejects inferred/non-canonical rows" do
    assert RuntimeGraph.canonical_runtime_row?(%{
             local_device_id: "sr:a",
             neighbor_device_id: "sr:b",
             evidence_class: "direct",
             metadata: %{"relation_type" => "CONNECTS_TO"}
           })

    assert RuntimeGraph.canonical_runtime_row?(%{
             local_device_id: "sr:a",
             neighbor_device_id: "sr:b",
             evidence_class: "direct-logical",
             metadata: %{"relation_type" => "LOGICAL_PEER"}
           })

    assert RuntimeGraph.canonical_runtime_row?(%{
             local_device_id: "sr:host",
             neighbor_device_id: "sr:guest",
             evidence_class: "hosted-virtual",
             metadata: %{"relation_type" => "HOSTED_ON"}
           })

    refute RuntimeGraph.canonical_runtime_row?(%{
             local_device_id: "sr:a",
             neighbor_device_id: "sr:b",
             evidence_class: "inferred",
             metadata: %{"relation_type" => "INFERRED_TO"}
           })

    refute RuntimeGraph.canonical_runtime_row?(%{
             local_device_id: "ip-192.168.1.1",
             neighbor_device_id: "sr:b",
             evidence_class: "direct",
             metadata: %{"relation_type" => "CONNECTS_TO"}
           })
  end

  test "runtime row classifiers distinguish backbone from attachment rows" do
    backbone_row = %{
      local_device_id: "sr:a",
      neighbor_device_id: "sr:b",
      evidence_class: "direct",
      metadata: %{"relation_type" => "CONNECTS_TO"}
    }

    attachment_row = %{
      local_device_id: "sr:a",
      neighbor_device_id: "sr:endpoint-b",
      evidence_class: "endpoint-attachment",
      metadata: %{"relation_type" => "OBSERVED_TO"}
    }

    inferred_row = %{
      local_device_id: "sr:a",
      neighbor_device_id: "sr:b",
      evidence_class: "inferred",
      metadata: %{"relation_type" => "INFERRED_TO"}
    }

    logical_row = %{
      local_device_id: "sr:a",
      neighbor_device_id: "sr:b",
      evidence_class: "direct-logical",
      metadata: %{"relation_type" => "LOGICAL_PEER"}
    }

    hosted_row = %{
      local_device_id: "sr:host",
      neighbor_device_id: "sr:guest",
      evidence_class: "hosted-virtual",
      metadata: %{"relation_type" => "HOSTED_ON"}
    }

    observed_row = %{
      local_device_id: "sr:a",
      neighbor_device_id: "sr:endpoint-b",
      evidence_class: "observed-only",
      metadata: %{"relation_type" => "OBSERVED_TO"}
    }

    assert RuntimeGraph.backbone_runtime_row?(backbone_row)
    refute RuntimeGraph.attachment_runtime_row?(backbone_row)

    assert RuntimeGraph.backbone_runtime_row?(logical_row)
    refute RuntimeGraph.attachment_runtime_row?(logical_row)

    assert RuntimeGraph.backbone_runtime_row?(hosted_row)
    refute RuntimeGraph.attachment_runtime_row?(hosted_row)

    assert RuntimeGraph.attachment_runtime_row?(attachment_row)
    refute RuntimeGraph.backbone_runtime_row?(attachment_row)

    assert RuntimeGraph.attachment_runtime_row?(observed_row)
    refute RuntimeGraph.backbone_runtime_row?(observed_row)

    refute RuntimeGraph.backbone_runtime_row?(inferred_row)
    refute RuntimeGraph.attachment_runtime_row?(inferred_row)
  end

  test "prioritize_runtime_rows/1 keeps backbone and inferred-segment rows first and bounds each row class" do
    backbone_rows =
      Enum.map(1..5_010, fn idx ->
        %{
          local_device_id: "sr:backbone-#{idx}",
          neighbor_device_id: "sr:backbone-peer-#{idx}",
          evidence_class: "direct",
          metadata: %{"relation_type" => "CONNECTS_TO"}
        }
      end)

    attachment_rows =
      Enum.map(1..2_010, fn idx ->
        %{
          local_device_id: "sr:attachment-#{idx}",
          neighbor_device_id: "sr:endpoint-#{idx}",
          evidence_class: "endpoint-attachment",
          metadata: %{"relation_type" => "ATTACHED_TO"}
        }
      end)

    inferred_segment_rows =
      Enum.map(1..2_010, fn idx ->
        %{
          local_device_id: "sr:inferred-segment-#{idx}",
          neighbor_device_id: "sr:inferred-segment-peer-#{idx}",
          evidence_class: "inferred-segment",
          metadata: %{"relation_type" => "ATTACHED_TO"}
        }
      end)

    prioritized =
      RuntimeGraph.prioritize_runtime_rows(backbone_rows ++ attachment_rows ++ inferred_segment_rows)

    assert length(prioritized) == 9_000
    assert Enum.count(prioritized, &RuntimeGraph.backbone_runtime_row?/1) == 5_000
    assert Enum.count(prioritized, &RuntimeGraph.attachment_runtime_row?/1) == 4_000

    assert Enum.count(prioritized, &(Map.get(&1, :evidence_class) == "inferred-segment")) ==
             2_000

    assert Enum.count(prioritized, &(Map.get(&1, :evidence_class) == "endpoint-attachment")) ==
             2_000

    assert Enum.all?(Enum.take(prioritized, 5_000), &RuntimeGraph.backbone_runtime_row?/1)

    assert Enum.all?(
             Enum.slice(prioritized, 5_000, 2_000),
             &(Map.get(&1, :evidence_class) == "inferred-segment")
           )

    assert Enum.all?(
             Enum.slice(prioritized, 7_000, 2_000),
             &(Map.get(&1, :evidence_class) == "endpoint-attachment")
           )
  end

  test "prioritize_runtime_rows/1 preserves the sole inferred-segment row outside a full ordinary attachment budget" do
    attachment_rows =
      Enum.map(1..2_000, fn idx ->
        %{
          local_device_id: "sr:attachment-#{idx}",
          neighbor_device_id: "sr:endpoint-#{idx}",
          evidence_class: "endpoint-attachment",
          metadata: %{"relation_type" => "ATTACHED_TO"}
        }
      end)

    inferred_segment_row = %{
      local_device_id: "sr:inferred-segment",
      neighbor_device_id: "sr:inferred-segment-peer",
      evidence_class: "inferred-segment",
      metadata: %{"relation_type" => "ATTACHED_TO"}
    }

    prioritized =
      RuntimeGraph.prioritize_runtime_rows(attachment_rows ++ [inferred_segment_row])

    assert hd(prioritized) == inferred_segment_row
    assert MapSet.new(tl(prioritized)) == MapSet.new(attachment_rows)
  end

  test "prioritize_runtime_rows/1 chooses the same bounded rows across input permutations" do
    backbone_rows =
      quota_rows(5_001, "backbone", "direct", "CONNECTS_TO")

    inferred_segment_rows =
      quota_rows(2_001, "inferred", "inferred-segment", "ATTACHED_TO")

    attachment_rows =
      quota_rows(2_001, "attachment", "endpoint-attachment", "ATTACHED_TO")

    rows = backbone_rows ++ inferred_segment_rows ++ attachment_rows
    rotated_rows = Enum.drop(rows, 3_137) ++ Enum.take(rows, 3_137)

    forward = RuntimeGraph.prioritize_runtime_rows(rows)
    reversed = RuntimeGraph.prioritize_runtime_rows(Enum.reverse(rows))
    rotated = RuntimeGraph.prioritize_runtime_rows(rotated_rows)

    assert runtime_row_identities(forward) == runtime_row_identities(reversed)
    assert runtime_row_identities(forward) == runtime_row_identities(rotated)
    assert length(forward) == 9_000

    refute Enum.any?(forward, &(&1.local_device_id == "sr:inferred-02001"))
  end

  test "refresh_due?/2 throttles repeated refresh attempts" do
    assert RuntimeGraph.refresh_due?(
             %{last_refresh_started_at_ms: nil, min_refresh_ms: 30_000},
             1_000
           )

    refute RuntimeGraph.refresh_due?(
             %{last_refresh_started_at_ms: 1_000, min_refresh_ms: 30_000},
             30_999
           )

    assert RuntimeGraph.refresh_due?(
             %{last_refresh_started_at_ms: 1_000, min_refresh_ms: 30_000},
             31_000
           )
  end

  defp quota_rows(count, prefix, evidence_class, relation_type) do
    Enum.map(1..count, fn idx ->
      suffix = idx |> Integer.to_string() |> String.pad_leading(5, "0")

      %{
        local_device_id: "sr:#{prefix}-#{suffix}",
        neighbor_device_id: "sr:#{prefix}-peer-#{suffix}",
        local_if_name: "if-#{suffix}",
        local_if_index: idx,
        neighbor_if_name: "peer-if-#{suffix}",
        neighbor_if_index: idx + 10_000,
        protocol: "test",
        evidence_class: evidence_class,
        metadata: %{"relation_type" => relation_type}
      }
    end)
  end

  defp runtime_row_identities(rows) do
    Enum.map(rows, fn row ->
      {
        row.local_device_id,
        row.neighbor_device_id,
        row.evidence_class,
        row.metadata["relation_type"],
        row.local_if_index,
        row.neighbor_if_index
      }
    end)
  end

  defp bounded_order_keys(query) do
    [_prefix, bounded_query] = String.split(query, "ORDER BY ", parts: 2)
    [order_keys, _rest] = String.split(bounded_query, ~r/\n\s*LIMIT /, parts: 2)

    order_keys
    |> String.split(~r/,\s*\n/)
    |> Enum.map(&String.trim/1)
  end
end

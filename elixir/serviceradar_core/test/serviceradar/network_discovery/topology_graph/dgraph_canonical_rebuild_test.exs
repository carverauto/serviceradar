defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphCanonicalRebuildTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild.DgraphRebuild

  @moduletag :db_free
  @observed "2025-01-10T12:00:00Z"
  @cutoff "2025-01-10T10:00:00Z"
  @old "2025-01-09T12:00:00Z"

  test "fresh reciprocal evidence produces one canonical link with both interface indexes" do
    forward = evidence("sr:switch-a", "sr:switch-b", "port1", "port7")
    reverse = evidence("sr:switch-b", "sr:switch-a", "port7", "port1")
    {:ok, inputs} = DgraphRebuild.decode_inputs([forward, reverse])

    assert {[
              %{
                source: "sr:switch-a",
                target: "sr:switch-b",
                kind: :canonical_topology,
                if_index_ab: 1,
                if_index_ba: 7,
                if_name_ab: "port1",
                if_name_ba: "port7",
                last_seen: @observed
              }
            ], %{after_prune_edges: 1, starved: false}} =
             DgraphRebuild.plan(inputs, @cutoff)
  end

  test "rebuild keeps discovery timestamps and existing directional telemetry" do
    current =
      evidence("sr:switch-b", "sr:switch-a", "port7", "port1")
      |> Map.merge(%{
        "relation" => "CANONICAL_TOPOLOGY",
        "flow_pps_ab" => 12,
        "flow_pps_ba" => 34,
        "flow_bps_ab" => 96,
        "flow_bps_ba" => 272,
        "capacity_bps" => 1_000_000_000,
        "telemetry_eligible" => true
      })

    fresh = evidence("sr:switch-a", "sr:switch-b", "port1", "port7")
    {:ok, inputs} = DgraphRebuild.decode_inputs([current, fresh])

    assert {[
              %{
                last_seen: @observed,
                flow_pps_ab: 34,
                flow_pps_ba: 12,
                flow_bps_ab: 272,
                flow_bps_ba: 96,
                capacity_bps: 1_000_000_000,
                telemetry_eligible: true
              }
            ], _} = DgraphRebuild.plan(inputs, @cutoff)
  end

  test "index-only parallel links have distinct interface names in the typed write contract" do
    rows =
      for index <- [0, 2, 3] do
        evidence("sr:switch-a", "sr:switch-b", "", "")
        |> Map.merge(%{
          "source" => [%{"id" => "sr:switch-a"}],
          "target" => [%{"id" => "sr:switch-b"}],
          "if_index_ab" => index,
          "if_index_ba" => index
        })
      end

    {:ok, inputs} = DgraphRebuild.decode_inputs(rows)
    {writes, _stats} = DgraphRebuild.plan(inputs, @cutoff)

    assert writes |> Enum.map(&{&1.if_name_ab, &1.if_name_ba}) |> Enum.sort() ==
             [{"", ""}, {"ifindex:2", "ifindex:2"}, {"ifindex:3", "ifindex:3"}]
  end

  test "starvation retains the old graph without refreshing its last observation" do
    frozen =
      evidence("sr:switch-a", "sr:switch-b", "port1", "port7")
      |> Map.put("last_seen", @old)

    current = Map.put(frozen, "relation", "CANONICAL_TOPOLOGY")
    {:ok, inputs} = DgraphRebuild.decode_inputs([frozen, current])

    assert {[%{last_seen: @old}], %{starved: true, prune_result: :skipped_starved}} =
             DgraphRebuild.plan(inputs, @cutoff)
  end

  test "large stale deletion is refused unless the configured override is set" do
    old =
      evidence("sr:switch-c", "sr:switch-d", "port1", "port7")
      |> Map.merge(%{"last_seen" => @old, "relation" => "CANONICAL_TOPOLOGY"})

    fresh = evidence("sr:switch-a", "sr:switch-b", "port1", "port7")
    {:ok, inputs} = DgraphRebuild.decode_inputs([old, fresh])

    {retained, stats} = DgraphRebuild.plan(inputs, @cutoff)
    assert stats.prune_result == {:refused, :mass_deletion}
    assert Enum.any?(retained, &(&1.source == "sr:switch-c" and &1.last_seen == @old))

    assert {[%{source: "sr:switch-a"}], %{prune_result: :ok}} =
             DgraphRebuild.plan(inputs, @cutoff, prune_override: true)
  end

  test "supported uplink demotes an unsupported same-port link from canonical adjacency" do
    uplink = evidence("sr:switch-a", "sr:switch-b", "port1", "port7")
    support = Map.put(uplink, "relation", "ATTACHED_TO")
    shared = evidence("sr:switch-a", "sr:switch-c", "port1", "port7")
    current_shared = Map.put(shared, "relation", "CANONICAL_TOPOLOGY")

    observed =
      evidence("sr:switch-d", "sr:switch-e", "port1", "port7")
      |> Map.put("relation", "OBSERVED_TO")

    {:ok, inputs} =
      DgraphRebuild.decode_inputs([uplink, support, current_shared, observed])

    assert {[%{source: "sr:switch-a", target: "sr:switch-b"}], %{same_port_demotions: {:ok, 1}}} =
             DgraphRebuild.plan(inputs, @cutoff)
  end

  test "fingerprint tracks evidence changes and interface enrichment but buckets heartbeat time" do
    row = evidence("sr:switch-a", "sr:switch-b", "port1", "port7")
    {:ok, original} = DgraphRebuild.decode_inputs([row])

    {:ok, heartbeat} =
      DgraphRebuild.decode_inputs([Map.put(row, "last_seen", "2025-01-10T12:45:00Z")])

    {:ok, changed} = DgraphRebuild.decode_inputs([Map.put(row, "confidence_tier", "medium")])
    enriched = put_in(row, ["target", Access.at(0), "interfaces", Access.at(0), "index"], 8)
    {:ok, enriched} = DgraphRebuild.decode_inputs([enriched])

    assert DgraphRebuild.fingerprint(original) == DgraphRebuild.fingerprint(heartbeat)
    refute DgraphRebuild.fingerprint(original) == DgraphRebuild.fingerprint(changed)
    refute DgraphRebuild.fingerprint(original) == DgraphRebuild.fingerprint(enriched)
  end

  test "malformed graph responses cannot be treated as an empty canonical set" do
    row =
      evidence("sr:switch-a", "sr:switch-b", "port1", "port7")
      |> Map.put("relation", "CANONICAL_TOPOLOGY")

    assert {:error, :invalid_dgraph_edge_identity} =
             DgraphRebuild.decode_inputs([Map.delete(row, "target")])

    assert {:error, :invalid_dgraph_edge_timestamp} =
             DgraphRebuild.decode_inputs([Map.put(row, "last_seen", "invalid")])
  end

  test "self and unresolved mapper observations do not prevent valid links from reconciling" do
    valid = evidence("sr:switch-a", "sr:switch-b", "port1", "port7")
    self_link = evidence("sr:switch-a", "sr:switch-a", "port1", "port7")
    unresolved = Map.delete(valid, "target")
    {:ok, inputs} = DgraphRebuild.decode_inputs([valid, self_link, unresolved])

    assert {[%{source: "sr:switch-a", target: "sr:switch-b"}], _} =
             DgraphRebuild.plan(inputs, @cutoff)
  end

  defp evidence(source, target, local, remote) do
    %{
      "source" => [endpoint(source, local)],
      "target" => [endpoint(target, remote)],
      "relation" => "CONNECTS_TO",
      "ingestor" => "mapper_topology_v1",
      "protocol" => "lldp",
      "evidence_class" => "direct-physical",
      "confidence_tier" => "high",
      "if_name_ab" => local,
      "if_name_ba" => remote,
      "if_index_ab" => 0,
      "if_index_ba" => 0,
      "last_seen" => @observed
    }
  end

  defp endpoint(id, port) do
    index = if port == "port1", do: 1, else: 7
    %{"id" => id, "interfaces" => [%{"key" => "#{id}/#{port}", "name" => port, "index" => index}]}
  end
end

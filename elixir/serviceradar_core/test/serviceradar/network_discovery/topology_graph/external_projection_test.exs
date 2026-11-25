defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.ExternalProjectionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.HorizonTopology
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.ExternalProjection

  test "normalizes Contract #4 snapshots, deduplicates nodes, and collapses duplicate edges" do
    payload = %{
      "schema_version" => 1,
      "generated_at" => "2026-11-25T00:00:00Z",
      "ttl_secs" => 600,
      "nodes" => [
        %{
          "id" => "transit:192.0.2.1",
          "kind" => "transit_router",
          "asn" => 64_512,
          "ip" => "192.0.2.1",
          "region" => "us-east"
        },
        %{
          "id" => "transit:192.0.2.1",
          "kind" => "TransitRouter",
          "label" => "border-iad-01"
        },
        %{
          "id" => "203.0.113.0/24",
          "kind" => "Prefix",
          "asn" => 64_513,
          "rpki_status" => "valid",
          "rtbh_active" => false
        },
        %{"id" => "bad-kind", "kind" => "UnknownType"}
      ],
      "edges" => [
        %{
          "src_id" => "transit:192.0.2.1",
          "dst_id" => "asn:64513",
          "kind" => "border_handoff",
          "border_asn" => 64_513,
          "as_boundary_confidence" => 0.92,
          "avg_rtt_us" => 10_000,
          "loss_pct" => 0.0
        },
        %{
          "src_id" => "transit:192.0.2.1",
          "dst_id" => "asn:64513",
          "kind" => "border_handoff",
          "avg_rtt_us" => 20_000,
          "loss_pct" => 1.0
        },
        %{
          "src_id" => "transit:192.0.2.1",
          "dst_id" => "198.51.100.1",
          "kind" => "traceroute_hop",
          "round_id" => "round-raw-1"
        }
      ]
    }

    assert {:ok, normalized} = ExternalProjection.normalize_snapshot(payload)
    assert length(normalized.nodes) == 2

    transit = Enum.find(normalized.nodes, &(&1.id == "transit:192.0.2.1"))
    assert transit.kind == "TransitRouter"
    assert transit.label == "border-iad-01"
    assert transit.asn == 64_512
    assert transit.expires_at == "2026-11-25T00:10:00Z"

    assert length(normalized.edges) == 1
    [edge] = normalized.edges
    assert edge.kind == "border_handoff"
    assert edge.avg_rtt_us == 15_000
    assert edge.loss_pct == 0.5
    assert edge.border_asn == 64_513
  end

  test "rejects raw per-round hop payloads including probes-only and round_id with nodes" do
    raw_round = %{
      "schema_version" => 1,
      "generated_at" => "2026-11-25T00:00:00Z",
      "round_id" => "r-123",
      "path_hops" => [%{"hop_ttl" => 1, "ip" => "192.0.2.1"}]
    }

    assert {:ignore, :raw_per_round_hops} = ExternalProjection.normalize_snapshot(raw_round)

    probes_only = %{
      "schema_version" => 1,
      "generated_at" => "2026-11-25T00:00:00Z",
      "probes" => [%{"seq" => 1, "ip" => "192.0.2.1"}]
    }

    assert {:ignore, :raw_per_round_hops} = ExternalProjection.normalize_snapshot(probes_only)

    round_with_nodes = %{
      "schema_version" => 1,
      "generated_at" => "2026-11-25T00:00:00Z",
      "round_id" => "r-456",
      "nodes" => [%{"id" => "asn:64512", "kind" => "ASN", "asn" => 64_512}]
    }

    assert {:ignore, :raw_per_round_hops} =
             ExternalProjection.normalize_snapshot(round_with_nodes)
  end

  test "prune_timestamp returns current timestamp while stale_cutoff shifts by ttl" do
    now = ~U[2026-11-25 00:16:00Z]
    assert ExternalProjection.prune_timestamp(now) == "2026-11-25T00:16:00Z"
    assert ExternalProjection.stale_cutoff(now, 900) == "2026-11-25T00:01:00Z"
  end

  test "normalizes outage and BGP status events" do
    assert {:ok, outage_patch} =
             ExternalProjection.normalize_status_event("serviceradar.horizon.outages.region", %{
               "target_id" => "saas:api.example",
               "belief_state" => "confirmed_outage",
               "timestamp" => "2026-11-25T01:00:00Z"
             })

    assert outage_patch.entity_id == "saas:api.example"
    assert outage_patch.outage_state == "confirmed_outage"

    assert {:ok, bgp_patch} =
             ExternalProjection.normalize_status_event("serviceradar.horizon.bgp.rtbh", %{
               "covering_prefix" => "198.51.100.0/24",
               "rpki_status" => "invalid",
               "event_type" => "rtbh_blackhole",
               "timestamp" => "2026-11-25T01:00:00Z"
             })

    assert bgp_patch.entity_id == "198.51.100.0/24"
    assert bgp_patch.kind == "Prefix"
    assert bgp_patch.rpki_state == "invalid"
    assert bgp_patch.rtbh_active == true
  end

  test "HorizonTopology processor is fail-open on malformed payloads and retries transient errors" do
    assert :ok =
             HorizonTopology.process_message(
               "serviceradar.horizon.topology.snapshot",
               "{not-json"
             )

    snapshot_json =
      Jason.encode!(%{
        "schema_version" => 1,
        "generated_at" => "2026-11-25T00:00:00Z",
        "ttl_secs" => 900,
        "nodes" => [%{"id" => "asn:64512", "kind" => "ASN", "asn" => 64_512}],
        "edges" => []
      })

    assert {:error, :transient} =
             HorizonTopology.process_message(
               "serviceradar.horizon.topology.snapshot",
               snapshot_json,
               upsert_external_topology: fn _snap, _opts -> {:error, :transient} end
             )

    assert :ok =
             HorizonTopology.process_message(
               "serviceradar.horizon.topology.snapshot",
               snapshot_json,
               final_delivery?: true,
               upsert_external_topology: fn _snap, _opts -> {:error, :transient} end
             )
  end
end

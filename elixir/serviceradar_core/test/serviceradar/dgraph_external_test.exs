defmodule ServiceRadar.DgraphExternalTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Dgraph.ExternalTopology
  alias ServiceRadar.Dgraph.Native
  alias ServiceRadar.Dgraph.TransientError

  setup do
    prev_url = Application.get_env(:serviceradar_core, :dgraph_url)
    prev_opts = Application.get_env(:serviceradar_core, ServiceRadar.Dgraph)
    env_url = System.get_env("DGRAPH_URL")

    on_exit(fn ->
      restore_env("DGRAPH_URL", env_url)
      put_app(:dgraph_url, prev_url)
      put_app(ServiceRadar.Dgraph, prev_opts)
    end)

    :ok
  end

  test "NIF exports external topology operations" do
    {:module, _} = Code.ensure_compiled(Native)
    assert function_exported?(Native, :upsert_external_topology, 3)
    assert function_exported?(Native, :upsert_external_status, 3)
    assert function_exported?(Native, :prune_stale_external, 3)
    assert function_exported?(Native, :query_blast_radius, 5)
    assert function_exported?(Native, :query_shared_fate_spofs, 4)
    assert function_exported?(Native, :query_customer_cone, 5)
    assert function_exported?(Native, :query_multi_hop_trace, 6)
    assert function_exported?(Native, :query_egress_topology, 4)
    assert function_exported?(Native, :query_external_egress_targets, 3)
    assert function_exported?(Native, :reconcile_egress_edges, 4)
  end

  test "rejects empty query seeds and non-map snapshots without contacting Dgraph" do
    System.delete_env("DGRAPH_URL")
    Application.delete_env(:serviceradar_core, :dgraph_url)

    assert {:error, "seed_id must not be empty"} = ExternalTopology.blast_radius("   ")
    assert {:error, "asn_id must not be empty"} = ExternalTopology.customer_cone_impact("")
    assert {:error, "src_id must not be empty"} = ExternalTopology.multi_hop_trace("  ")
    assert {:error, "timestamp must not be empty"} = ExternalTopology.prune_stale_external(" ")
    assert {:error, _} = ExternalTopology.upsert_external_topology(:invalid)
    assert {:error, _} = ExternalTopology.upsert_external_status(:invalid)
  end

  test "synchronous NIF ABI validation rejects unknown node or edge kinds" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    url = "dgraph://127.0.0.1:#{port}?sslmode=disable"
    Application.put_env(:serviceradar_core, :dgraph_url, url)

    Application.put_env(:serviceradar_core, ServiceRadar.Dgraph,
      max_attempts: 1,
      item_deadline_ms: 500,
      bulk_deadline_ms: 500
    )

    bad_snapshot = %{
      generated_at: "2026-11-25T00:00:00Z",
      ttl_secs: 900,
      nodes: [%{id: "asn:64512", kind: "InvalidType"}],
      edges: []
    }

    assert {:error, reason} = ExternalTopology.upsert_external_topology(bad_snapshot)
    assert reason =~ "unknown external node kind"

    bad_edge_snapshot = %{
      generated_at: "2026-11-25T00:00:00Z",
      ttl_secs: 900,
      nodes: [%{id: "asn:64512", kind: "ASN"}],
      edges: [%{src_id: "asn:64512", dst_id: "asn:64513", kind: "canonical_topology"}]
    }

    assert {:error, edge_reason} = ExternalTopology.upsert_external_topology(bad_edge_snapshot)
    assert edge_reason =~ "unknown external edge kind"
  end

  test "refused port returns TransientError for external queries and snapshots" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    url = "dgraph://127.0.0.1:#{port}?sslmode=disable"
    Application.put_env(:serviceradar_core, :dgraph_url, url)

    Application.put_env(:serviceradar_core, ServiceRadar.Dgraph,
      max_attempts: 1,
      item_deadline_ms: 500,
      bulk_deadline_ms: 500
    )

    snapshot = %{
      generated_at: "2026-11-25T00:00:00Z",
      ttl_secs: 900,
      nodes: [
        %{id: "asn:64512", kind: "ASN", asn: 64_512, label: "AS64512"},
        %{id: "198.51.100.0/24", kind: "Prefix", asn: 64_512, rpki_state: "valid"}
      ],
      edges: [
        %{
          src_id: "asn:64512",
          dst_id: "asn:64513",
          kind: "as_rel_provider",
          border_asn: 64_513,
          as_boundary_confidence: 0.9
        }
      ]
    }

    assert {:error, %TransientError{operation: :upsert_external_topology}} =
             ExternalTopology.upsert_external_topology(snapshot)

    assert {:error, %TransientError{operation: :query_blast_radius}} =
             ExternalTopology.blast_radius("198.51.100.0/24", max_hops: 99, limit: 999)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value) when is_binary(value), do: System.put_env(name, value)

  defp put_app(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp put_app(key, value), do: Application.put_env(:serviceradar_core, key, value)
end

defmodule ServiceRadar.NetworkDiscovery.EndpointAttachmentE2ETest do
  @moduledoc """
  End-to-end coverage (database + Apache AGE required) for endpoint attachment
  identity promotion (fix-topology-evidence-pipeline-resilience, task 3.5).

  With `:topology_endpoint_identity_promotion_enabled` on, a real-shaped
  SNMP-L2 ARP+FDB attachment record for an un-inventoried host must:

    1. mint a provisional `sr:` device keyed by normalized MAC + partition
       (`identity_state: provisional`, `identity_source:
       mapper_topology_sighting`);
    2. persist the evidence row with the resolved `sr:` neighbor id;
    3. project a renderable `sr:`↔`sr:` ATTACHED_TO edge into AGE that
       survives the canonical rebuild (CANONICAL_TOPOLOGY) and the runtime
       topology projection;
    4. converge onto the same uid when the same MAC is sighted again.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @switch_uid "sr:e2e-fdb-switch"
  @endpoint_mac "aa:bb:cc:dd:e2:01"
  @endpoint_ip "192.0.2.181"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    if age_available?() do
      graph_name = graph_name()

      case ensure_graph(graph_name) do
        :ok ->
          :ok

        {:error, reason} ->
          {:ok, skip: "Apache AGE graph #{graph_name} not available: #{inspect(reason)}"}
      end
    else
      {:ok, skip: "Apache AGE is not available (ag_catalog.cypher missing)"}
    end
  end

  setup do
    original =
      Application.get_env(:serviceradar_core, :topology_endpoint_identity_promotion_enabled)

    Application.put_env(:serviceradar_core, :topology_endpoint_identity_promotion_enabled, true)

    on_exit(fn ->
      case original do
        nil ->
          Application.delete_env(
            :serviceradar_core,
            :topology_endpoint_identity_promotion_enabled
          )

        value ->
          Application.put_env(
            :serviceradar_core,
            :topology_endpoint_identity_promotion_enabled,
            value
          )
      end
    end)

    endpoint_uid = expected_endpoint_uid()

    purge_topology_rows([@switch_uid])
    purge_endpoint_device(endpoint_uid)

    cleanup_graph([
      @switch_uid,
      endpoint_uid,
      "#{@switch_uid}/ifindex:4",
      "#{endpoint_uid}/#{@endpoint_mac}",
      "#{endpoint_uid}/#{@endpoint_ip}",
      "#{endpoint_uid}/unknown-neighbor"
    ])

    {:ok, endpoint_uid: endpoint_uid}
  end

  test "FDB attachment for an un-inventoried host renders as an sr:<->sr: attachment edge", %{
    endpoint_uid: endpoint_uid
  } do
    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([fdb_payload()]), %{})

    # 1. Provisional identity minted, MAC-keyed and merge-inert-tagged.
    actor = SystemActor.system(:mapper_topology_ingestor)
    assert {:ok, %Device{} = device} = Device.get_by_uid(endpoint_uid, true, actor: actor)
    metadata = Map.new(device.metadata || %{})
    assert metadata["identity_state"] == "provisional"
    assert metadata["identity_source"] == "mapper_topology_sighting"
    assert metadata["identity_confidence_tier"] == "medium"
    assert IdentityReconciler.normalize_mac(device.mac) == normalized_endpoint_mac()

    # 2. Evidence row persisted with the resolved sr: neighbor id.
    assert [row] = topology_rows(@switch_uid)
    assert row["neighbor_device_id"] == endpoint_uid
    assert row["neighbor_port_id"] == ""

    # 3a. Mapper evidence edge in AGE references sr: identities on both ends.
    [attached] =
      cypher_rows(
        "MATCH (ai:Interface {device_id: '#{@switch_uid}'})-[r:ATTACHED_TO]->(bi:Interface {device_id: '#{endpoint_uid}'}) " <>
          "RETURN {count: count(r)} AS result"
      )

    assert attached["count"] == 1

    # 3b. The edge survives the canonical rebuild (both endpoints pass the
    # STARTS WITH 'sr:' gates).
    [canonical] =
      cypher_rows(
        "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device) " <>
          "WHERE (a.id = '#{@switch_uid}' AND b.id = '#{endpoint_uid}') " <>
          "   OR (a.id = '#{endpoint_uid}' AND b.id = '#{@switch_uid}') " <>
          "RETURN {count: count(r), relation_type: head(collect(r.relation_type))} AS result"
      )

    assert canonical["count"] == 1
    assert canonical["relation_type"] == "ATTACHED_TO"

    # 3c. And the runtime projection serves it (attachment plane).
    assert {:ok, _} = RuntimeTopologyProjection.refresh_from_graph()
    assert {:ok, cached} = RuntimeTopologyProjection.read_cached_links()

    assert Enum.any?(cached, fn cached_row ->
             ids = [cached_row["local_device_id"], cached_row["neighbor_device_id"]]
             @switch_uid in ids and endpoint_uid in ids
           end)

    # 4. Re-sighting the same MAC converges on the same provisional device.
    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([fdb_payload()]), %{})

    %Postgrex.Result{rows: [[device_count]]} =
      SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM ocsf_devices WHERE uid = $1 AND deleted_at IS NULL",
        [endpoint_uid]
      )

    assert device_count == 1
  end

  defp fdb_payload do
    %{
      "timestamp" => DateTime.truncate(DateTime.utc_now(), :microsecond),
      "protocol" => "SNMP-L2",
      "agent_id" => "agent-e2e-fdb",
      "gateway_id" => "agent-e2e-fdb",
      "partition" => "default",
      "local_device_id" => @switch_uid,
      "local_device_ip" => "192.0.2.180",
      "local_if_index" => 4,
      "neighbor_chassis_id" => @endpoint_mac,
      "neighbor_mgmt_addr" => @endpoint_ip,
      "metadata" => %{
        "protocol" => "SNMP-L2",
        "source" => "snmp-arp-fdb",
        "evidence" => "ipNetToMedia+dot1dTpFdb",
        "fdb_port_mapped" => "true",
        "evidence_class" => "inferred-segment",
        "relation_family" => "ATTACHED_TO",
        "confidence_tier" => "medium",
        "confidence_reason" => "arp_fdb_port_mapping"
      }
    }
  end

  defp normalized_endpoint_mac, do: IdentityReconciler.normalize_mac(@endpoint_mac)

  defp expected_endpoint_uid do
    IdentityReconciler.generate_deterministic_device_id(%{
      mac: normalized_endpoint_mac(),
      partition: "default"
    })
  end

  defp purge_endpoint_device(endpoint_uid) do
    SQL.query!(
      Repo,
      "DELETE FROM device_identifiers WHERE identifier_type = 'mac' AND identifier_value = $1",
      [normalized_endpoint_mac()]
    )

    SQL.query!(Repo, "DELETE FROM ocsf_devices WHERE uid = $1", [endpoint_uid])

    :ok
  end

  defp purge_topology_rows(local_device_ids) when is_list(local_device_ids) do
    SQL.query!(
      Repo,
      "DELETE FROM platform.mapper_topology_links WHERE local_device_id = ANY($1)",
      [local_device_ids]
    )

    :ok
  end

  defp topology_rows(local_device_id) do
    %Postgrex.Result{rows: rows, columns: columns} =
      SQL.query!(
        Repo,
        """
        SELECT protocol, local_device_id, local_if_index, neighbor_device_id,
               neighbor_chassis_id, neighbor_port_id, neighbor_system_name
        FROM platform.mapper_topology_links
        WHERE local_device_id = $1
        """,
        [local_device_id]
      )

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp age_available? do
    with {:ok, %Postgrex.Result{rows: [[_]]}} <-
           SQL.query(Repo, "SELECT 1 FROM pg_namespace WHERE nspname = 'ag_catalog'", []),
         {:ok, %Postgrex.Result{rows: [[_]]}} <-
           SQL.query(
             Repo,
             """
             SELECT 1
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'ag_catalog' AND p.proname = 'cypher'
             LIMIT 1
             """,
             []
           ) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp ensure_graph(graph_name) do
    case SQL.query(Repo, "SELECT 1 FROM ag_catalog.ag_graph WHERE name = $1 LIMIT 1", [graph_name]) do
      {:ok, %Postgrex.Result{num_rows: 1}} ->
        :ok

      {:ok, _} ->
        case SQL.query(Repo, "SELECT ag_catalog.create_graph($1)", [graph_name]) do
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      {:error, err} ->
        {:error, err}
    end
  rescue
    err -> {:error, err}
  end

  defp cleanup_graph(ids) when is_list(ids) do
    quoted_ids = Enum.map_join(ids, ", ", &("'" <> &1 <> "'"))
    graph = String.replace(graph_name(), "'", "\\'")

    cypher = "MATCH (n) WHERE n.id IN [#{quoted_ids}] DETACH DELETE n"

    _ =
      SQL.query(
        Repo,
        "SELECT ag_catalog.agtype_to_text(v) FROM ag_catalog.cypher('#{graph}', $$#{cypher}$$) AS (v agtype)",
        []
      )

    :ok
  end

  defp cypher_rows(cypher) do
    graph = String.replace(graph_name(), "'", "\\'")

    sql = """
    SELECT ag_catalog.agtype_to_text(result)
    FROM ag_catalog.cypher('#{graph}', $$#{cypher}$$) AS (result agtype)
    """

    case SQL.query(Repo, sql, []) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.map(rows, fn
          [text_value] when is_binary(text_value) -> decode_agtype(text_value)
          row -> row
        end)

      {:error, error} ->
        raise "cypher query failed: #{inspect(error)}"
    end
  end

  defp decode_agtype(text_value) do
    case Jason.decode(text_value) do
      {:ok, parsed} -> parsed
      {:error, _} -> text_value
    end
  end

  defp graph_name do
    Application.get_env(:serviceradar_core, :age_graph_name, "platform_graph")
  end
end

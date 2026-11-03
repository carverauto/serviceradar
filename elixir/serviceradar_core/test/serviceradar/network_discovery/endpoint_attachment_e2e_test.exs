defmodule ServiceRadar.NetworkDiscovery.EndpointAttachmentE2ETest do
  @moduledoc """
  End-to-end coverage (database required) for endpoint attachment identity
  promotion (fix-topology-evidence-pipeline-resilience, task 3.5).

  With `:topology_endpoint_identity_promotion_enabled` on, a real-shaped
  SNMP-L2 ARP+FDB attachment record for an un-inventoried host must:

    1. mint a provisional `sr:` device keyed by normalized MAC + partition
       (`identity_state: provisional`, `identity_source:
       mapper_topology_sighting`);
    2. persist the evidence row with the resolved `sr:` neighbor id;
    3. converge onto the same uid when the same MAC is sighted again.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @switch_uid "sr:e2e-fdb-switch"
  @endpoint_mac "00:00:5e:00:53:e1"
  @endpoint_ip "192.0.2.181"

  setup_all do
    TestSupport.start_core!()
    :ok
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

    {:ok, endpoint_uid: endpoint_uid}
  end

  test "FDB attachment for an un-inventoried host resolves to a provisional sr: neighbor", %{
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

    # 3. Re-sighting the same MAC converges on the same provisional device.
    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([fdb_payload()]), %{})

    %Postgrex.Result{rows: [[device_count]]} =
      SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM ocsf_devices WHERE uid = $1 AND deleted_at IS NULL",
        [endpoint_uid]
      )

    assert device_count == 1
  end

  test "an identity-purged endpoint sighting gains one fresh successor", %{
    endpoint_uid: endpoint_uid
  } do
    actor = SystemActor.system(:mapper_topology_ingestor)
    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([fdb_payload()]), %{})
    assert {:ok, %Device{} = device} = Device.get_by_uid(endpoint_uid, false, actor: actor)
    assert {:ok, _} = Device.soft_delete(device, "manual", Ecto.UUID.generate(), actor: actor)

    assert {%{errors: 0}, _deleted} =
             DeviceCleanupWorker.hard_delete_records(%{deleted: 0, errors: 0}, [
               %{uid: endpoint_uid}
             ])

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([fdb_payload()]), %{})

    successor = Ids.reseeded_device_id(endpoint_uid)

    assert {:ok, %Device{deleted_at: nil} = live} =
             Device.get_by_uid(successor, false, actor: actor)

    assert live.metadata["identity_source"] == "mapper_topology_sighting"
    assert {:ok, tombstone} = Device.get_by_uid(endpoint_uid, true, actor: actor)
    assert tombstone.deleted_at
    assert tombstone.identity_purged_at
    assert tombstone.metadata["_seed_successor"] == successor
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

    TestSupport.purge_devices!([endpoint_uid])

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
end

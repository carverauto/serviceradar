defmodule ServiceRadar.Inventory.IdentityReconcilerMergeTest do
  @moduledoc """
  Integration coverage for merge behavior with interface observations.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.EndpointInventoryFleetOrdinal
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_merge_test)
    handler_id = "identity-reconciler-merge-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:serviceradar, :identity_reconciler, :merge, :executed],
          [:serviceradar, :identity_reconciler, :merge, :failed]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    {:ok, actor: actor}
  end

  test "merge reassigns interface observations and drops duplicates", %{actor: actor} do
    from_uid = "sr:" <> Ecto.UUID.generate()
    to_uid = "sr:" <> Ecto.UUID.generate()

    assert {:ok, _from_device} = create_device(actor, from_uid, "merge-from")
    assert {:ok, _to_device} = create_device(actor, to_uid, "merge-to")

    timestamp = DateTime.truncate(DateTime.utc_now(), :second)
    earlier = DateTime.add(timestamp, -60, :second)

    assert {:ok, _} = create_interface(actor, to_uid, timestamp, "ifindex:1", 1, "eth0")
    assert {:ok, _} = create_interface(actor, from_uid, timestamp, "ifindex:1", 1, "eth0")
    assert {:ok, _} = create_interface(actor, from_uid, earlier, "ifindex:2", 2, "eth1")

    assert :ok = IdentityReconciler.merge_devices(from_uid, to_uid, actor: actor)

    assert_receive {:telemetry_event, [:serviceradar, :identity_reconciler, :merge, :executed],
                    %{count: 1}, telemetry_metadata}

    assert telemetry_metadata.reason == "identity_resolution"
    assert telemetry_metadata.manual_override == false
    assert telemetry_metadata.from_device_id == from_uid
    assert telemetry_metadata.to_device_id == to_uid

    assert {:error, _} = Device.get_by_uid(from_uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(to_uid, false, actor: actor)

    assert {:ok, interfaces} = list_interfaces(actor, to_uid)
    assert length(interfaces) == 2

    assert Enum.any?(interfaces, fn iface ->
             iface.interface_uid == "ifindex:1" and iface.timestamp == timestamp
           end)

    assert Enum.any?(interfaces, fn iface ->
             iface.interface_uid == "ifindex:2" and iface.timestamp == earlier
           end)

    assert {:ok, []} = list_interfaces(actor, from_uid)
  end

  test "merge preserves manual classification before combining provenance", %{actor: actor} do
    cases = [
      {["manual", "netbox"], "Switch", 10, ["armis"], "Tablet", 4, {"Switch", 10}},
      {["manual"], "Switch", 10, ["manual"], "Router", 12, {"Router", 12}},
      {["manual"], "Switch", 10, ["manual"], "Unknown", 0, {"Switch", 10}},
      {["manual"], " Unknown ", 0, ["armis"], "Tablet", 4, {"Tablet", 4}},
      {["netbox"], "Switch", 10, ["armis"], "Tablet", 4, {"Tablet", 4}}
    ]

    Enum.each(cases, fn {from_sources, from_type, from_type_id, to_sources, to_type, to_type_id,
                         expected} ->
      from_uid = "sr:" <> Ecto.UUID.generate()
      to_uid = "sr:" <> Ecto.UUID.generate()

      assert {:ok, _} =
               create_device(actor, from_uid, "source.example.com", %{
                 type: from_type,
                 type_id: from_type_id,
                 discovery_sources: from_sources
               })

      assert {:ok, _} =
               create_device(actor, to_uid, "survivor.example.com", %{
                 type: to_type,
                 type_id: to_type_id,
                 discovery_sources: to_sources
               })

      assert :ok =
               IdentityReconciler.merge_devices(from_uid, to_uid,
                 actor: actor,
                 reason: "sync_ip_hostname_agreement"
               )

      assert {:ok, survivor} = Device.get_by_uid(to_uid, false, actor: actor)
      assert {survivor.type, survivor.type_id} == expected

      assert Enum.sort(survivor.discovery_sources) ==
               Enum.sort(Enum.uniq(from_sources ++ to_sources))

      assert {:error, _} = Device.get_by_uid(from_uid, false, actor: actor)
    end)
  end

  test "manual merge reason emits manual override telemetry", %{actor: actor} do
    from_uid = "sr:" <> Ecto.UUID.generate()
    to_uid = "sr:" <> Ecto.UUID.generate()

    assert {:ok, _from_device} = create_device(actor, from_uid, "merge-from-manual")
    assert {:ok, _to_device} = create_device(actor, to_uid, "merge-to-manual")

    assert :ok =
             IdentityReconciler.merge_devices(from_uid, to_uid,
               actor: actor,
               reason: "manual_merge"
             )

    assert_receive {:telemetry_event, [:serviceradar, :identity_reconciler, :merge, :executed],
                    %{count: 1}, telemetry_metadata}

    assert telemetry_metadata.reason == "manual_merge"
    assert telemetry_metadata.manual_override == true
  end

  test "merge preserves source tags, metadata, and discovery sources on the survivor", %{
    actor: actor
  } do
    from_uid = "sr:" <> Ecto.UUID.generate()
    to_uid = "sr:" <> Ecto.UUID.generate()

    assert {:ok, _from_device} =
             create_device(actor, from_uid, "merge-facts-from", %{
               tags: %{"rids" => true, "owner" => "source"},
               metadata: %{"csv_import" => true, "authority" => "source"},
               discovery_sources: ["manual", "sweep"]
             })

    assert {:ok, _to_device} =
             create_device(actor, to_uid, "merge-facts-to", %{
               tags: %{"managed" => true, "owner" => "survivor"},
               metadata: %{"armis_device_id" => "4487840", "authority" => "survivor"},
               discovery_sources: ["armis", "sweep"]
             })

    assert :ok =
             IdentityReconciler.merge_devices(from_uid, to_uid,
               actor: actor,
               reason: "manual_merge"
             )

    assert {:ok, survivor} = Device.get_by_uid(to_uid, false, actor: actor)

    assert survivor.tags == %{
             "managed" => true,
             "owner" => "survivor",
             "rids" => true
           }

    assert survivor.metadata == %{
             "type_manually_set" => false,
             "armis_device_id" => "4487840",
             "authority" => "survivor",
             "csv_import" => true
           }

    assert Enum.sort(survivor.discovery_sources) == ["armis", "manual", "sweep"]
  end

  test "merge reassigns endpoint inventory rows and tombstones dead ordinal", %{actor: actor} do
    from_uid = "sr:" <> Ecto.UUID.generate()
    to_uid = "sr:" <> Ecto.UUID.generate()
    agent_id = "agent-merge-#{System.unique_integer([:positive])}"

    assert {:ok, _from_device} = create_device(actor, from_uid, "merge-from-inventory")
    assert {:ok, _to_device} = create_device(actor, to_uid, "merge-to-inventory")

    assert {:ok, from_ordinal} = EndpointInventoryFleetOrdinal.ensure_allocated(from_uid)
    assert {:ok, to_ordinal} = EndpointInventoryFleetOrdinal.ensure_allocated(to_uid)

    assert %{scan_ref: _scan_ref} =
             insert_endpoint_inventory_rows!(from_uid, agent_id, "nginx-merge")

    assert :ok = IdentityReconciler.merge_devices(from_uid, to_uid, actor: actor)

    assert table_device_count("endpoint_inventory_scans", from_uid) == 0
    assert table_device_count("endpoint_inventory_artifacts", from_uid) == 0
    assert table_device_count("endpoint_inventory_packages", from_uid) == 0

    assert table_device_count("endpoint_inventory_scans", to_uid) == 1
    assert table_device_count("endpoint_inventory_artifacts", to_uid) == 1
    assert table_device_count("endpoint_inventory_packages", to_uid) == 1

    assert EndpointInventoryFleetOrdinal.ordinal_for(to_uid) == to_ordinal
    assert %{ordinal: ^from_ordinal, tombstoned: true} = fleet_ordinal_row(from_uid)
  end

  test "backfills null endpoint inventory rows when an agent gets a canonical device uid", %{
    actor: actor
  } do
    device_uid = "sr:" <> Ecto.UUID.generate()
    agent_id = "agent-backfill-#{System.unique_integer([:positive])}"

    assert {:ok, _device} = create_device(actor, device_uid, "backfill-inventory")

    assert %{scan_ref: _scan_ref} =
             insert_endpoint_inventory_rows!(nil, agent_id, "curl-backfill")

    assert table_null_device_count("endpoint_inventory_scans", agent_id) == 1
    assert table_null_device_count("endpoint_inventory_artifacts", agent_id) == 1
    assert table_null_device_count("endpoint_inventory_packages", agent_id) == 1

    assert :ok =
             IdentityReconciler.backfill_endpoint_inventory_device_uid_for_agent(
               agent_id,
               device_uid
             )

    assert table_null_device_count("endpoint_inventory_scans", agent_id) == 0
    assert table_null_device_count("endpoint_inventory_artifacts", agent_id) == 0
    assert table_null_device_count("endpoint_inventory_packages", agent_id) == 0

    assert table_device_count("endpoint_inventory_scans", device_uid) == 1
    assert table_device_count("endpoint_inventory_artifacts", device_uid) == 1
    assert table_device_count("endpoint_inventory_packages", device_uid) == 1
    assert is_integer(EndpointInventoryFleetOrdinal.ordinal_for(device_uid))
  end

  defp create_device(actor, uid, hostname, extra_attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          uid: uid,
          hostname: hostname,
          ip: unique_ip_for_uid(uid)
        },
        extra_attrs
      )

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp unique_ip_for_uid(uid) do
    <<a, b, c, _rest::binary>> = :crypto.hash(:sha256, uid)
    "10.#{a}.#{b}.#{max(c, 1)}"
  end

  defp create_interface(actor, device_id, timestamp, interface_uid, if_index, if_name) do
    attrs = %{
      timestamp: timestamp,
      device_id: device_id,
      interface_uid: interface_uid,
      if_index: if_index,
      if_name: if_name
    }

    Interface
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp list_interfaces(actor, device_id) do
    Interface
    |> Ash.Query.filter(device_id == ^device_id)
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read(actor: actor)
  end

  defp insert_endpoint_inventory_rows!(device_uid, agent_id, package_name) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    scan_id = "scan-#{System.unique_integer([:positive])}"
    package_ref = insert_endpoint_package!(package_name, now)

    {1, [%{id: scan_ref}]} =
      Repo.insert_all(
        "endpoint_inventory_scans",
        [
          %{
            device_uid: device_uid,
            agent_id: agent_id,
            scan_id: scan_id,
            state: "scanned",
            coverage_state: "complete",
            package_count: 1,
            artifact_count: 1,
            current: true,
            last_scan_at: now,
            ingested_at: now,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform",
        returning: [:id]
      )

    Repo.insert_all(
      "endpoint_inventory_artifacts",
      [
        %{
          scan_ref: scan_ref,
          agent_id: agent_id,
          device_uid: device_uid,
          object_key: "endpoint-inventory/#{agent_id}/#{scan_id}.json",
          sha256: String.duplicate("a", 64),
          size_bytes: 128,
          artifact_hash: "sha256:" <> String.duplicate("b", 64),
          uploaded_at: now,
          inserted_at: now
        }
      ],
      prefix: "platform"
    )

    Repo.insert_all(
      "endpoint_inventory_packages",
      [
        %{
          scan_ref: scan_ref,
          device_uid: device_uid,
          agent_id: agent_id,
          name: package_name,
          version: "1.0.0",
          architecture: "amd64",
          package_manager: "dpkg",
          ecosystem: "deb",
          purl: "pkg:deb/#{package_name}@1.0.0?arch=amd64",
          purl_canonical: "pkg:deb/#{package_name}@1.0.0?arch=amd64",
          endpoint_package_ref: package_ref,
          current: true,
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: "platform"
    )

    %{scan_ref: scan_ref, package_ref: package_ref}
  end

  defp insert_endpoint_package!(package_name, now) do
    {_count, [%{id: package_ref}]} =
      Repo.insert_all(
        "endpoint_packages",
        [
          %{
            coordinate_key: "purl:pkg:deb/#{package_name}@1.0.0?arch=amd64",
            purl_canonical: "pkg:deb/#{package_name}@1.0.0?arch=amd64",
            cpes: [],
            package_manager: "dpkg",
            name: package_name,
            version: "1.0.0",
            architecture: "amd64",
            ecosystem: "deb",
            source_scope: "host",
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform",
        on_conflict: {:replace, [:updated_at]},
        conflict_target: [:coordinate_key],
        returning: [:id]
      )

    package_ref
  end

  defp table_device_count(table, device_uid) do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM platform.#{table} WHERE device_uid = $1", [device_uid])

    count
  end

  defp table_null_device_count(table, agent_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT COUNT(*) FROM platform.#{table} WHERE agent_id = $1 AND device_uid IS NULL",
        [agent_id]
      )

    count
  end

  defp fleet_ordinal_row(device_uid) do
    %{rows: [[ordinal, tombstoned]]} =
      Repo.query!(
        """
        SELECT ordinal, tombstoned
        FROM platform.device_fleet_ordinals
        WHERE uid = $1
        """,
        [device_uid]
      )

    %{ordinal: ordinal, tombstoned: tombstoned}
  end
end

defmodule ServiceRadar.Inventory.PluginSourceInventoryIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservation
  alias ServiceRadar.Inventory.DeviceSourceSnapshot
  alias ServiceRadar.Inventory.SourceInventoryReader
  alias ServiceRadar.Inventory.SyncIngestor

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:plugin_source_inventory_test)}
  end

  test "plugin inventory converges with Armis by scoped serial and preserves both source identities",
       %{
         actor: actor
       } do
    suffix = unique_suffix()
    armis_id = "armis-#{suffix}"
    plugin_integration_id = "example-inventory:v1:lab-#{suffix}:device:201"
    serial = "FOC#{suffix}ABC"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "hostname" => "iad-asw-#{suffix}",
                   "ip" => "10.240.#{unique_octet()}.10",
                   "source" => "armis",
                   "metadata" => %{
                     "armis_device_id" => armis_id,
                     "integration_type" => "armis",
                     "vendor_name" => "Cisco Systems",
                     "serial_number" => serial
                   }
                 }
               ],
               actor: actor
             )

    armis_identifier = identifier!(actor, :armis_device_id, armis_id)

    assert :ok =
             DeviceDiscoveryIngestor.ingest(
               inventory_payload(
                 "lab-#{suffix}",
                 "collection-#{suffix}-1",
                 ~U[2026-07-13 18:00:00Z],
                 [inventory_device("201", "iad-asw-#{suffix}", serial)]
               ),
               %{partition: "default"},
               actor: actor
             )

    plugin_integration_identifier = identifier!(actor, :integration_id, plugin_integration_id)
    serial_identifier = identifier!(actor, :hardware_serial, "cisco:#{serial}")

    assert plugin_integration_identifier.device_id == armis_identifier.device_id
    assert serial_identifier.device_id == armis_identifier.device_id

    assert {:ok, device} = Device.get_by_uid(armis_identifier.device_id, false, actor: actor)
    assert Enum.sort(device.discovery_sources) == ["armis", "example-inventory"]
    assert device.metadata["integration_type"] == "armis"
    assert device.metadata["armis_device_id"] == armis_id
    assert device.metadata["source_metadata"]["partition"] == "IAD"

    [observation] =
      actor
      |> observations!("lab-#{suffix}")
      |> Enum.filter(&(&1.source_object_id == "201"))

    assert observation.device_id == device.uid
    assert observation.present
    assert observation.serial_number == serial
  end

  test "a later complete snapshot marks missing plugin inventory observations absent", %{
    actor: actor
  } do
    suffix = unique_suffix()
    instance = "presence-#{suffix}"
    first_collection = "collection-#{suffix}-1"
    second_collection = "collection-#{suffix}-2"

    assert :ok =
             DeviceDiscoveryIngestor.ingest(
               inventory_payload(instance, first_collection, ~U[2026-07-13 18:00:00Z], [
                 inventory_device("301", "ord-asw-301", "FOC#{suffix}301"),
                 inventory_device("302", "ord-asw-302", "FOC#{suffix}302")
               ]),
               %{partition: "default"},
               actor: actor
             )

    assert :ok =
             DeviceDiscoveryIngestor.ingest(
               inventory_payload(instance, second_collection, ~U[2026-07-14 18:00:00Z], [
                 inventory_device("301", "ord-asw-301", "FOC#{suffix}301")
               ]),
               %{partition: "default"},
               actor: actor
             )

    by_object = Map.new(observations!(actor, instance), &{&1.source_object_id, &1})
    assert by_object["301"].present
    assert by_object["301"].collection_id == second_collection
    refute by_object["302"].present
    assert %DateTime{} = by_object["302"].absent_since

    snapshot = snapshot!(actor, instance)
    assert snapshot.collection_id == second_collection
    assert snapshot.device_count == 1
    assert snapshot.absent_count == 1

    # Command retries replay the same collection without adding rows or
    # changing the activated snapshot.
    assert :ok =
             DeviceDiscoveryIngestor.ingest(
               inventory_payload(instance, second_collection, ~U[2026-07-14 18:00:00Z], [
                 inventory_device("301", "ord-asw-301", "FOC#{suffix}301")
               ]),
               %{partition: "default"},
               actor: actor
             )

    assert length(observations!(actor, instance)) == 2
    assert snapshot!(actor, instance).collection_id == second_collection
  end

  test "same IP and hostname do not merge devices with conflicting scoped serials", %{
    actor: actor
  } do
    suffix = unique_suffix()
    instance = "conflict-#{suffix}"
    ip = "10.241.#{unique_octet()}.20"
    hostname = "conflict-asw-#{suffix}"
    armis_id = "armis-conflict-#{suffix}"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "hostname" => hostname,
                   "ip" => ip,
                   "source" => "armis",
                   "metadata" => %{
                     "armis_device_id" => armis_id,
                     "integration_type" => "armis",
                     "vendor_name" => "Cisco",
                     "serial_number" => "AR#{suffix}"
                   }
                 }
               ],
               actor: actor
             )

    assert :ok =
             DeviceDiscoveryIngestor.ingest(
               inventory_payload(
                 instance,
                 "collection-conflict-#{suffix}",
                 ~U[2026-07-13 18:00:00Z],
                 [inventory_device("401", hostname, "HP#{suffix}", ip)]
               ),
               %{partition: "default"},
               actor: actor
             )

    armis_owner = identifier!(actor, :armis_device_id, armis_id).device_id

    plugin_owner =
      identifier!(actor, :integration_id, "example-inventory:v1:#{instance}:device:401").device_id

    refute plugin_owner == armis_owner
  end

  test "source inventory pages stay pinned to one complete collection", %{actor: actor} do
    suffix = unique_suffix()
    instance = "reader-#{suffix}"
    first_collection = "reader-collection-#{suffix}-1"

    assert :ok =
             DeviceDiscoveryIngestor.ingest(
               inventory_payload(instance, first_collection, ~U[2026-07-13 18:00:00Z], [
                 inventory_device("501", "iad-asw-501", "FOC#{suffix}501"),
                 inventory_device("502", "iad-asw-502", "FOC#{suffix}502")
               ]),
               %{partition: "default"},
               actor: actor
             )

    assert {:ok, first_page} =
             SourceInventoryReader.list(%{
               "source" => "example-inventory",
               "instance" => instance,
               "limit" => "1"
             })

    assert first_page["collection"]["id"] == first_collection
    assert first_page["collection"]["expected_present_count"] == 2
    assert first_page["pagination"]["has_more"]
    assert [first_row] = first_page["rows"]
    cursor = first_page["pagination"]["next_cursor"]

    assert {:ok, second_page} =
             SourceInventoryReader.list(%{
               "source" => "example-inventory",
               "instance" => instance,
               "collection" => first_collection,
               "cursor" => cursor,
               "limit" => "1"
             })

    assert [second_row] = second_page["rows"]
    refute first_row["source_object_id"] == second_row["source_object_id"]
    refute second_page["pagination"]["has_more"]
    assert is_nil(second_page["pagination"]["next_cursor"])

    assert :ok =
             DeviceDiscoveryIngestor.ingest(
               inventory_payload(
                 instance,
                 "reader-collection-#{suffix}-2",
                 ~U[2026-07-13 19:00:00Z],
                 [inventory_device("501", "iad-asw-501", "FOC#{suffix}501")]
               ),
               %{partition: "default"},
               actor: actor
             )

    assert {:error, :source_collection_changed} =
             SourceInventoryReader.list(%{
               "source" => "example-inventory",
               "instance" => instance,
               "collection" => first_collection,
               "cursor" => cursor,
               "limit" => "1"
             })
  end

  defp identifier!(actor, type, value) do
    {:ok, [identifier]} =
      DeviceIdentifier
      |> Ash.Query.for_read(:lookup, %{
        identifier_type: type,
        identifier_value: value,
        partition: "default"
      })
      |> Ash.read(actor: actor)

    identifier
  end

  defp observations!(actor, instance) do
    {:ok, observations} =
      DeviceSourceObservation
      |> Ash.Query.filter(source == "example-inventory" and source_instance == ^instance)
      |> Ash.read(actor: actor)

    observations
  end

  defp snapshot!(actor, instance) do
    {:ok, [snapshot]} =
      DeviceSourceSnapshot
      |> Ash.Query.filter(source == "example-inventory" and source_instance == ^instance)
      |> Ash.read(actor: actor)

    snapshot
  end

  defp inventory_payload(instance, collection_id, observed_at, devices) do
    hash_seed = :sha256 |> :crypto.hash(collection_id) |> Base.encode16(case: :lower)

    %{
      "status" => "OK",
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "example-inventory",
          "collection_id" => collection_id,
          "reference_hash" => hash_seed,
          "observed_at" => DateTime.to_iso8601(observed_at),
          "metadata" => %{
            "source_instance" => instance,
            "snapshot_complete" => true,
            "query_hash" => String.duplicate("b", 64),
            "page_count" => 1,
            "received_rows" => length(devices)
          },
          "devices" =>
            Enum.map(devices, fn device ->
              integration_id = "example-inventory:v1:#{instance}:device:#{device.id}"

              %{
                "device_id" => device.id,
                "hostname" => device.hostname,
                "ip" => device.ip,
                "serial" => device.serial,
                "vendor_name" => "Cisco",
                "model" => "C9300",
                "type" => "Switch",
                "metadata" => %{
                  "integration_id" => integration_id,
                  "integration_type" => "example-inventory",
                  "source_metadata" => %{
                    "instance_id" => instance,
                    "partition" => "IAD",
                    "management_status" => "Managed",
                    "present" => true
                  }
                }
              }
            end)
        }
      ]
    }
  end

  defp inventory_device(id, hostname, serial, ip \\ nil) do
    %{
      id: id,
      hostname: hostname,
      serial: serial,
      ip: ip || "10.242.#{unique_octet()}.#{rem(String.to_integer(id), 200) + 20}"
    }
  end

  defp unique_suffix do
    [:positive] |> System.unique_integer() |> Integer.to_string()
  end

  defp unique_octet do
    [:positive] |> System.unique_integer() |> rem(200) |> Kernel.+(20)
  end
end

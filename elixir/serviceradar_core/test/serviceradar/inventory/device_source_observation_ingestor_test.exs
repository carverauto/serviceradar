defmodule ServiceRadar.Inventory.DeviceSourceObservationIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor

  test "normalizes a complete plugin inventory snapshot after canonical resolution" do
    parent = self()
    envelope = inventory_envelope()
    updates = [inventory_update("101", "iad-asw-01")]

    resolver = fn devices, partition ->
      send(parent, {:resolve, devices, partition})
      {:ok, %{"example-inventory:v1:example-lab:device:101" => "sr:canonical-101"}}
    end

    activator = fn snapshot, observations ->
      send(parent, {:activate, snapshot, observations})
      :ok
    end

    assert :ok =
             DeviceSourceObservationIngestor.ingest(
               envelope,
               updates,
               %{partition: "default"},
               resolver: resolver,
               activator: activator
             )

    assert_receive {:resolve, [source_device], "default"}
    assert source_device.source_object_id == "101"
    assert source_device.source_integration_id == "example-inventory:v1:example-lab:device:101"

    assert_receive {:activate, snapshot, [observation]}
    assert snapshot.source_instance == "example-lab"
    assert snapshot.collection_id == "collection-1"
    assert snapshot.content_hash == String.duplicate("a", 64)
    assert observation.device_id == "sr:canonical-101"
    assert observation.hostname == "iad-asw-01"
    assert observation.vendor_name == "Cisco"
    assert observation.serial_number == "FOC1234ABC"
    assert observation.management_status == "Managed"
    assert observation.present
  end

  test "ignores discovery envelopes that are not declared complete snapshots" do
    envelope = put_in(inventory_envelope(), ["metadata", "snapshot_complete"], false)

    assert :ok =
             DeviceSourceObservationIngestor.ingest(
               envelope,
               [inventory_update("101", "iad-asw-01")],
               %{partition: "default"},
               resolver: fn _, _ -> flunk("resolver must not run") end,
               activator: fn _, _ -> flunk("activator must not run") end
             )
  end

  test "rejects duplicate source objects in one complete collection" do
    updates = [inventory_update("101", "iad-asw-01"), inventory_update("101", "iad-asw-02")]

    assert {:error, :duplicate_source_object} =
             DeviceSourceObservationIngestor.ingest(
               inventory_envelope(),
               updates,
               %{partition: "default"},
               resolver: fn _, _ -> flunk("resolver must not run") end,
               activator: fn _, _ -> flunk("activator must not run") end
             )
  end

  test "ignores ordinary discovery envelopes" do
    assert :ok =
             DeviceSourceObservationIngestor.ingest(
               %{"source" => "proxmox"},
               [],
               %{},
               resolver: fn _, _ -> flunk("resolver must not run") end,
               activator: fn _, _ -> flunk("activator must not run") end
             )
  end

  test "preflight returns the snapshot disposition from its checker" do
    parent = self()

    checker = fn snapshot ->
      send(parent, {:checked, snapshot})
      {:ok, :idempotent}
    end

    assert {:ok, :idempotent} =
             DeviceSourceObservationIngestor.preflight(
               inventory_envelope(),
               [inventory_update("101", "iad-asw-01")],
               %{partition: "default"},
               checker: checker
             )

    assert_receive {:checked, snapshot}
    assert snapshot.source == "example-inventory"
    assert snapshot.source_instance == "example-lab"
  end

  test "preflight validates the collection before checking current state" do
    invalid = put_in(inventory_envelope(), ["reference_hash"], "not-a-sha256")

    assert {:error, :invalid_content_hash} =
             DeviceSourceObservationIngestor.preflight(
               invalid,
               [inventory_update("101", "iad-asw-01")],
               %{partition: "default"},
               checker: fn _ -> flunk("checker must not run") end
             )
  end

  test "ordinary discovery preflight does not query source snapshot state" do
    assert {:ok, :process} =
             DeviceSourceObservationIngestor.preflight(
               %{"source" => "proxmox"},
               [],
               %{},
               checker: fn _ -> flunk("checker must not run") end
             )
  end

  defp inventory_envelope do
    %{
      "schema" => "serviceradar.device_discovery.v1",
      "source" => "example-inventory",
      "collection_id" => "collection-1",
      "reference_hash" => String.duplicate("a", 64),
      "observed_at" => "2026-07-13T18:00:00.123456Z",
      "metadata" => %{
        "source_instance" => "example-lab",
        "snapshot_complete" => true,
        "query_hash" => String.duplicate("b", 64),
        "page_count" => 1,
        "received_rows" => 1
      }
    }
  end

  defp inventory_update(device_id, hostname) do
    %{
      "partition" => "default",
      "source" => "example-inventory",
      "device_id" => device_id,
      "hostname" => hostname,
      "ip" => "192.0.2.10",
      "mac" => "00:11:22:33:44:55",
      "metadata" => %{
        "integration_id" => "example-inventory:v1:example-lab:device:#{device_id}",
        "integration_type" => "example-inventory",
        "source_metadata" => %{
          "instance_id" => "example-lab",
          "partition" => "IAD",
          "management_status" => "Managed",
          "present" => true
        },
        "serial_number" => "FOC1234ABC",
        "vendor_name" => "Cisco",
        "model" => "C9300",
        "device_type" => "Switch",
        "status" => "Managed"
      }
    }
  end
end

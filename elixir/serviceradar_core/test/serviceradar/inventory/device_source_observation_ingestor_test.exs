defmodule ServiceRadar.Inventory.DeviceSourceObservationIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor

  test "normalizes a complete HPNA snapshot after canonical resolution" do
    parent = self()
    envelope = hpna_envelope()
    updates = [hpna_update("101", "iad-asw-01")]

    resolver = fn devices, partition ->
      send(parent, {:resolve, devices, partition})
      {:ok, %{"hpna:v1:lab-hpna:device:101" => "sr:canonical-101"}}
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
    assert source_device.source_integration_id == "hpna:v1:lab-hpna:device:101"

    assert_receive {:activate, snapshot, [observation]}
    assert snapshot.source_instance == "lab-hpna"
    assert snapshot.collection_id == "collection-1"
    assert snapshot.content_hash == String.duplicate("a", 64)
    assert observation.device_id == "sr:canonical-101"
    assert observation.hostname == "iad-asw-01"
    assert observation.vendor_name == "Cisco"
    assert observation.serial_number == "FOC1234ABC"
    assert observation.management_status == "Managed"
    assert observation.present
  end

  test "rejects incomplete snapshots before resolution or activation" do
    envelope = put_in(hpna_envelope(), ["metadata", "snapshot_complete"], false)

    assert {:error, :incomplete_source_snapshot} =
             DeviceSourceObservationIngestor.ingest(
               envelope,
               [hpna_update("101", "iad-asw-01")],
               %{partition: "default"},
               resolver: fn _, _ -> flunk("resolver must not run") end,
               activator: fn _, _ -> flunk("activator must not run") end
             )
  end

  test "rejects duplicate source objects in one complete collection" do
    updates = [hpna_update("101", "iad-asw-01"), hpna_update("101", "iad-asw-02")]

    assert {:error, :duplicate_source_object} =
             DeviceSourceObservationIngestor.ingest(
               hpna_envelope(),
               updates,
               %{partition: "default"},
               resolver: fn _, _ -> flunk("resolver must not run") end,
               activator: fn _, _ -> flunk("activator must not run") end
             )
  end

  test "ignores non-HPNA discovery envelopes" do
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
               hpna_envelope(),
               [hpna_update("101", "iad-asw-01")],
               %{partition: "default"},
               checker: checker
             )

    assert_receive {:checked, snapshot}
    assert snapshot.source == "hpna"
    assert snapshot.source_instance == "lab-hpna"
  end

  test "preflight validates the collection before checking current state" do
    invalid = put_in(hpna_envelope(), ["reference_hash"], "not-a-sha256")

    assert {:error, :invalid_content_hash} =
             DeviceSourceObservationIngestor.preflight(
               invalid,
               [hpna_update("101", "iad-asw-01")],
               %{partition: "default"},
               checker: fn _ -> flunk("checker must not run") end
             )
  end

  test "non-HPNA preflight does not query source snapshot state" do
    assert {:ok, :process} =
             DeviceSourceObservationIngestor.preflight(
               %{"source" => "proxmox"},
               [],
               %{},
               checker: fn _ -> flunk("checker must not run") end
             )
  end

  defp hpna_envelope do
    %{
      "schema" => "serviceradar.device_discovery.v1",
      "source" => "hpna",
      "collection_id" => "collection-1",
      "reference_hash" => String.duplicate("a", 64),
      "observed_at" => "2026-07-13T18:00:00.123456Z",
      "metadata" => %{
        "source_instance" => "lab-hpna",
        "snapshot_complete" => true,
        "query_hash" => String.duplicate("b", 64),
        "page_count" => 1,
        "received_rows" => 1
      }
    }
  end

  defp hpna_update(device_id, hostname) do
    %{
      "partition" => "default",
      "source" => "hpna",
      "hostname" => hostname,
      "ip" => "192.0.2.10",
      "mac" => "00:11:22:33:44:55",
      "metadata" => %{
        "integration_id" => "hpna:v1:lab-hpna:device:#{device_id}",
        "integration_type" => "hpna",
        "hpna_instance_id" => "lab-hpna",
        "hpna_device_id" => device_id,
        "hpna_partition" => "IAD",
        "hpna_device_type" => "Switch",
        "hpna_management_status" => "Managed",
        "hpna_serial_number" => "FOC1234ABC",
        "serial_number" => "FOC1234ABC",
        "vendor_name" => "Cisco",
        "model" => "C9300"
      }
    }
  end
end

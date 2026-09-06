defmodule ServiceRadarWebNG.Devices.ManualDeviceCreatorTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Devices.ManualDeviceCreator

  defmodule HostnameResolverStub do
    @moduledoc false

    def resolve("missing-hostname.example"), do: {:error, :nxdomain}

    def resolve(hostname) when is_binary(hostname) do
      hash = :erlang.phash2(hostname, 65_025)
      third_octet = div(hash, 255)
      fourth_octet = rem(hash, 255)

      {:ok, "198.18.#{third_octet}.#{fourth_octet}"}
    end
  end

  setup do
    previous_resolver = Application.get_env(:serviceradar_web_ng, :device_hostname_resolver)
    Application.put_env(:serviceradar_web_ng, :device_hostname_resolver, HostnameResolverStub)

    on_exit(fn ->
      restore_app_env(:device_hostname_resolver, previous_resolver)
    end)

    user = AshTestHelpers.admin_user_fixture()

    {:ok, scope: Scope.for_user(user)}
  end

  test "manual ownership updates preserve metadata written after the device was read", %{
    scope: scope
  } do
    assert {:ok, stale} =
             create_device(scope, %{
               uid: "sr:" <> Ecto.UUID.generate(),
               ip: "192.0.2.85",
               hostname: "metadata-race.example.com",
               type: "Switch",
               type_id: 10,
               discovery_sources: ["armis"],
               metadata: %{"initial" => "retained"}
             })

    assert {:ok, _} =
             stale
             |> Ash.Changeset.for_update(:merge_metadata, %{
               metadata_patch: %{"later_enrichment" => "retained", "type_manually_set" => true}
             })
             |> Ash.update(scope: scope)

    assert {:ok, updated} = ManualDeviceCreator.update_existing_device(stale, %{}, scope)
    assert updated.metadata["type_manually_set"] == true
    assert updated.metadata["initial"] == "retained"
    assert updated.metadata["later_enrichment"] == "retained"

    assert {:ok, _} =
             updated
             |> Ash.Changeset.for_update(:merge_metadata, %{
               metadata_patch: %{"new_identity_fact" => "retained"}
             })
             |> Ash.update(scope: scope)

    assert {:ok, _} =
             ManualDeviceCreator.update_existing_device(
               stale,
               %{type: "Switch", type_id: 10},
               scope
             )

    assert {:ok, persisted} = Device.get_by_uid(stale.uid, false, scope: scope)
    assert persisted.metadata["type_manually_set"] == true
    assert persisted.metadata["later_enrichment"] == "retained"
    assert persisted.metadata["new_identity_fact"] == "retained"
  end

  test "manual selection replaces an inference committed after the import read", %{scope: scope} do
    ip = "192.0.2.86"
    hostname = "classification-race.example.com"

    assert {:ok, stale} =
             create_device(scope, %{
               uid: "sr:" <> Ecto.UUID.generate(),
               ip: ip,
               hostname: hostname,
               type: "Switch",
               type_id: 10,
               discovery_sources: ["armis"],
               metadata: %{"type_manually_set" => false}
             })

    integration_update = %{
      "ip" => ip,
      "hostname" => hostname,
      "source" => "armis",
      "metadata" => %{"armis_type" => "Tablet"}
    }

    assert :ok = SyncIngestor.ingest_updates([integration_update])
    assert {:ok, inferred} = Device.get_by_uid(stale.uid, false, scope: scope)
    assert {inferred.type, inferred.type_id} == {"Tablet", 4}

    assert {:ok, selected} =
             ManualDeviceCreator.update_existing_device(
               stale,
               %{type: "Switch", type_id: 10},
               scope
             )

    assert {selected.type, selected.type_id} == {"Switch", 10}
    assert selected.metadata["type_manually_set"] == true
    assert {:ok, persisted} = Device.get_by_uid(stale.uid, false, scope: scope)
    assert {persisted.type, persisted.type_id} == {"Switch", 10}

    assert :ok = SyncIngestor.ingest_updates([integration_update])
    assert {:ok, protected} = Device.get_by_uid(stale.uid, false, scope: scope)
    assert {protected.type, protected.type_id} == {"Switch", 10}
    assert protected.metadata["type_manually_set"] == true
  end

  test "an unchanged explicit type is protected but provenance alone is not", %{scope: scope} do
    ip = "192.0.2.84"
    hostname = "manual-selection.example.com"

    assert {:ok, existing} =
             create_device(scope, %{
               uid: "sr:" <> Ecto.UUID.generate(),
               ip: ip,
               hostname: hostname,
               type: "Switch",
               type_id: 10,
               discovery_sources: ["armis"]
             })

    assert {:ok, provenance_only} =
             ManualDeviceCreator.create(scope, %{ip: ip, hostname: hostname})

    assert provenance_only.uid == existing.uid
    assert "manual" in provenance_only.discovery_sources
    assert provenance_only.metadata["type_manually_set"] == false

    assert {:ok, refreshed} =
             provenance_only
             |> Ash.Changeset.for_update(:update, %{type: "camera", type_id: 99})
             |> Ash.update(scope: scope)

    assert refreshed.type == "camera"
    assert refreshed.metadata["type_manually_set"] == false

    for type <- ["Tablet", "Switch"] do
      assert :ok =
               SyncIngestor.ingest_updates([
                 %{
                   "ip" => ip,
                   "hostname" => hostname,
                   "source" => "armis",
                   "metadata" => %{"armis_type" => type}
                 }
               ])

      assert {:ok, inferred} = Device.get_by_uid(existing.uid, false, scope: scope)
      assert inferred.type == type
      assert inferred.metadata["type_manually_set"] == false
    end

    assert {:ok, selected} =
             ManualDeviceCreator.create(scope, %{ip: ip, hostname: hostname, type: "Switch"})

    assert selected.uid == existing.uid
    assert selected.type == "Switch"
    assert selected.type_id == 10
    assert selected.metadata["type_manually_set"] == true

    assert :ok =
             SyncIngestor.ingest_updates([
               %{
                 "ip" => ip,
                 "hostname" => hostname,
                 "source" => "armis",
                 "metadata" => %{"armis_type" => "Tablet"}
               }
             ])

    assert {:ok, protected} = Device.get_by_uid(existing.uid, false, scope: scope)
    assert protected.type == "Switch"
    assert protected.type_id == 10
    assert protected.metadata["type_manually_set"] == true
  end

  test "resolves hostname-only devices and persists the resolved IP", %{scope: scope} do
    first_hostname = "manual-host-a-#{System.unique_integer([:positive])}.example"
    second_hostname = "manual-host-b-#{System.unique_integer([:positive])}.example"

    assert {:ok, first} =
             ManualDeviceCreator.create(scope, %{
               "hostname" => first_hostname,
               "ip" => "",
               "type" => "server",
               "tags" => ["source=test"]
             })

    assert {:ok, second} =
             ManualDeviceCreator.create(scope, %{
               hostname: second_hostname,
               ip: nil,
               type: "server",
               tags: []
             })

    assert first.hostname == first_hostname
    assert second.hostname == second_hostname
    assert first.ip =~ "198.18."
    assert second.ip =~ "198.18."
    assert first.ip != second.ip
    assert first.discovery_sources == ["manual"]
    assert first.tags == %{"source" => "test"}
    assert first.is_managed == true
    assert first.is_active == true
    assert second.is_managed == true
    assert second.is_active == true
  end

  test "does not add hostname-only devices when DNS resolution fails", %{scope: scope} do
    assert {:error, {:hostname_resolution_failed, "missing-hostname.example", :nxdomain}} =
             ManualDeviceCreator.create(scope, %{
               hostname: "missing-hostname.example",
               ip: "",
               type: "server",
               tags: []
             })
  end

  test "requires either a resolvable hostname or an IP address", %{scope: scope} do
    assert {:error, :missing_device_address} =
             ManualDeviceCreator.create(scope, %{hostname: "", ip: "", type: "server", tags: []})
  end

  test "keeps a user-provided IP when both hostname and IP are supplied", %{scope: scope} do
    assert {:ok, device} =
             ManualDeviceCreator.create(scope, %{
               hostname: "missing-hostname.example",
               ip: "203.0.113.10",
               type: "server",
               tags: []
             })

    assert device.hostname == "missing-hostname.example"
    assert device.ip == "203.0.113.10"
  end

  test "updates an existing hostname-only manual device after resolving its IP", %{scope: scope} do
    hostname = "manual-existing-host-#{System.unique_integer([:positive])}.example"

    assert {:ok, legacy} =
             create_device(scope, %{
               uid: "legacy-hostname-only-#{System.unique_integer([:positive])}",
               hostname: hostname,
               ip: nil,
               type_id: 0,
               is_managed: true,
               is_active: true
             })

    assert {:ok, device} =
             ManualDeviceCreator.create(scope, %{
               hostname: hostname,
               ip: "",
               type: "server",
               tags: ["source=test"]
             })

    assert device.uid == legacy.uid
    assert device.hostname == hostname
    assert device.ip =~ "198.18."
    assert device.type == "server"
    assert device.type_id == 1
    assert device.tags == %{"source" => "test"}
    assert device.discovery_sources == ["manual"]
    assert device.is_active == true
  end

  test "restores a soft-deleted deterministic manual device instead of failing", %{scope: scope} do
    hostname = "manual-restore-#{System.unique_integer([:positive])}.example"

    assert {:ok, original} =
             ManualDeviceCreator.create(scope, %{
               hostname: hostname,
               ip: "",
               type: "server",
               tags: []
             })

    assert {:ok, deleted} =
             original
             |> Ash.Changeset.for_update(:soft_delete, %{
               deleted_by: "test",
               deleted_reason: "manual re-add test"
             })
             |> Ash.update(scope: scope)

    assert deleted.deleted_at

    assert {:ok, restored} =
             ManualDeviceCreator.create(scope, %{
               hostname: hostname,
               ip: "",
               type: "server",
               tags: ["owner=ops"]
             })

    assert restored.uid == original.uid
    assert restored.hostname == hostname
    assert restored.ip == original.ip
    assert is_nil(restored.deleted_at)
    assert restored.deleted_by == nil
    assert restored.deleted_reason == nil
    assert restored.tags == %{"owner" => "ops"}
  end

  test "upsert merges spreadsheet tags and metadata onto an existing IP-matched device", %{
    scope: scope
  } do
    ip = "203.0.113.#{rem(System.unique_integer([:positive]), 200) + 20}"

    assert {:ok, existing} =
             create_device(scope, %{
               uid: "armis-existing-#{System.unique_integer([:positive])}",
               hostname: "armis-host",
               ip: ip,
               type: "server",
               type_id: 1,
               tags: %{"env" => "prod"},
               metadata: %{"other_writer" => "keep-me"},
               is_managed: true,
               is_active: true
             })

    assert {:ok, :updated, device} =
             ManualDeviceCreator.upsert(scope, %{
               hostname: "rids-bos-b23",
               ip: ip,
               type: "rids",
               tags: ["rids=true", "site=BOS", "gate=B23"],
               metadata: %{"concourse" => "B", "model" => "DAK_VENUS1500_4LINE"}
             })

    assert device.uid == existing.uid
    assert device.hostname == "rids-bos-b23"
    assert device.ip == ip
    assert device.type == "server"
    assert device.type_id == 1
    assert device.tags["env"] == "prod"
    assert device.tags["rids"] == "true"
    assert device.tags["site"] == "BOS"
    assert device.tags["gate"] == "B23"
    assert device.metadata["other_writer"] == "keep-me"
    assert device.metadata["concourse"] == "B"
    assert device.metadata["model"] == "DAK_VENUS1500_4LINE"
    assert "manual" in device.discovery_sources
  end

  test "prefers a live IP match over a tombstoned uid when both match the row", %{scope: scope} do
    ip = "203.0.113.#{rem(System.unique_integer([:positive]), 200) + 20}"
    hostname = "rids-tombstone-#{System.unique_integer([:positive])}.example"

    assert {:ok, live} =
             create_device(scope, %{
               uid: "sr:" <> Ecto.UUID.generate(),
               hostname: "live-inventory",
               ip: ip,
               type: "server",
               type_id: 1,
               is_managed: true,
               is_active: true
             })

    assert {:ok, tombstoned} =
             create_device(scope, %{
               uid: "sr:" <> Ecto.UUID.generate(),
               hostname: hostname,
               ip: nil,
               type: "rids",
               type_id: 0,
               is_managed: true,
               is_active: true
             })

    assert {:ok, _} =
             tombstoned
             |> Ash.Changeset.for_update(:soft_delete, %{
               deleted_by: "test",
               deleted_reason: "merged away"
             })
             |> Ash.update(scope: scope)

    assert {:ok, :updated, device} =
             ManualDeviceCreator.upsert(scope, %{
               hostname: hostname,
               ip: ip,
               type: "rids",
               tags: ["site=BOS"]
             })

    assert device.uid == live.uid
    assert device.hostname == hostname
    assert is_nil(device.deleted_at)
    assert {:ok, still_deleted} = Device.get_by_uid(tombstoned.uid, true, scope: scope)
    assert still_deleted.deleted_at
  end

  test "merges active hostname-only duplicate into resolved-IP canonical device", %{scope: scope} do
    hostname = "manual-merge-#{System.unique_integer([:positive])}.example"
    assert {:ok, resolved_ip} = HostnameResolverStub.resolve(hostname)

    assert {:ok, canonical} =
             ManualDeviceCreator.create(scope, %{
               hostname: "",
               ip: resolved_ip,
               type: "server",
               tags: []
             })

    assert {:ok, legacy} =
             create_device(scope, %{
               uid: "legacy-duplicate-#{System.unique_integer([:positive])}",
               hostname: hostname,
               ip: nil,
               type_id: 0,
               is_managed: true,
               is_active: true
             })

    assert {:ok, device} =
             ManualDeviceCreator.create(scope, %{
               hostname: hostname,
               ip: "",
               type: "router",
               tags: ["location=lab"]
             })

    assert device.uid == canonical.uid
    assert device.hostname == hostname
    assert device.ip == resolved_ip
    assert device.type == "router"
    assert device.type_id == 12
    assert device.tags == %{"location" => "lab"}
    assert {:error, _} = Device.get_by_uid(legacy.uid, false, scope: scope)
  end

  test "the same IP can be created independently in default and another partition", %{
    scope: scope
  } do
    ip = "203.0.113.#{rem(System.unique_integer([:positive]), 200) + 20}"

    assert {:ok, isolation} =
             ManualDeviceCreator.create(scope, %{
               hostname: "rids-isolation",
               ip: ip,
               type: "rids",
               tags: ["role=isolation"]
             })

    assert isolation.partition == "default"

    assert {:ok, monitoring} =
             ManualDeviceCreator.create(scope, %{
               hostname: "rids-monitoring",
               ip: ip,
               partition: "rids",
               type: "rids",
               tags: ["role=monitoring"]
             })

    assert monitoring.partition == "rids"
    assert monitoring.uid != isolation.uid
    assert monitoring.ip == isolation.ip

    assert {:ok, :updated, updated_monitoring} =
             ManualDeviceCreator.upsert(scope, %{
               hostname: "rids-monitoring",
               ip: ip,
               partition: "rids",
               tags: ["site=ZZA"]
             })

    assert updated_monitoring.uid == monitoring.uid
    assert updated_monitoring.tags["role"] == "monitoring"
    assert updated_monitoring.tags["site"] == "ZZA"

    assert {:ok, still_isolation} = Device.get_by_uid(isolation.uid, false, scope: scope)
    assert still_isolation.tags == %{"role" => "isolation"}
    refute still_isolation.tags["site"]
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_app_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp create_device(scope, attrs) do
    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(scope: scope)
  end
end

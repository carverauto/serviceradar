defmodule ServiceRadar.Inventory.SyncBatchResolutionTest do
  @moduledoc """
  Integration coverage for batch identity resolution (tasks 2.4/5.1):

  - IP fallback never overrides strong identifiers (no adoption of an
    existing device just because it holds the update's IP)
  - distinct strong-identified updates in one batch stay distinct
    (regression for the 500-per-batch integration_id collapse)
  - active-IP-conflict recovery drops the conflicting IP from
    strong-identified records instead of remapping them onto the holder
  - pre-set merged-away sr: IDs resolve to the canonical survivor
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SourceIdentityConflict
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_batch_resolution_test)
    {:ok, actor: actor}
  end

  defp unique_ip do
    a = System.unique_integer([:positive])
    "10.#{rem(div(a, 65_536), 60) + 60}.#{rem(div(a, 256), 256)}.#{rem(a, 254) + 1}"
  end

  defp integration_update(integration_id, ip, hostname) do
    %{
      "ip" => ip,
      "hostname" => hostname,
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }
  end

  defp device_for_integration_id(integration_id, actor) do
    query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :integration_id,
        identifier_value: integration_id,
        partition: "default"
      })

    case Ash.read(query, actor: actor) do
      {:ok, [identifier | _]} -> identifier.device_id
      _ -> nil
    end
  end

  defp device_for_armis_id(armis_id, actor) do
    query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :armis_device_id,
        identifier_value: armis_id,
        partition: "default"
      })

    case Ash.read(query, actor: actor) do
      {:ok, [identifier | _]} -> identifier.device_id
      _ -> nil
    end
  end

  test "strong-identified update does not adopt an existing device by IP", %{actor: actor} do
    ip = unique_ip()

    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "ip-holder-#{System.unique_integer([:positive])}",
        ip: ip
      })
      |> Ash.create(actor: actor)

    integration_id = "it-#{System.unique_integer([:positive])}"
    update = integration_update(integration_id, ip, "strong-newcomer")

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    resolved = device_for_integration_id(integration_id, actor)
    assert is_binary(resolved)
    assert resolved != existing.uid
  end

  test "weak update still adopts an existing device by IP", %{actor: actor} do
    ip = unique_ip()

    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "weak-ip-holder-#{System.unique_integer([:positive])}",
        ip: ip
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => ip,
      "hostname" => "weak-sighting",
      "source" => "sweep"
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    {:ok, devices} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> ServiceRadar.Ash.Page.unwrap()

    assert [%Device{uid: uid}] = devices
    assert uid == existing.uid
  end

  test "distinct strong-identified updates in one batch stay distinct devices", %{actor: actor} do
    count = 20

    updates =
      for n <- 1..count do
        integration_update(
          "batch-it-#{System.unique_integer([:positive])}-#{n}",
          unique_ip(),
          "batch-host-#{n}"
        )
      end

    assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)

    device_ids =
      Enum.map(updates, fn u ->
        device_for_integration_id(u["metadata"]["integration_id"], actor)
      end)

    assert Enum.all?(device_ids, &is_binary/1)
    assert length(Enum.uniq(device_ids)) == count
  end

  test "IP conflict drops IP from strong-identified record instead of remapping", %{actor: actor} do
    ip = unique_ip()
    integration_a = "conflict-a-#{System.unique_integer([:positive])}"
    integration_b = "conflict-b-#{System.unique_integer([:positive])}"

    # First strong device claims the IP.
    assert :ok =
             SyncIngestor.ingest_updates([integration_update(integration_a, ip, "holder-a")],
               actor: actor
             )

    # Second strong device arrives claiming the SAME IP in a later batch.
    assert :ok =
             SyncIngestor.ingest_updates([integration_update(integration_b, ip, "claimer-b")],
               actor: actor
             )

    device_a = device_for_integration_id(integration_a, actor)
    device_b = device_for_integration_id(integration_b, actor)

    assert is_binary(device_a)
    assert is_binary(device_b)
    assert device_a != device_b

    {:ok, %Device{deleted_at: nil}} = Device.get_by_uid(device_a, false, actor: actor)
    {:ok, device_b_row} = Device.get_by_uid(device_b, false, actor: actor)
    refute device_b_row.ip == ip

    assert {:ok, conflicts} =
             SourceIdentityConflict
             |> Ash.Query.filter(
               conflict_category == "active_ip_conflict" and device_uid == ^device_b and
                 current_ip == ^ip
             )
             |> Ash.read(actor: actor)

    assert [%SourceIdentityConflict{} | _] = conflicts
  end

  test "same Armis source ID can move IP without changing canonical device", %{actor: actor} do
    armis_id = "armis-dhcp-#{System.unique_integer([:positive])}"
    source_id = "armis-source-#{System.unique_integer([:positive])}"
    ip_a = unique_ip()
    ip_b = unique_ip()

    update = fn ip ->
      %{
        "ip" => ip,
        "hostname" => "armis-dhcp-host",
        "source" => "armis",
        "metadata" => %{
          "integration_type" => "armis",
          "armis_device_id" => armis_id,
          "integration_id" => armis_id
        },
        "sync_meta" => %{"sync_service_id" => source_id}
      }
    end

    assert :ok = SyncIngestor.ingest_updates([update.(ip_a)], actor: actor)
    canonical = device_for_armis_id(armis_id, actor)
    assert is_binary(canonical)

    assert :ok = SyncIngestor.ingest_updates([update.(ip_b)], actor: actor)

    assert device_for_armis_id(armis_id, actor) == canonical

    assert {:ok, %Device{uid: ^canonical, ip: ^ip_b}} =
             Device.get_by_uid(canonical, false, actor: actor)

    assert 1 ==
             Repo.one(
               from(di in DeviceIdentifier,
                 where:
                   di.identifier_type == :armis_device_id and
                     di.identifier_value == ^armis_id,
                 select: count(di.id)
               )
             )
  end

  test "generic integration ID values are source-scoped across integration sources", %{
    actor: actor
  } do
    shared_integration_id = "shared-generic-#{System.unique_integer([:positive])}"
    source_a = "source-a-#{System.unique_integer([:positive])}"
    source_b = "source-b-#{System.unique_integer([:positive])}"

    update = fn source_id, ip ->
      %{
        "ip" => ip,
        "hostname" => "generic-#{source_id}",
        "source" => "integration-test",
        "metadata" => %{
          "integration_type" => "test-integration",
          "integration_id" => shared_integration_id
        },
        "sync_meta" => %{"sync_service_id" => source_id}
      }
    end

    assert :ok = SyncIngestor.ingest_updates([update.(source_a, unique_ip())], actor: actor)
    assert :ok = SyncIngestor.ingest_updates([update.(source_b, unique_ip())], actor: actor)

    scoped_a = "test-integration:source:#{source_a}:#{shared_integration_id}"
    scoped_b = "test-integration:source:#{source_b}:#{shared_integration_id}"

    device_a = device_for_integration_id(scoped_a, actor)
    device_b = device_for_integration_id(scoped_b, actor)

    assert is_binary(device_a)
    assert is_binary(device_b)
    assert device_a != device_b
  end

  test "source-scoped integration ID resolves through pre-existing raw bridge", %{
    actor: actor
  } do
    raw_integration_id = "legacy-raw-#{System.unique_integer([:positive])}"
    source_id = "upgrade-source-#{System.unique_integer([:positive])}"

    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "legacy-raw-owner-#{System.unique_integer([:positive])}",
        ip: unique_ip()
      })
      |> Ash.create(actor: actor)

    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: existing.uid,
        identifier_type: :integration_id,
        identifier_value: raw_integration_id,
        partition: "default",
        confidence: :strong,
        metadata: %{"integration_type" => "test-integration"}
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => unique_ip(),
      "hostname" => "legacy-raw-resync",
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => raw_integration_id
      },
      "sync_meta" => %{"sync_service_id" => source_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    scoped = "test-integration:source:#{source_id}:#{raw_integration_id}"

    assert device_for_integration_id(raw_integration_id, actor) == existing.uid
    assert device_for_integration_id(scoped, actor) == existing.uid
  end

  test "pre-set merged-away sr: ID resolves to canonical survivor", %{actor: actor} do
    {:ok, from_device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "batch-follow-from-#{System.unique_integer([:positive])}",
        ip: nil
      })
      |> Ash.create(actor: actor)

    {:ok, to_device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "batch-follow-to-#{System.unique_integer([:positive])}",
        ip: nil
      })
      |> Ash.create(actor: actor)

    assert :ok =
             IdentityReconciler.merge_devices(from_device.uid, to_device.uid,
               actor: actor,
               reason: "manual_merge"
             )

    integration_id = "follow-it-#{System.unique_integer([:positive])}"

    update = %{
      "device_id" => from_device.uid,
      "ip" => unique_ip(),
      "hostname" => "batch-follow-update",
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    # The identifier must land on the survivor, not resurrect the tombstone.
    assert device_for_integration_id(integration_id, actor) == to_device.uid
  end

  test "explicit Armis device ID resolves to existing owner when source ID differs", %{
    actor: actor
  } do
    armis_id = "armis-legacy-#{System.unique_integer([:positive])}"
    source_id = "legacy-source-#{System.unique_integer([:positive])}"

    canonical_update = %{
      device_id: nil,
      ip: nil,
      mac: nil,
      hostname: "armis-canonical",
      partition: "default",
      metadata: %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert {:ok, canonical_uid} =
             IdentityReconciler.resolve_device_id(canonical_update, actor: actor)

    legacy_update = %{
      "hostname" => "armis-legacy",
      "source" => "armis",
      "metadata" => %{
        "integration_type" => "armis",
        "armis_device_id" => armis_id,
        "source_device_id" => source_id,
        "integration_id" => armis_id
      }
    }

    assert :ok = SyncIngestor.ingest_updates([legacy_update], actor: actor)

    assert device_for_armis_id(armis_id, actor) == canonical_uid

    assert {:ok, %Device{uid: ^canonical_uid}} =
             Device.get_by_uid(canonical_uid, false, actor: actor)

    assert 1 ==
             Repo.one(
               from(d in Device,
                 where:
                   is_nil(d.deleted_at) and
                     fragment("?->>'source_device_id' = ?", d.metadata, ^source_id),
                 select: count(d.uid)
               )
             )
  end

  test "cold explicit Armis ingest registers armis_device_id identifier", %{actor: actor} do
    armis_id = "armis-cold-#{System.unique_integer([:positive])}"

    update = %{
      "hostname" => "armis-cold",
      "source" => "armis",
      "metadata" => %{
        "integration_type" => "armis",
        "armis_device_id" => armis_id,
        "source_device_id" => "legacy-source-#{System.unique_integer([:positive])}",
        "integration_id" => armis_id
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert device_uid = device_for_armis_id(armis_id, actor)
    assert {:ok, %Device{uid: ^device_uid}} = Device.get_by_uid(device_uid, false, actor: actor)
  end

  # Two universally-administered MACs (IEEE local bit 0x02 CLEAR in the first
  # octet) — globally-unique hardware anchors.
  defp universal_mac,
    do:
      "00#{~c"~10.16.0B" |> :io_lib.format([System.unique_integer([:positive])]) |> to_string()}"
      |> String.slice(0, 12)
      |> String.upcase()

  # A locally-administered MAC (IEEE local bit 0x02 SET in the first octet `02`)
  # — a virtual/Docker/overlay NIC, NOT a hardware anchor. Such a MAC must never
  # drive a device split (it is rejected from both the incoming and canonical
  # universal-MAC sets), so it can never trigger the distinct-MAC veto.
  defp local_mac,
    do:
      "02#{~c"~10.16.0B" |> :io_lib.format([System.unique_integer([:positive])]) |> to_string()}"
      |> String.slice(0, 12)
      |> String.upcase()

  test "shared armis_device_id with a distinct universal MAC splits to a NEW device", %{
    actor: actor
  } do
    armis_id = "armis-veto-#{System.unique_integer([:positive])}"
    mac_a = universal_mac()
    mac_b = universal_mac()
    refute mac_a == mac_b

    # First record registers the armis canonical and its hardware MAC.
    update_a = %{
      "hostname" => "veto-host-a",
      "source" => "armis",
      "mac" => mac_a,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update_a], actor: actor)
    canonical = device_for_armis_id(armis_id, actor)
    assert is_binary(canonical)

    # Second record shares the armis_device_id but carries a DISJOINT universal
    # MAC -> distinct hardware -> must NOT collapse onto the armis canonical.
    update_b = %{
      "hostname" => "veto-host-b",
      "source" => "armis",
      "mac" => mac_b,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

    device_for_b = device_for_mac(mac_b, actor)
    assert is_binary(device_for_b)

    assert device_for_b != canonical,
           "distinct-MAC record was over-merged onto the armis canonical"
  end

  test "shared armis_device_id re-observing the SAME MAC stays the same device", %{actor: actor} do
    armis_id = "armis-same-#{System.unique_integer([:positive])}"
    mac = universal_mac()

    update = %{
      "hostname" => "same-host",
      "source" => "armis",
      "mac" => mac,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
    canonical = device_for_armis_id(armis_id, actor)
    assert is_binary(canonical)

    # Re-observe the identical (armis_device_id, MAC) pair -> same device, no
    # split (MAC sets intersect -> veto does not fire).
    assert :ok =
             SyncIngestor.ingest_updates(
               [%{update | "hostname" => "same-host-reobserved"}],
               actor: actor
             )

    assert device_for_mac(mac, actor) == canonical
    assert device_for_armis_id(armis_id, actor) == canonical
  end

  test "shared armis_device_id with a disjoint LOCALLY-administered MAC stays the same device",
       %{actor: actor} do
    # Network-agnostic invariant: a locally-administered MAC (virtual/Docker/
    # overlay NIC) is NOT a hardware anchor. Even though it is disjoint from the
    # canonical's universal MAC, it is rejected from both veto sides, so the
    # incoming armis record must attach to the existing canonical (no split).
    # A regression dropping the `Enum.reject(&Mac.locally_administered_mac?/1)`
    # would treat this disjoint MAC as a hardware anchor and wrongly split.
    armis_id = "armis-local-#{System.unique_integer([:positive])}"
    universal = universal_mac()
    local = local_mac()

    update_a = %{
      "hostname" => "local-host-a",
      "source" => "armis",
      "mac" => universal,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update_a], actor: actor)
    canonical = device_for_armis_id(armis_id, actor)
    assert is_binary(canonical)

    # Same armis_device_id, but the incoming MAC is locally-administered and
    # disjoint from the canonical's universal MAC -> veto must NOT fire.
    update_b = %{
      "hostname" => "local-host-b",
      "source" => "armis",
      "mac" => local,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

    assert device_for_armis_id(armis_id, actor) == canonical,
           "a disjoint locally-administered MAC must not trigger the distinct-MAC veto"
  end

  test "atomic incoming MAC that is a member of a legacy comma-blob canonical stays the same device",
       %{actor: actor} do
    # Blob-canonical asymmetry: legacy `:mac` identifier rows can be comma-blobs
    # of multiple universal MACs. `universal_macs/1` runs `normalize_mac_list/1`
    # on BOTH sides, so the atomic incoming MAC is compared against the canonical
    # blob's NORMALIZED member set. The veto must NOT fire when the incoming
    # atomic MAC is a member of the blob. Without the canonical-side normalize,
    # the raw blob string reads as disjoint from the atomic MAC and over-splits.
    armis_id = "armis-blob-#{System.unique_integer([:positive])}"
    mac_member = universal_mac()
    mac_other = universal_mac()
    refute mac_member == mac_other

    # Seed a canonical via armis_device_id with NO mac on the ingest path.
    update_a = %{
      "hostname" => "blob-host",
      "source" => "armis",
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update_a], actor: actor)
    canonical = device_for_armis_id(armis_id, actor)
    assert is_binary(canonical)

    # Directly seed the canonical's `:mac` identifier as a legacy comma-blob of
    # two universal MACs (the value an older ingest could have persisted).
    {:ok, _} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: canonical,
        identifier_type: :mac,
        identifier_value: "#{mac_member},#{mac_other}",
        partition: "default",
        confidence: :strong
      })
      |> Ash.create(actor: actor)

    # Incoming armis record (same armis_device_id) carries ONE atomic MAC that is
    # a member of the canonical's blob -> normalized sets intersect -> no veto.
    update_b = %{
      "hostname" => "blob-host-reobserved",
      "source" => "armis",
      "mac" => mac_member,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

    assert device_for_armis_id(armis_id, actor) == canonical,
           "an atomic MAC inside the canonical's comma-blob must not trigger the veto"
  end

  test "shared armis_device_id with NO incoming MAC stays the same device", %{actor: actor} do
    # Negative guard (a): incoming-empty. A re-observation carrying no MAC has an
    # empty incoming universal-MAC set, so the veto cannot fire (it requires both
    # sides non-empty) -> the record attaches to the existing canonical.
    armis_id = "armis-nomac-#{System.unique_integer([:positive])}"
    mac = universal_mac()

    update_a = %{
      "hostname" => "nomac-host-a",
      "source" => "armis",
      "mac" => mac,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update_a], actor: actor)
    canonical = device_for_armis_id(armis_id, actor)
    assert is_binary(canonical)

    # Same armis_device_id, but this record carries NO mac at all.
    update_b = %{
      "hostname" => "nomac-host-b",
      "source" => "armis",
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

    assert device_for_armis_id(armis_id, actor) == canonical,
           "a MAC-less re-observation must not trigger the distinct-MAC veto"
  end

  test "direct :mac match is never vetoed even with DIFFERENT armis_device_ids", %{
    actor: actor
  } do
    # Negative guard (b): a direct `:mac` identifier match is self-consistent and
    # is NEVER vetoed (the `id_type == :mac` branch returns the device before the
    # veto can run). Two records carry the SAME hardware MAC but DIFFERENT
    # armis_device_ids; resolution is driven by the shared `:mac` identifier, so
    # the second record must resolve to the SAME device as the first.
    mac = universal_mac()
    armis_a = "armis-direct-a-#{System.unique_integer([:positive])}"
    armis_b = "armis-direct-b-#{System.unique_integer([:positive])}"

    update_a = %{
      "hostname" => "direct-mac-a",
      "source" => "armis",
      "mac" => mac,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_a}
    }

    assert :ok = SyncIngestor.ingest_updates([update_a], actor: actor)
    canonical = device_for_mac(mac, actor)
    assert is_binary(canonical)

    # Second record: same MAC, a DIFFERENT armis_device_id. The direct `:mac`
    # match (priority over armis_device_id) resolves it to the same device.
    update_b = %{
      "hostname" => "direct-mac-b",
      "source" => "armis",
      "mac" => mac,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_b}
    }

    assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

    assert device_for_mac(mac, actor) == canonical,
           "a direct :mac identifier match must never be vetoed"
  end

  defp device_for_mac(mac, actor) do
    query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :mac,
        identifier_value: mac,
        partition: "default"
      })

    case Ash.read(query, actor: actor) do
      {:ok, [identifier | _]} -> identifier.device_id
      _ -> nil
    end
  end
end

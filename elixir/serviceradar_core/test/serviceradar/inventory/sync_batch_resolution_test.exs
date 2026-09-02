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

  use ServiceRadar.DataCase, async: true

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

  defp device_for_armis_id(armis_id, actor, partition \\ "default") do
    query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :armis_device_id,
        identifier_value: armis_id,
        partition: partition
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

  # The holder here is what the manual and sweep creation paths actually produce:
  # an IP and nothing else -- no anchor, and no `identity_state` stamp, because
  # only the registrar path writes one. It used to be treated as an established
  # identity, so the incoming device lost its IP and re-collided every sync
  # forever. It must be adopted instead: the seed keeps its uid and gains the
  # discovered identity.
  test "anchorless holder with no identity_state is adopted, not deadlocked", %{actor: actor} do
    ip = unique_ip()
    integration_id = "adopt-seed-#{System.unique_integer([:positive])}"

    seed_uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _seed} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{uid: seed_uid, ip: ip, metadata: %{"source" => "manual"}},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert :ok =
             SyncIngestor.ingest_updates([integration_update(integration_id, ip, "claimer")],
               actor: actor
             )

    # Adopted: the incoming strong identity resolves onto the seed's uid.
    assert device_for_integration_id(integration_id, actor) == seed_uid

    # The seed keeps the IP rather than both rows losing it.
    {:ok, seed_row} = Device.get_by_uid(seed_uid, false, actor: actor)
    assert seed_row.ip == ip

    # Nothing to escalate, so no conflict is recorded.
    assert {:ok, []} =
             SourceIdentityConflict
             |> Ash.Query.filter(conflict_category == "active_ip_conflict" and current_ip == ^ip)
             |> Ash.read(actor: actor)
  end

  # The boundary the narrowing protects: an anchorless holder that carries a MAC
  # is NOT an IP-only seed, so it keeps its IP and the collision is escalated.
  # (The hostname half of this boundary is covered by "strong-identified update
  # does not adopt an existing device by IP" above.)
  test "anchorless holder with a MAC is not an IP-only seed", %{actor: actor} do
    ip = unique_ip()
    integration_id = "mac-holder-#{System.unique_integer([:positive])}"
    holder_uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _holder} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{uid: holder_uid, ip: ip, mac: "02:00:00:00:00:01"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert :ok =
             SyncIngestor.ingest_updates([integration_update(integration_id, ip, "claimer")],
               actor: actor
             )

    claimer_uid = device_for_integration_id(integration_id, actor)
    assert is_binary(claimer_uid)
    assert claimer_uid != holder_uid

    {:ok, holder_row} = Device.get_by_uid(holder_uid, false, actor: actor)
    assert holder_row.ip == ip
  end

  # The escape hatch: a row that explicitly claims `identity_state: "canonical"`
  # is an assertion of identity even with no anchor registered yet, so it is NOT
  # adoptable and the collision is escalated as before.
  test "explicitly canonical anchorless holder is not adopted", %{actor: actor} do
    ip = unique_ip()
    integration_id = "canonical-holder-#{System.unique_integer([:positive])}"

    holder_uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _holder} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{uid: holder_uid, ip: ip, metadata: %{"identity_state" => "canonical"}},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert :ok =
             SyncIngestor.ingest_updates([integration_update(integration_id, ip, "claimer")],
               actor: actor
             )

    claimer_uid = device_for_integration_id(integration_id, actor)
    assert is_binary(claimer_uid)
    assert claimer_uid != holder_uid

    {:ok, holder_row} = Device.get_by_uid(holder_uid, false, actor: actor)
    assert holder_row.ip == ip

    {:ok, claimer_row} = Device.get_by_uid(claimer_uid, false, actor: actor)
    refute claimer_row.ip == ip
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
    partition = "default:armis:#{source_id}"
    canonical = device_for_armis_id(armis_id, actor, partition)
    assert is_binary(canonical)

    assert :ok = SyncIngestor.ingest_updates([update.(ip_b)], actor: actor)

    assert device_for_armis_id(armis_id, actor, partition) == canonical

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

  test "Armis poller agent_id is observer provenance and cannot bypass the MAC veto", %{
    actor: actor
  } do
    armis_id = "armis-poller-veto-#{System.unique_integer([:positive])}"
    poller_agent_id = "armis-poller-#{System.unique_integer([:positive])}"
    mac_a = universal_mac()
    mac_b = universal_mac()

    update = fn hostname, ip, mac, source_device_id ->
      %{
        "agent_id" => poller_agent_id,
        "gateway_id" => "armis-gateway",
        "partition" => "default",
        "device_id" => "default:#{ip}",
        "ip" => ip,
        "hostname" => hostname,
        "source" => "armis",
        "mac" => mac,
        "metadata" => %{
          "integration_type" => "armis",
          "armis_device_id" => armis_id,
          "integration_id" => armis_id,
          "source_device_id" => source_device_id
        }
      }
    end

    update_a = update.("poller-host-a", unique_ip(), mac_a, "source-a")
    update_b = update.("poller-host-b", unique_ip(), mac_b, "source-b")

    assert :ok = SyncIngestor.ingest_updates([update_a], actor: actor)
    assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

    device_a = device_for_mac(mac_a, actor)
    device_b = device_for_mac(mac_b, actor)

    assert is_binary(device_a)
    assert is_binary(device_b)
    assert device_a != device_b

    refute Repo.exists?(
             from(identifier in DeviceIdentifier,
               where:
                 identifier.identifier_type == :agent_id and
                   identifier.identifier_value == ^poller_agent_id
             )
           )
  end

  test "Armis poller provenance never resolves a device onto the poller's own host", %{
    actor: actor
  } do
    poller_agent_id = "armis-legitimate-poller-#{System.unique_integer([:positive])}"

    {:ok, poller_host} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "armis-poller-host"
      })
      |> Ash.create(actor: actor)

    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: poller_host.uid,
        identifier_type: :agent_id,
        identifier_value: poller_agent_id,
        partition: "default",
        confidence: :strong
      })
      |> Ash.create(actor: actor)

    mac = universal_mac()
    armis_id = "armis-poller-host-#{System.unique_integer([:positive])}"
    ip = unique_ip()

    update = %{
      "agent_id" => poller_agent_id,
      "gateway_id" => "armis-gateway",
      "partition" => "default",
      "device_id" => "default:#{ip}",
      "ip" => ip,
      "hostname" => "armis-discovered-endpoint",
      "source" => "armis",
      "mac" => mac,
      "metadata" => %{
        "integration_type" => "armis",
        "armis_device_id" => armis_id,
        "integration_id" => armis_id,
        "source_device_id" => "source-endpoint"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    endpoint_uid = device_for_mac(mac, actor)
    assert is_binary(endpoint_uid)
    assert endpoint_uid != poller_host.uid
    assert device_for_armis_id(armis_id, actor) == endpoint_uid

    assert poller_host.uid ==
             Repo.one(
               from(identifier in DeviceIdentifier,
                 where:
                   identifier.identifier_type == :agent_id and
                     identifier.identifier_value == ^poller_agent_id,
                 select: identifier.device_id
               )
             )
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

  test "a new typed Armis ID does not adopt another device's historical MAC", %{actor: actor} do
    armis_a = "armis-history-a-#{System.unique_integer([:positive])}"
    armis_b = "armis-history-b-#{System.unique_integer([:positive])}"
    current_mac = universal_mac()
    historical_mac = universal_mac()
    refute current_mac == historical_mac

    update_a = %{
      "hostname" => "history-host-a",
      "source" => "armis",
      "mac" => current_mac,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_a}
    }

    assert :ok = SyncIngestor.ingest_updates([update_a], actor: actor)
    canonical = device_for_armis_id(armis_a, actor)
    assert is_binary(canonical)

    {:ok, _} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: canonical,
        identifier_type: :mac,
        identifier_value: historical_mac,
        partition: "default",
        confidence: :strong
      })
      |> Ash.create(actor: actor)

    update_b = %{
      "hostname" => "history-host-b",
      "source" => "armis",
      "mac" => historical_mac,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_b}
    }

    assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

    resolved_b = device_for_armis_id(armis_b, actor)
    assert is_binary(resolved_b)
    assert resolved_b != canonical
  end

  test "direct current-primary MAC match is not vetoed even with DIFFERENT armis_device_ids", %{
    actor: actor
  } do
    # Negative guard (b): a direct `:mac` identifier match to the canonical
    # device's current primary MAC is self-consistent and is not vetoed. Two
    # records carry the SAME current hardware MAC but DIFFERENT armis_device_ids;
    # resolution is driven by the shared `:mac` identifier, so the second record
    # must resolve to the SAME device as the first.
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

    # Second record: same current MAC, a DIFFERENT armis_device_id. The direct
    # `:mac` match resolves it to the same device.
    update_b = %{
      "hostname" => "direct-mac-b",
      "source" => "armis",
      "mac" => mac,
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_b}
    }

    assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

    assert device_for_mac(mac, actor) == canonical,
           "a direct current-primary MAC match must not be vetoed"
  end

  test "mapper SNMP LAN MAC attaches to the existing UniFi WAN sibling", %{actor: actor} do
    {:ok, unifi} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "farm01",
        ip: "152.117.116.178",
        mac: "f4:92:bf:75:c7:21"
      })
      |> Ash.create(actor: actor)

    assert {:ok, _} =
             DeviceIdentifier
             |> Ash.Changeset.for_create(:register, %{
               device_id: unifi.uid,
               identifier_type: :mac,
               identifier_value: "F492BF75C721",
               partition: "default",
               confidence: :strong,
               source: "test"
             })
             |> Ash.create(actor: actor)

    update = %{
      "hostname" => "farm01",
      "ip" => "192.168.1.1",
      "mac" => "f6:92:bf:75:c7:21",
      "source" => "mapper",
      "metadata" => %{
        "identity_mac_kind" => "primary",
        "source" => "snmp"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
    assert device_for_mac("F492BF75C721", actor) == unifi.uid
    assert device_for_mac("F692BF75C721", actor) == unifi.uid

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
    assert device_for_mac("F692BF75C721", actor) == unifi.uid
  end

  test "mapper SNMP LAN ingest heals an existing UniFi/SNMP sibling split", %{actor: actor} do
    {:ok, unifi} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "farm01",
        ip: "152.117.116.178",
        mac: "f4:92:bf:75:c7:21"
      })
      |> Ash.create(actor: actor)

    {:ok, snmp} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "farm01",
        ip: "192.168.1.1",
        mac: "f6:92:bf:75:c7:21"
      })
      |> Ash.create(actor: actor)

    assert {:ok, _} =
             DeviceIdentifier
             |> Ash.Changeset.for_create(:register, %{
               device_id: unifi.uid,
               identifier_type: :mac,
               identifier_value: "F492BF75C721",
               partition: "default",
               confidence: :strong,
               source: "test"
             })
             |> Ash.create(actor: actor)

    assert {:ok, _} =
             DeviceIdentifier
             |> Ash.Changeset.for_create(:register, %{
               device_id: snmp.uid,
               identifier_type: :mac,
               identifier_value: "F692BF75C721",
               partition: "default",
               confidence: :medium,
               source: "test"
             })
             |> Ash.create(actor: actor)

    update = %{
      "hostname" => "farm01",
      "ip" => "192.168.1.1",
      "mac" => "f6:92:bf:75:c7:21",
      "source" => "mapper",
      "metadata" => %{"identity_mac_kind" => "primary", "source" => "snmp"}
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
    assert device_for_mac("F692BF75C721", actor) == unifi.uid

    assert {:ok, %Device{deleted_at: deleted_at}} =
             Device.get_by_uid(snmp.uid, true, actor: actor)

    assert deleted_at
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

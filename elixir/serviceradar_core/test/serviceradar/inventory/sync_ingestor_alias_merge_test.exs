defmodule ServiceRadar.Inventory.SyncIngestorAliasMergeTest do
  @moduledoc """
  Integration coverage for alias-conflict merges during sync ingestion.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.InterfaceMacs
  alias ServiceRadar.Inventory.Identity.Resolver
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Sync.Lookups
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_alias_merge_test)
    {:ok, actor: actor}
  end

  test "sync ingestion merges alias device into canonical device for non-mapper source", %{
    actor: actor
  } do
    ip = unique_test_ip(1)
    mac = "AA:BB:CC:DD:EE:01"
    agent_id = "alias-merge-agent-#{System.unique_integer([:positive])}"

    {:ok, canonical} = create_device(actor, "canonical")
    {:ok, alias_device} = create_device(actor, "alias")

    assert {:ok, _} = register_identifier(actor, canonical.uid, :agent_id, agent_id)

    {:ok, alias_state} = create_alias_state(actor, alias_device.uid, ip)
    assert {:ok, _} = DeviceAliasState.confirm(alias_state, actor: actor)

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "tonka01",
      "source" => "agent",
      "metadata" => %{"agent_id" => agent_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert {:ok, _} = Device.get_by_uid(canonical.uid, false, actor: actor)

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip)
      |> Ash.read(actor: actor)
      |> ServiceRadar.Ash.Page.unwrap()

    assert Enum.count(devices_at_ip) == 1
    remaining_uid = hd(devices_at_ip).uid
    refute remaining_uid == alias_device.uid

    assert {:ok, [audit | _]} = MergeAudit.get_merged_to(alias_device.uid, actor: actor)
    refute audit.to_device_id == alias_device.uid
  end

  # Alias rows are per device, so the survivor of an alias merge can hold its own row of the
  # address. Moving the merged record's row onto it would break the unique key and roll the
  # merge back; the row is folded into the survivor's instead, carrying its confirmation.
  test "an alias merge succeeds when the survivor holds its own row of the address", %{
    actor: actor
  } do
    ip = unique_test_ip(3)
    agent_id = "alias-fold-agent-#{System.unique_integer([:positive])}"

    {:ok, canonical} = create_device(actor, "fold-canonical")
    {:ok, alias_device} = create_device(actor, "fold-alias")

    assert {:ok, _} = register_identifier(actor, canonical.uid, :agent_id, agent_id)

    {:ok, merged_row} = create_alias_state(actor, alias_device.uid, ip)
    assert {:ok, _} = DeviceAliasState.confirm(merged_row, actor: actor)
    {:ok, survivor_row} = create_alias_state(actor, canonical.uid, ip)

    update = %{
      "ip" => ip,
      "hostname" => "fold-canonical",
      "source" => "agent",
      "metadata" => %{"agent_id" => agent_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    canonical_uid = canonical.uid
    survivor_row_id = survivor_row.id

    assert {:ok, [%{to_device_id: ^canonical_uid}]} =
             MergeAudit.get_merged_to(alias_device.uid, actor: actor)

    assert {:ok, %DeviceAliasState{device_id: ^canonical_uid, state: :confirmed}} =
             Ash.get(DeviceAliasState, survivor_row.id)

    assert {:ok, %DeviceAliasState{state: :replaced, replaced_by_alias_id: ^survivor_row_id}} =
             Ash.get(DeviceAliasState, merged_row.id)
  end

  describe "an address that moved to another device (DHCP churn, #4609)" do
    # The alias holder owns an identifier of its own, so the shared address is the only thing
    # linking it to the updated device. DHCP hands addresses to other devices, so that link is
    # never evidence of sameness: the alias is invalidated and the two records stay separate.
    # Model: formal/dire DireResolution, switch sync_alias_merge_unguarded.
    test "an agent update does not merge an alias holder that owns a MAC", %{actor: actor} do
      ip = unique_test_ip(11)
      agent_id = "alias-dhcp-agent-#{System.unique_integer([:positive])}"

      {:ok, canonical} = create_device(actor, "leased-now")
      {:ok, previous_holder} = create_device(actor, "leased-before")

      assert {:ok, _} = register_identifier(actor, canonical.uid, :agent_id, agent_id)
      assert {:ok, _} = register_identifier(actor, previous_holder.uid, :mac, "00005E005311")

      {:ok, alias_state} = create_alias_state(actor, previous_holder.uid, ip)
      assert {:ok, _} = DeviceAliasState.confirm(alias_state, actor: actor)

      update = %{
        "ip" => ip,
        "hostname" => "leased-now",
        "source" => "agent",
        "metadata" => %{"agent_id" => agent_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      assert {:ok, %Device{deleted_at: nil}} =
               Device.get_by_uid(previous_holder.uid, false, actor: actor)

      assert {:ok, []} = MergeAudit.get_merged_to(previous_holder.uid, actor: actor)
      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, alias_state.id)
    end

    test "an Armis update does not merge an alias holder that owns a MAC", %{actor: actor} do
      ip = unique_test_ip(12)
      armis_id = "#{System.unique_integer([:positive])}"

      {:ok, previous_holder} = create_device(actor, "discovered-before")
      assert {:ok, _} = register_identifier(actor, previous_holder.uid, :mac, "00005E005312")

      {:ok, alias_state} = create_alias_state(actor, previous_holder.uid, ip)
      assert {:ok, _} = DeviceAliasState.confirm(alias_state, actor: actor)

      update = %{
        "ip" => ip,
        "hostname" => "armis-leased-now",
        "source" => "armis",
        # Armis identity travels in the update's metadata (Inventory.Identity.Ids).
        "metadata" => %{
          "integration_type" => "armis",
          "integration_id" => "armis:source-test:device:#{armis_id}",
          "armis_device_id" => armis_id
        }
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      assert {:ok, %Device{deleted_at: nil}} =
               Device.get_by_uid(previous_holder.uid, false, actor: actor)

      assert {:ok, []} = MergeAudit.get_merged_to(previous_holder.uid, actor: actor)
      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, alias_state.id)
    end

    # A sync naming its integration source files its identifiers under the source's own partition
    # (Ids.identifier_partition/2). The alias pass looks the address up under the partition
    # AliasEvents records aliases under, or it finds no holder and the alias stays confirmed.
    test "an Armis update naming its sync source invalidates a MAC-owning holder's alias", %{
      actor: actor
    } do
      ip = unique_test_ip(13)
      armis_id = "#{System.unique_integer([:positive])}"
      source_id = Ecto.UUID.generate()
      integration_id = "armis:#{source_id}:device:#{armis_id}"

      {:ok, previous_holder} = create_device(actor, "discovered-before-sourced")
      assert {:ok, _} = register_identifier(actor, previous_holder.uid, :mac, "00005E005313")

      {:ok, alias_state} = create_alias_state(actor, previous_holder.uid, ip)
      assert {:ok, _} = DeviceAliasState.confirm(alias_state, actor: actor)

      update = %{
        "ip" => ip,
        "hostname" => "armis-sourced-leased-now",
        "source" => "armis",
        "metadata" => %{
          "integration_type" => "armis",
          "integration_id" => integration_id,
          "armis_device_id" => armis_id
        },
        "sync_meta" => %{"sync_service_id" => source_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      # The precondition: the sync's identity sits under the source's partition, not the alias's.
      assert {:ok, [%DeviceIdentifier{partition: identifier_partition} | _]} =
               DeviceIdentifier
               |> Ash.Query.filter(identifier_value == ^integration_id)
               |> Ash.read(actor: actor)

      assert identifier_partition == "default:armis:#{source_id}"

      assert {:ok, %Device{deleted_at: nil}} =
               Device.get_by_uid(previous_holder.uid, false, actor: actor)

      assert {:ok, []} = MergeAudit.get_merged_to(previous_holder.uid, actor: actor)
      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, alias_state.id)
    end

    # Alias rows are per device, so an address two devices held in turn carries a confirmed row
    # of each, and every identified holder is handled, not only the first one read.
    test "an Armis update invalidates the alias of every MAC-owning holder", %{actor: actor} do
      ip = unique_test_ip(14)
      armis_id = "#{System.unique_integer([:positive])}"

      {:ok, first_holder} = create_device(actor, "leased-first")
      {:ok, second_holder} = create_device(actor, "leased-second")
      assert {:ok, _} = register_identifier(actor, first_holder.uid, :mac, "00005E005314")
      assert {:ok, _} = register_identifier(actor, second_holder.uid, :mac, "00005E005315")

      {:ok, first_row} = create_alias_state(actor, first_holder.uid, ip)
      assert {:ok, _} = DeviceAliasState.confirm(first_row, actor: actor)
      {:ok, second_row} = create_alias_state(actor, second_holder.uid, ip)
      assert {:ok, _} = DeviceAliasState.confirm(second_row, actor: actor)

      update = %{
        "ip" => ip,
        "hostname" => "armis-leased-third",
        "source" => "armis",
        "metadata" => %{
          "integration_type" => "armis",
          "integration_id" => "armis:source-test:device:#{armis_id}",
          "armis_device_id" => armis_id
        }
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      for holder <- [first_holder, second_holder] do
        assert {:ok, %Device{deleted_at: nil}} =
                 Device.get_by_uid(holder.uid, false, actor: actor)

        assert {:ok, []} = MergeAudit.get_merged_to(holder.uid, actor: actor)
      end

      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, first_row.id)
      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, second_row.id)
    end
  end

  describe "alias rows are per device" do
    # The device a sighting resolves to can hold its own row of the address, and be its newest
    # holder. AliasGuard skips that row and handles every other identified holder.
    test "AliasGuard skips the device's own row and invalidates every other holder", %{
      actor: actor
    } do
      ip = unique_test_ip(15)

      {:ok, device} = create_device(actor, "holder-now")
      {:ok, older} = create_device(actor, "holder-before")
      {:ok, oldest} = create_device(actor, "holder-long-before")
      assert {:ok, _} = register_identifier(actor, older.uid, :mac, "00005E005316")
      assert {:ok, _} = register_identifier(actor, oldest.uid, :mac, "00005E005317")

      own_row = confirmed_alias_row(actor, device.uid, ip, 0, 4)
      older_row = confirmed_alias_row(actor, older.uid, ip, 60, 3)
      oldest_row = confirmed_alias_row(actor, oldest.uid, ip, 120, 3)

      assert :ok =
               AliasGuard.maybe_merge_ip_alias_device(
                 device.uid,
                 %{ip: ip, partition: "default"},
                 actor
               )

      assert {:ok, %DeviceAliasState{state: :confirmed}} = Ash.get(DeviceAliasState, own_row.id)
      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, older_row.id)
      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, oldest_row.id)
    end

    # Every by-value reader of an address's holders orders them by DeviceAliasState.holder_sort/0.
    test "readers return an address's holders most recently seen first", %{actor: actor} do
      ip = unique_test_ip(16)

      {:ok, d1} = create_device(actor, "reader-oldest")
      {:ok, d2} = create_device(actor, "reader-newest")
      {:ok, d3} = create_device(actor, "reader-middle")

      # The newest holder is neither the first nor the last row written, nor the most or the
      # least sighted, so an unordered read cannot pick it by chance.
      confirmed_alias_row(actor, d1.uid, ip, 120, 5)
      confirmed_alias_row(actor, d2.uid, ip, 0, 3)
      confirmed_alias_row(actor, d3.uid, ip, 60, 1)

      assert {:ok, [d2.uid, d3.uid, d1.uid]} ==
               Resolver.lookup_alias_device_ids(ip, "default", actor)

      assert {:ok, [d3.uid, d1.uid]} ==
               Resolver.lookup_alias_device_ids(ip, "default", actor, except: d2.uid)

      assert {:ok, d2.uid} == IdentityReconciler.lookup_alias_device_id(ip, "default", actor)
      assert %{ip => d2.uid} == Lookups.lookup_alias_device_ids_by_ip([ip])
      assert sweep_holder(ip, actor) == d2.uid

      # The mapper ranks by state first; within a state, recency comes before sightings.
      assert {:ok, d2.uid} == MapperResultsIngestor.find_device_uid_by_alias(ip, "default", actor)
    end

    test "readers break a tie in recency by sightings, then by device id", %{actor: actor} do
      ip = unique_test_ip(17)

      {:ok, a} = create_device(actor, "tie-a")
      {:ok, b} = create_device(actor, "tie-b")
      [lo, hi] = Enum.sort([a.uid, b.uid])

      confirmed_alias_row(actor, hi, ip, 30, 4)
      confirmed_alias_row(actor, lo, ip, 30, 2)

      assert {:ok, [hi, lo]} == Resolver.lookup_alias_device_ids(ip, "default", actor)
      assert %{ip => hi} == Lookups.lookup_alias_device_ids_by_ip([ip])
      assert sweep_holder(ip, actor) == hi
      assert {:ok, hi} == MapperResultsIngestor.find_device_uid_by_alias(ip, "default", actor)

      set_alias_row_seen(hi, ip, 30, 2)

      assert {:ok, [lo, hi]} == Resolver.lookup_alias_device_ids(ip, "default", actor)
      assert %{ip => lo} == Lookups.lookup_alias_device_ids_by_ip([ip])
      assert sweep_holder(ip, actor) == lo
      assert {:ok, lo} == MapperResultsIngestor.find_device_uid_by_alias(ip, "default", actor)
    end

    test "the pending-alias fallback leaves out the excepted device as well", %{actor: actor} do
      ip = unique_test_ip(18)

      {:ok, device} = create_device(actor, "fallback-own")
      {:ok, _row} = create_alias_state(actor, device.uid, ip)

      assert {:ok, device.uid} ==
               Resolver.lookup_alias_device_id(ip, "default", actor, include_detected: true)

      assert {:ok, nil} ==
               Resolver.lookup_alias_device_id(ip, "default", actor,
                 include_detected: true,
                 except: device.uid
               )
    end
  end

  test "mapper source does not merge alias device by mac-only identifier", %{actor: actor} do
    ip = unique_test_ip(2)
    mac = unique_mac(2)
    normalized_mac = IdentityReconciler.normalize_mac(mac)

    {:ok, canonical} = create_device(actor, "canonical-mapper")
    {:ok, alias_device} = create_device(actor, "alias-mapper")

    assert {:ok, _} = register_identifier(actor, canonical.uid, :mac, normalized_mac)

    {:ok, alias_state} = create_alias_state(actor, alias_device.uid, ip)
    assert {:ok, _} = DeviceAliasState.confirm(alias_state, actor: actor)

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "mapper-tonka",
      "source" => "mapper"
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert {:ok, _} = Device.get_by_uid(alias_device.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(canonical.uid, false, actor: actor)
    assert {:ok, []} = MergeAudit.get_merged_to(alias_device.uid, actor: actor)
  end

  describe "chassis corroboration narrows the distinct-MAC veto" do
    test "two devices with disjoint MACs still conflict when neither claims the other", %{
      actor: actor
    } do
      {:ok, a} = create_device(actor, "chassis-a")
      {:ok, b} = create_device(actor, "chassis-b")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "F492BF75C721")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "F492BF75C72B")

      # The default and correct answer: two universally-administered MACs that
      # differ are two pieces of hardware. Nothing about this change may weaken
      # it -- a recycled IP rebinding to a different host depends on it.
      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end

    test "the veto lifts when one device's own interface table claims the other's MAC", %{
      actor: actor
    } do
      {:ok, a} = create_device(actor, "chassis-wan")
      {:ok, b} = create_device(actor, "chassis-lan")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "F492BF75C721")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "F492BF75C72B")
      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)

      # The chassis itself, over authenticated SNMP, reports ...C72B as one of
      # its own interfaces. That is direct evidence these are two addresses of
      # one device rather than two devices.
      assert InterfaceMacs.register(a.uid, ["f4:92:bf:75:c7:2b"], nil, actor) == 1

      refute AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor),
             "an own-interface claim on the other device's MAC should lift the veto"
    end

    test "the claim works in either direction", %{actor: actor} do
      {:ok, a} = create_device(actor, "chassis-x")
      {:ok, b} = create_device(actor, "chassis-y")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "F492BF75C731")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "F492BF75C73B")

      assert InterfaceMacs.register(b.uid, ["f4:92:bf:75:c7:31"], nil, actor) == 1

      refute AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end

    test "an unrelated interface MAC does not lift the veto", %{actor: actor} do
      {:ok, a} = create_device(actor, "chassis-p")
      {:ok, b} = create_device(actor, "chassis-q")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "F492BF75C741")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "F492BF75C74B")

      # A device claiming its own other interfaces must NOT make it look like
      # every other device. Only a claim on the OTHER device's MAC counts.
      assert InterfaceMacs.register(a.uid, ["f4:92:bf:75:c7:99"], nil, actor) == 1

      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end
  end

  describe "interface MAC registration" do
    test "two rows of ONE chassis can both claim the same MAC", %{actor: actor} do
      # The defect this table exists to fix. Two device rows that are the same
      # chassis report the SAME interface MACs. Under a globally-unique identifier
      # the first to register owned every one and the twin owned none -- observed
      # on farm01 as 11 MACs on one row and 0 on the twin that reported 16. The
      # loser then re-attempted every MAC on every poll forever, each attempt
      # silently updating the other device's row and counting as a success.
      {:ok, a} = create_device(actor, "chassis-wan-side")
      {:ok, b} = create_device(actor, "chassis-lan-side")

      shared = "f4:92:bf:75:c7:81"

      assert InterfaceMacs.register(a.uid, [shared], nil, actor) == 1
      assert InterfaceMacs.register(b.uid, [shared], nil, actor) == 1

      assert MapSet.member?(InterfaceMacs.registered_values(a.uid, actor), "F492BF75C781")

      assert MapSet.member?(InterfaceMacs.registered_values(b.uid, actor), "F492BF75C781"),
             "the second device could not claim a MAC the first already claimed"
    end

    test "the change gate still holds for the second claimant", %{actor: actor} do
      # The scale consequence of the old defect: the loser's own set always read
      # back empty, so it never converged and wrote on every poll. At 1M devices
      # duplicates are the common case, which is exactly where steady-state zero
      # was claimed.
      {:ok, a} = create_device(actor, "chassis-first")
      {:ok, b} = create_device(actor, "chassis-second")

      shared = "f4:92:bf:75:c7:82"

      assert InterfaceMacs.register(a.uid, [shared], nil, actor) == 1
      assert InterfaceMacs.register(b.uid, [shared], nil, actor) == 1

      assert InterfaceMacs.register(b.uid, [shared], nil, actor) == 0,
             "the second claimant re-wrote a MAC it already holds; its change gate never engages"
    end

    test "refuses locally-administered addresses", %{actor: actor} do
      {:ok, device} = create_device(actor, "virtualized-host")

      # tap/veth/dummy/bridge addresses are overwhelmingly locally administered,
      # and a synthesised address is not evidence of hardware. On the deployment
      # that motivated this, the filter removed 14 of 67 interface MACs.
      assert InterfaceMacs.eligible(["02:6e:4e:5c:13:14", "f6:92:bf:75:c7:21"]) == []

      assert InterfaceMacs.register(device.uid, ["02:6e:4e:5c:13:14"], nil, actor) == 0
      assert MapSet.size(InterfaceMacs.registered_values(device.uid, actor)) == 0
    end

    test "writes nothing when a poll discovers nothing new", %{actor: actor} do
      {:ok, device} = create_device(actor, "polled-switch")
      macs = ["f4:92:bf:75:c7:51", "f4:92:bf:75:c7:52"]

      assert InterfaceMacs.register(device.uid, macs, nil, actor) == 2

      # The change gate. Without it, 1M devices polled 15x/day would upsert
      # hundreds of millions of rows/day for values that change only when
      # hardware does.
      assert InterfaceMacs.register(device.uid, macs, nil, actor) == 0
      assert InterfaceMacs.register(device.uid, macs ++ ["f4:92:bf:75:c7:53"], nil, actor) == 1
    end

    test "normalizes separators and case", %{actor: actor} do
      {:ok, device} = create_device(actor, "mixed-format")

      assert InterfaceMacs.register(device.uid, ["f4-92-bf-75-c7-61"], nil, actor) == 1
      assert InterfaceMacs.register(device.uid, ["F4:92:BF:75:C7:61"], nil, actor) == 0

      assert MapSet.member?(InterfaceMacs.registered_values(device.uid, actor), "F492BF75C761")
    end

    test "ignores malformed addresses rather than raising", %{actor: actor} do
      {:ok, device} = create_device(actor, "bad-data")

      assert InterfaceMacs.eligible(["", "not-a-mac", nil, "f4:92:bf"]) == []
      assert InterfaceMacs.register(device.uid, ["", "zz", nil], nil, actor) == 0
    end
  end

  defp create_device(actor, hostname) do
    uniq = System.unique_integer([:positive, :monotonic])

    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: unique_device_ip(uniq)
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp register_identifier(actor, device_id, type, value) do
    attrs = %{
      device_id: device_id,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      source: "test"
    }

    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, attrs)
    |> Ash.create(actor: actor)
  end

  defp create_alias_state(actor, device_id, ip) do
    attrs = %{
      device_id: device_id,
      partition: "default",
      alias_type: :ip,
      alias_value: ip,
      metadata: %{"source" => "test"}
    }

    DeviceAliasState.create_detected(attrs, actor: actor)
  end

  defp confirmed_alias_row(actor, device_id, ip, age_seconds, sighting_count) do
    {:ok, row} = create_alias_state(actor, device_id, ip)
    {:ok, row} = DeviceAliasState.confirm(row, actor: actor)
    set_alias_row_seen(device_id, ip, age_seconds, sighting_count)
    row
  end

  # Orders an address's holders without sleeping: sets when one device's row of it was last seen,
  # `age_seconds` before the test's transaction began, and how often it was sighted.
  defp set_alias_row_seen(device_id, ip, age_seconds, sighting_count) do
    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE platform.device_alias_states
        SET last_seen_at = (now() AT TIME ZONE 'utc') - make_interval(secs => $1),
            sighting_count = $2
        WHERE device_id = $3 AND alias_type = 'ip' AND alias_value = $4
        """,
        [age_seconds * 1.0, sighting_count, device_id, ip]
      )
  end

  # The device the sweep's batch lookup resolves an address to.
  defp sweep_holder(ip, actor) do
    assert %{^ip => %{canonical_device_id: uid}} =
             DeviceLookup.batch_lookup_by_ip([ip], actor: actor)

    uid
  end

  defp unique_test_ip(seed) do
    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "100.122.#{third}.#{fourth}"
  end

  defp unique_device_ip(seed) do
    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "100.123.#{third}.#{fourth}"
  end

  defp unique_mac(seed) do
    suffix = rem(System.unique_integer([:positive, :monotonic]) + seed, 255)

    "AA:BB:CC:DD:EE:#{suffix |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()}"
  end
end

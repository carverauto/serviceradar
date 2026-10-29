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
      "hostname" => "synthetic-node",
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

  describe "Lookups.lookup_identifiers_strict/1" do
    test "resolves all identifier types across partitions via a constant-parameter unnest join",
         %{
           actor: actor
         } do
      suffix = System.unique_integer([:positive, :monotonic])

      specs = [
        {:agent_id, "agent-lookup-#{suffix}", "default"},
        {:armis_device_id, "armis-lookup-#{suffix}", "default:armis:src-1"},
        {:integration_id, "integration-lookup-#{suffix}", "default"},
        {:netbox_device_id, "netbox-lookup-#{suffix}", "site-west"},
        {:hardware_serial, "SN-LOOKUP-#{suffix}", "default"},
        {:mac,
         "00005E#{suffix |> rem(999_999) |> Integer.to_string() |> String.pad_leading(6, "0")}",
         "default"},
        {:ip, "192.0.2.#{rem(suffix, 250) + 1}", "site-west"},
        {:passive_fingerprint, "fp-lookup-#{suffix}", "default"}
      ]

      expected =
        Map.new(specs, fn {type, value, partition} ->
          {:ok, device} = create_device(actor, "id-holder-#{type}-#{suffix}")

          {:ok, _identifier} =
            DeviceIdentifier
            |> Ash.Changeset.for_create(:register, %{
              device_id: device.uid,
              identifier_type: type,
              identifier_value: value,
              partition: partition,
              source: "test"
            })
            |> Ash.create(actor: actor)

          {{type, value, partition}, device.uid}
        end)

      wrong_partition_keys =
        Enum.map(specs, fn {type, value, _partition} -> {type, value, "wrong-partition"} end)

      assert {:ok, mappings} = Lookups.lookup_identifiers_strict(wrong_partition_keys)
      assert mappings == %{}

      unmatched = [
        {:mac, "00005EFFFFFF", "default"},
        {:integration_id, "missing-#{suffix}", "default"}
      ]

      string_keys =
        Enum.map(specs, fn {type, value, partition} ->
          {to_string(type), value, partition}
        end)

      query_keys = specs ++ unmatched ++ Enum.take(specs, 3) ++ string_keys

      parent = self()
      handler_id = "lookups-unnest-query-#{suffix}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:service_radar, :repo, :query],
          fn _event, _measurements, %{query: sql, params: params}, _config ->
            if self() == parent and String.contains?(sql, "device_identifiers") do
              send(parent, {:identifier_lookup_query, sql, params})
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, ^expected} = Lookups.lookup_identifiers_strict(query_keys)
      :ok = :telemetry.detach(handler_id)

      assert_receive {:identifier_lookup_query, sql, [types, values, partitions]}
      refute_receive {:identifier_lookup_query, _, _}
      assert sql =~ "unnest"
      refute sql =~ " OR "
      assert length(types) == length(specs) + length(unmatched)
      assert length(values) == length(types)
      assert length(partitions) == length(types)

      assert ^expected = Lookups.bulk_lookup_identifiers(query_keys)
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
      "hostname" => "synthetic-edge.example.test",
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

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "001122334455")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "00AABBCCDDEE")

      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end

    test "a one-sided interface claim does not lift the veto", %{actor: actor} do
      {:ok, a} = create_device(actor, "chassis-wan")
      {:ok, b} = create_device(actor, "chassis-lan")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "001122334455")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "00AABBCCDDEE")
      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)

      assert InterfaceMacs.register(a.uid, ["00:aa:bb:cc:dd:ee"], nil, actor) == 1

      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end

    test "cross-partition reciprocal claims do not lift the veto", %{actor: actor} do
      {:ok, a} = create_device(actor, "partition-a")
      {:ok, b} = create_device(actor, "partition-b")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "001122334455")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "00AABBCCDDEE")

      assert InterfaceMacs.register(a.uid, ["00:aa:bb:cc:dd:ee"], "other", actor) == 1
      assert InterfaceMacs.register(b.uid, ["00:11:22:33:44:55"], "default", actor) == 1

      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end

    test "reciprocal interface claims lift the veto", %{actor: actor} do
      {:ok, a} = create_device(actor, "chassis-x")
      {:ok, b} = create_device(actor, "chassis-y")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "001122334455")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "00AABBCCDDEE")

      assert InterfaceMacs.register(a.uid, ["00:aa:bb:cc:dd:ee"], nil, actor) == 1
      assert InterfaceMacs.register(b.uid, ["00:11:22:33:44:55"], nil, actor) == 1

      refute AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end

    test "an unrelated interface MAC does not lift the veto", %{actor: actor} do
      {:ok, a} = create_device(actor, "chassis-p")
      {:ok, b} = create_device(actor, "chassis-q")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "001122334455")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "00AABBCCDDEE")

      assert InterfaceMacs.register(a.uid, ["00:dd:ee:ff:00:11"], nil, actor) == 1

      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end
  end

  describe "an address replaced by a sync" do
    # A hypervisor API reports a node at its cluster address while discovery reached the node
    # on its management address. The configured address becomes the primary, and the address
    # discovery established must stay attributable to the node: once neither the primary nor an
    # alias holds it, a sweep reaching it resolves to nothing and cannot seed it again either
    # (the address-named seed uid is the node's own).
    test "a declarative source keeps the address it replaced as an alias", %{actor: actor} do
      seed = System.unique_integer([:positive, :monotonic])
      held_ip = test_net_ip("192.0.2", seed)
      declared_ip = test_net_ip("198.51.100", seed)
      integration_id = "proxmox:v3:#{Ecto.UUID.generate()}:#{Ecto.UUID.generate()}:node:node01"

      {:ok, node} = create_device_at(actor, "node01", held_ip)
      assert {:ok, _} = register_identifier(actor, node.uid, :integration_id, integration_id)

      update = %{
        "device_id" => node.uid,
        "ip" => declared_ip,
        "partition" => "default",
        "source" => "hypervisor_enrichment",
        "metadata" => %{"integration_id" => integration_id, "integration_type" => "hypervisor"}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      assert {:ok, %Device{ip: ^declared_ip}} = Device.get_by_uid(node.uid, false, actor: actor)

      assert {:ok, [%DeviceAliasState{state: :detected}]} =
               DeviceAliasState.lookup_for_device(node.uid, :ip, held_ip, actor: actor)

      node_uid = node.uid

      assert %{^held_ip => {%{canonical_device_id: ^node_uid}, _alias}} =
               DeviceLookup.lookup_detected_aliases_by_ip([held_ip],
                 actor: actor,
                 partition: "default"
               )
    end

    # The record a batch writes for a device is its last update for that device, so that
    # update's source decides. A sighting of the node at its held address earlier in the batch
    # does not make the configured address that wins a move.
    test "a declarative update that wins its batch keeps the address after an observed sighting",
         %{actor: actor} do
      seed = System.unique_integer([:positive, :monotonic])
      held_ip = test_net_ip("192.0.2", seed)
      declared_ip = test_net_ip("198.51.100", seed)
      armis_id = "#{seed}"
      integration_id = "proxmox:v3:#{Ecto.UUID.generate()}:#{Ecto.UUID.generate()}:node:node02"

      {:ok, node} = create_device_at(actor, "node02", held_ip)
      assert {:ok, _} = register_identifier(actor, node.uid, :armis_device_id, armis_id)
      assert {:ok, _} = register_identifier(actor, node.uid, :integration_id, integration_id)

      sighting = %{
        "ip" => held_ip,
        "source" => "armis",
        "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
      }

      declaration = %{
        "device_id" => node.uid,
        "ip" => declared_ip,
        "partition" => "default",
        "source" => "hypervisor_enrichment",
        "metadata" => %{"integration_id" => integration_id, "integration_type" => "hypervisor"}
      }

      assert :ok = SyncIngestor.ingest_updates([sighting, declaration], actor: actor)

      assert {:ok, %Device{ip: ^declared_ip}} = Device.get_by_uid(node.uid, false, actor: actor)

      assert {:ok, [%DeviceAliasState{state: :detected}]} =
               DeviceAliasState.lookup_for_device(node.uid, :ip, held_ip, actor: actor)
    end

    # An observed source saw the device at the new address, so the old one is the stale side of
    # a move. Keeping it would attribute the address's next holder to this device.
    test "an observed source does not keep the address it moved the device off", %{
      actor: actor
    } do
      seed = System.unique_integer([:positive, :monotonic])
      old_ip = test_net_ip("192.0.2", seed)
      new_ip = test_net_ip("198.51.100", seed)
      armis_id = "#{seed}"

      {:ok, device} = create_device_at(actor, "moved-host", old_ip)
      assert {:ok, _} = register_identifier(actor, device.uid, :armis_device_id, armis_id)

      update = %{
        "ip" => new_ip,
        "source" => "armis",
        "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      assert {:ok, %Device{ip: ^new_ip}} = Device.get_by_uid(device.uid, false, actor: actor)

      assert {:ok, []} =
               DeviceAliasState.lookup_for_device(device.uid, :ip, old_ip, actor: actor)
    end
  end

  describe "interface MAC registration" do
    test "two records for one chassis can both claim the same MAC", %{actor: actor} do
      {:ok, a} = create_device(actor, "chassis-wan-side")
      {:ok, b} = create_device(actor, "chassis-lan-side")
      shared = "00:11:22:33:44:66"

      assert InterfaceMacs.register(a.uid, [shared], nil, actor) == 1
      assert InterfaceMacs.register(b.uid, [shared], nil, actor) == 1

      assert MapSet.member?(InterfaceMacs.registered_values(a.uid, actor), "001122334466")
      assert MapSet.member?(InterfaceMacs.registered_values(b.uid, actor), "001122334466")
    end

    test "re-registering an existing claim does not count as a new row", %{actor: actor} do
      {:ok, device} = create_device(actor, "repeat-claim")
      mac = "00:11:22:33:44:77"

      assert InterfaceMacs.register(device.uid, [mac], nil, actor) == 1
      assert InterfaceMacs.register(device.uid, [mac], nil, actor) == 0
    end

    test "re-registering an existing claim moves it to the authoritative partition", %{
      actor: actor
    } do
      {:ok, device} = create_device(actor, "partition-migration")
      mac = "00:11:22:33:44:88"

      assert InterfaceMacs.register(device.uid, [mac], "edge", actor) == 1

      assert InterfaceMacs.registered_values(device.uid, "edge", actor) ==
               MapSet.new(["001122334488"])

      assert InterfaceMacs.registered_values(device.uid, "default", actor) == MapSet.new()

      assert InterfaceMacs.register(device.uid, [mac], "default", actor) == 1
      assert InterfaceMacs.registered_values(device.uid, "edge", actor) == MapSet.new()

      assert InterfaceMacs.registered_values(device.uid, "default", actor) ==
               MapSet.new(["001122334488"])
    end

    test "refuses locally-administered addresses", %{actor: actor} do
      {:ok, device} = create_device(actor, "local-address")

      assert InterfaceMacs.register(device.uid, ["02:11:22:33:44:55"], nil, actor) == 0
      assert InterfaceMacs.registered_values(device.uid, actor) == MapSet.new()
    end

    test "writes nothing when a poll discovers nothing new", %{actor: actor} do
      {:ok, device} = create_device(actor, "empty-poll")

      assert InterfaceMacs.register(device.uid, [], nil, actor) == 0
      assert InterfaceMacs.registered_values(device.uid, actor) == MapSet.new()
    end

    test "normalizes separators and case", %{actor: actor} do
      {:ok, device} = create_device(actor, "normalized-address")

      assert InterfaceMacs.register(device.uid, ["00-aa-bb-cc-dd-11"], nil, actor) == 1
      assert InterfaceMacs.registered_values(device.uid, actor) == MapSet.new(["00AABBCCDD11"])
    end

    test "ignores malformed addresses rather than raising", %{actor: actor} do
      {:ok, device} = create_device(actor, "malformed-address")

      assert InterfaceMacs.register(device.uid, ["not-a-mac", "0011"], nil, actor) == 0
      assert InterfaceMacs.registered_values(device.uid, actor) == MapSet.new()
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

  defp create_device_at(actor, hostname, ip) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: ip,
      discovery_sources: ["sweep"]
    })
    |> Ash.create(actor: actor)
  end

  defp test_net_ip(prefix, seed), do: "#{prefix}.#{rem(seed, 254) + 1}"

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

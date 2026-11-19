defmodule ServiceRadar.Identity.DeviceLookupAliasTest do
  @moduledoc """
  Integration coverage for DeviceLookup IP resolution: confirmed aliases, cache
  behaviour, and which record wins when several share one address.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:device_lookup_alias_test)

    IdentityCache.clear()

    on_exit(fn -> IdentityCache.clear() end)

    {:ok, actor: actor}
  end

  test "batch lookup resolves confirmed IP aliases", %{actor: actor} do
    uid = "sr:" <> Ecto.UUID.generate()
    canonical_ip = unique_ip("canonical-alias")
    alias_ip = unique_ip("confirmed-alias")

    assert {:ok, _device} =
             Device
             |> Ash.Changeset.for_create(:create, %{
               uid: uid,
               ip: canonical_ip,
               hostname: "tonka01"
             })
             |> Ash.create(actor: actor)

    assert {:ok, alias_state} =
             DeviceAliasState.create_detected(
               %{
                 device_id: uid,
                 partition: "default",
                 alias_type: :ip,
                 alias_value: alias_ip,
                 metadata: %{}
               },
               actor: actor
             )

    assert {:ok, _confirmed} =
             DeviceAliasState.record_sighting(
               alias_state,
               %{confirm_threshold: 1},
               actor: actor
             )

    result = DeviceLookup.batch_lookup_by_ip([alias_ip], actor: actor)

    assert result[alias_ip].canonical_device_id == uid
  end

  # Regression: a soft-deleted device could win canonical selection over the live
  # record sharing its IP. The sweep path passes `include_deleted: true` on
  # purpose, and that used to be the only thing gating the `deleted_at` check --
  # so with it set, the winner was whichever uid sorted first. Every subsequent
  # write then landed on the tombstone while the survivor was never refreshed.
  #
  # The tombstone is deliberately given the LOWER uid so it sorts first. Without
  # the liveness preference this assertion fails; with it, uid order is irrelevant.
  test "batch lookup prefers the live device over a tombstone sharing its IP", %{actor: actor} do
    ip = unique_ip("tombstone-preference")

    [low, high] = Enum.sort([Ash.UUID.generate(), Ash.UUID.generate()])
    tombstone_uid = "sr:" <> low
    survivor_uid = "sr:" <> high
    assert tombstone_uid < survivor_uid

    assert {:ok, tombstone} =
             Device
             |> Ash.Changeset.for_create(:create, %{
               uid: tombstone_uid,
               ip: ip,
               hostname: "merged-away-01"
             })
             |> Ash.create(actor: actor)

    # Tombstone first: the live uniqueness index permits a second row at this IP
    # only once the first is soft-deleted, which is exactly the post-merge shape.
    assert {:ok, _deleted} =
             tombstone
             |> Ash.Changeset.for_update(:soft_delete, %{
               deleted_reason: "merged",
               deleted_by: "identity_reconciler"
             })
             |> Ash.update(actor: actor)

    assert {:ok, _survivor} =
             Device
             |> Ash.Changeset.for_create(:create, %{
               uid: survivor_uid,
               ip: ip,
               hostname: "survivor-01"
             })
             |> Ash.create(actor: actor)

    result =
      DeviceLookup.batch_lookup_by_ip([ip],
        actor: actor,
        include_deleted: true,
        use_cache: false
      )

    assert result[ip].canonical_device_id == survivor_uid
  end

  # Which holder an address resolves to (DeviceLookup.batch_resolve_by_ip/2). Each test runs
  # in its own partition, so rows elsewhere in the shared database cannot hold its addresses.
  describe "holder selection" do
    setup do
      {:ok, partition: "lookup-#{System.unique_integer([:positive])}"}
    end

    test "a live device whose primary IP is the address beats a deleted alias holder", %{
      actor: actor,
      partition: partition
    } do
      ip = "192.0.2.10"
      live = device!(actor, partition, ip)
      deleted = device!(actor, partition, "198.51.100.10", deleted: true)
      hold_alias!(deleted, ip, :confirmed)

      assert %{^ip => %{canonical_device_id: uid}} = lookup(actor, partition, [ip])
      assert uid == live.uid
    end

    test "a live alias holder beats a deleted device whose primary IP is the address", %{
      actor: actor,
      partition: partition
    } do
      ip = "192.0.2.20"
      _deleted = device!(actor, partition, ip, deleted: true)
      holder = device!(actor, partition, "198.51.100.20")
      hold_alias!(holder, ip, :detected)

      assert %{^ip => %{canonical_device_id: uid}} = lookup(actor, partition, [ip])
      assert uid == holder.uid
    end

    test "a live alias holder seen within the recency window beats one seen before it", %{
      actor: actor,
      partition: partition
    } do
      stale = device!(actor, partition, "198.51.100.40")
      fresh = device!(actor, partition, "198.51.100.41")

      # A confirmed alias outside the window against a detected one inside it.
      hold_alias!(stale, "192.0.2.40", :confirmed, days_ago: 60)
      hold_alias!(fresh, "192.0.2.40", :detected)

      # Two detected aliases: sightings do not outrank recency.
      hold_alias!(stale, "192.0.2.41", :detected, days_ago: 60, sightings: 5)
      hold_alias!(fresh, "192.0.2.41", :detected)

      # A stale alias with no fresher live holder still resolves: age never drops it.
      hold_alias!(stale, "192.0.2.42", :confirmed, days_ago: 60)

      resolved =
        actor
        |> lookup(partition, ["192.0.2.40", "192.0.2.41", "192.0.2.42"])
        |> Map.new(fn {ip, record} -> {ip, record.canonical_device_id} end)

      assert resolved == %{
               "192.0.2.40" => fresh.uid,
               "192.0.2.41" => fresh.uid,
               "192.0.2.42" => stale.uid
             }
    end

    # Rows written before aliases were validated (AliasPolicy) may still hold such values.
    test "a leftover link-local alias resolves nothing", %{actor: actor, partition: partition} do
      holder = device!(actor, partition, "198.51.100.50")
      %DeviceAliasState{id: id} = hold_alias!(holder, "192.0.2.50", :confirmed)

      Repo.query!(
        "UPDATE platform.device_alias_states SET alias_value = '169.254.10.20' WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

      assert lookup(actor, partition, ["169.254.10.20"]) == %{}
    end
  end

  test "batch lookup ignores stale identity cache by default", %{actor: actor} do
    ip = unique_ip("batch-stale")
    stale_record = stale_record("sr:" <> Ecto.UUID.generate(), ip)

    IdentityCache.put(ip, stale_record)

    assert DeviceLookup.batch_lookup_by_ip([ip], actor: actor) == %{}

    cached_result = DeviceLookup.batch_lookup_by_ip([ip], actor: actor, use_cache: true)
    assert cached_result[ip].canonical_device_id == stale_record.canonical_device_id
  end

  test "batch lookup emits authoritative fallback telemetry for cache misses", %{actor: actor} do
    attach_telemetry([[:serviceradar, :identity, :lookup, :authoritative_fallback]])
    ip = unique_ip("authoritative-fallback")

    assert DeviceLookup.batch_lookup_by_ip([ip], actor: actor, use_cache: true) == %{}

    assert_receive {:telemetry, [:serviceradar, :identity, :lookup, :authoritative_fallback],
                    %{count: 1}, %{reason: :cache_miss}}
  end

  test "single lookup ignores stale identity cache by default", %{actor: actor} do
    ip = unique_ip("single-stale")
    stale_record = stale_record("sr:" <> Ecto.UUID.generate(), ip)

    IdentityCache.put(ip, stale_record)

    assert {:ok, %{found: false, record: nil}} =
             DeviceLookup.get_canonical_device([%{kind: :ip, value: ip}], actor: actor)

    assert {:ok, %{found: true, record: record, resolved_via: "cache"}} =
             DeviceLookup.get_canonical_device([%{kind: :ip, value: ip}],
               actor: actor,
               use_cache: true
             )

    assert record.canonical_device_id == stale_record.canonical_device_id
  end

  test "device lifecycle invalidates IP identity cache", %{actor: actor} do
    ip = unique_ip("device-lifecycle")
    stale_record = stale_record("sr:" <> Ecto.UUID.generate(), ip)

    IdentityCache.put(ip, stale_record)
    assert IdentityCache.get(ip) == stale_record

    assert {:ok, _device} =
             Device
             |> Ash.Changeset.for_create(:create, %{
               uid: "sr:" <> Ecto.UUID.generate(),
               ip: ip,
               hostname: "cache-invalidation-test"
             })
             |> Ash.create(actor: actor)

    assert IdentityCache.get(ip) == nil
  end

  test "alias lifecycle invalidates IP identity cache", %{actor: actor} do
    uid = "sr:" <> Ecto.UUID.generate()
    device_ip = unique_ip("alias-lifecycle-device")
    alias_ip = unique_ip("alias-lifecycle-alias")
    stale_record = stale_record(uid, alias_ip)

    assert {:ok, _device} =
             Device
             |> Ash.Changeset.for_create(:create, %{
               uid: uid,
               ip: device_ip,
               hostname: "alias-cache-invalidation-test"
             })
             |> Ash.create(actor: actor)

    IdentityCache.put(alias_ip, stale_record)
    assert IdentityCache.get(alias_ip) == stale_record

    assert {:ok, _alias_state} =
             DeviceAliasState.create_detected(
               %{
                 device_id: uid,
                 partition: "default",
                 alias_type: :ip,
                 alias_value: alias_ip,
                 metadata: %{}
               },
               actor: actor
             )

    assert IdentityCache.get(alias_ip) == nil
  end

  defp lookup(actor, partition, ips) do
    DeviceLookup.batch_lookup_by_ip(ips,
      actor: actor,
      include_deleted: true,
      include_detected: true,
      partition: partition
    )
  end

  defp device!(actor, partition, ip, opts \\ []) do
    uid = "sr:" <> Ecto.UUID.generate()

    assert {:ok, device} =
             Device
             |> Ash.Changeset.for_create(:create, %{
               uid: uid,
               ip: ip,
               partition: partition,
               hostname: "host-" <> String.slice(uid, 3, 8)
             })
             |> Ash.create(actor: actor)

    if Keyword.get(opts, :deleted, false) do
      assert {:ok, deleted} =
               device
               |> Ash.Changeset.for_update(:soft_delete, %{
                 deleted_reason: "test",
                 deleted_by: "device_lookup_alias_test"
               })
               |> Ash.update(actor: actor)

      deleted
    else
      device
    end
  end

  # An IP alias of `device` in `state`, last seen `days_ago` days ago.
  defp hold_alias!(device, ip, state, opts \\ []) do
    actor = SystemActor.system(:device_lookup_alias_test)

    assert {:ok, alias_state} =
             DeviceAliasState.create_detected(
               %{
                 device_id: device.uid,
                 partition: device.partition,
                 alias_type: :ip,
                 alias_value: ip,
                 metadata: %{}
               },
               actor: actor
             )

    Repo.query!(
      """
      UPDATE platform.device_alias_states
      SET state = $2,
          sighting_count = $3,
          last_seen_at = (now() AT TIME ZONE 'utc') - make_interval(days => $4)
      WHERE id = $1
      """,
      [
        Ecto.UUID.dump!(alias_state.id),
        Atom.to_string(state),
        Keyword.get(opts, :sightings, 1),
        Keyword.get(opts, :days_ago, 0)
      ]
    )

    alias_state
  end

  defp stale_record(uid, ip) do
    %{
      canonical_device_id: uid,
      partition: "default",
      metadata_hash: nil,
      attributes: %{"ip" => ip, "partition" => "default"},
      updated_at: DateTime.utc_now()
    }
  end

  defp unique_ip(seed) do
    <<second, third, fourth, _rest::binary>> =
      :crypto.hash(:sha256, "#{seed}-#{Ash.UUID.generate()}")

    "10.#{1 + rem(second, 254)}.#{1 + rem(third, 254)}.#{1 + rem(fourth, 254)}"
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "device-lookup-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end

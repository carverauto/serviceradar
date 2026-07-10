defmodule ServiceRadar.Identity.DeviceLookupAliasTest do
  @moduledoc """
  Integration coverage for IP alias resolution in DeviceLookup.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
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

defmodule ServiceRadar.Identity.DeviceLookupAliasTest do
  @moduledoc """
  Integration coverage for IP alias resolution in DeviceLookup.
  """

  use ExUnit.Case, async: false

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

    assert {:ok, _device} =
             Device
             |> Ash.Changeset.for_create(:create, %{
               uid: uid,
               ip: "216.17.46.98",
               hostname: "tonka01"
             })
             |> Ash.create(actor: actor)

    assert {:ok, alias_state} =
             DeviceAliasState.create_detected(
               %{
                 device_id: uid,
                 partition: "default",
                 alias_type: :ip,
                 alias_value: "192.168.10.1",
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

    result = DeviceLookup.batch_lookup_by_ip(["192.168.10.1"], actor: actor)

    assert result["192.168.10.1"].canonical_device_id == uid
  end

  test "batch lookup ignores stale identity cache by default", %{actor: actor} do
    ip = "192.0.2.201"
    stale_record = stale_record("sr:" <> Ecto.UUID.generate(), ip)

    IdentityCache.put(ip, stale_record)

    assert DeviceLookup.batch_lookup_by_ip([ip], actor: actor) == %{}

    cached_result = DeviceLookup.batch_lookup_by_ip([ip], actor: actor, use_cache: true)
    assert cached_result[ip].canonical_device_id == stale_record.canonical_device_id
  end

  test "single lookup ignores stale identity cache by default", %{actor: actor} do
    ip = "192.0.2.202"
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
    ip = "192.0.2.203"
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

  defp stale_record(uid, ip) do
    %{
      canonical_device_id: uid,
      partition: "default",
      metadata_hash: nil,
      attributes: %{"ip" => ip, "partition" => "default"},
      updated_at: DateTime.utc_now()
    }
  end
end

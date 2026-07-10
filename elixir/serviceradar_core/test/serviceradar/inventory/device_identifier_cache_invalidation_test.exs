defmodule ServiceRadar.Inventory.DeviceIdentifierCacheInvalidationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    IdentityCache.clear()

    on_exit(fn -> IdentityCache.clear() end)

    {:ok, actor: SystemActor.system(:test)}
  end

  test "registering an IP identifier invalidates the identifier IP and device IP cache entries",
       %{
         actor: actor
       } do
    unique_id = Ash.UUID.generate()
    device_ip = unique_ip("identifier-device-#{unique_id}")
    identifier_ip = unique_ip("identifier-value-#{unique_id}")
    device_uid = "device-identifier-cache-#{unique_id}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          ip: device_ip,
          hostname: "identifier-cache-#{unique_id}",
          discovery_sources: ["armis"]
        },
        actor: actor
      )
      |> Ash.create()

    put_cache(device_ip, "stale-device-ip-#{unique_id}")
    put_cache(identifier_ip, "stale-identifier-ip-#{unique_id}")

    assert {:ok, _identifier} =
             DeviceIdentifier
             |> Ash.Changeset.for_create(
               :register,
               %{
                 device_id: device_uid,
                 identifier_type: :ip,
                 identifier_value: identifier_ip,
                 partition: "default",
                 confidence: :weak,
                 source: "test"
               },
               actor: actor
             )
             |> Ash.create()

    assert IdentityCache.get(device_ip) == nil
    assert IdentityCache.get(identifier_ip) == nil
  end

  test "reassigning an identifier invalidates old and new device IP cache entries", %{
    actor: actor
  } do
    unique_id = Ash.UUID.generate()
    old_ip = unique_ip("identifier-old-#{unique_id}")
    new_ip = unique_ip("identifier-new-#{unique_id}")
    old_uid = "device-identifier-old-#{unique_id}"
    new_uid = "device-identifier-new-#{unique_id}"

    {:ok, _old_device} = create_device(old_uid, old_ip, actor)
    {:ok, _new_device} = create_device(new_uid, new_ip, actor)

    {:ok, identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(
        :register,
        %{
          device_id: old_uid,
          identifier_type: :integration_id,
          identifier_value: "integration-#{unique_id}",
          partition: "default",
          confidence: :strong,
          source: "test"
        },
        actor: actor
      )
      |> Ash.create()

    put_cache(old_ip, "stale-old-device-#{unique_id}")
    put_cache(new_ip, "stale-new-device-#{unique_id}")

    assert {:ok, _reassigned} =
             identifier
             |> Ash.Changeset.for_update(:reassign_device, %{device_id: new_uid}, actor: actor)
             |> Ash.update()

    assert IdentityCache.get(old_ip) == nil
    assert IdentityCache.get(new_ip) == nil
  end

  defp create_device(uid, ip, actor) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        ip: ip,
        hostname: uid,
        discovery_sources: ["armis"]
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp put_cache(ip, device_uid) do
    IdentityCache.put(ip, %{
      canonical_device_id: device_uid,
      partition: "default",
      metadata_hash: nil,
      attributes: %{"ip" => ip},
      updated_at: DateTime.utc_now()
    })
  end

  defp unique_ip(seed) when is_binary(seed) do
    <<second, third, fourth, _rest::binary>> = :crypto.hash(:sha256, seed)
    "10.#{1 + rem(second, 254)}.#{1 + rem(third, 254)}.#{1 + rem(fourth, 254)}"
  end
end

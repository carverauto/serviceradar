defmodule ServiceRadar.Inventory.Identity.ResolveByAddressTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.ResolveByAddress

  defp actor, do: SystemActor.system(:resolve_by_address_test)

  defp unique_ip do
    n = System.unique_integer([:positive])
    "10.#{rem(n, 250) + 1}.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 253) + 1}"
  end

  defp create_device!(attrs) do
    uid = "sr:" <> Ecto.UUID.generate()

    Device
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{uid: uid, hostname: "host-#{uid}"}, attrs),
      actor: actor()
    )
    |> Ash.create!()
  end

  defp register_identifier!(device, type, value, partition \\ "default") do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device.uid,
        identifier_type: type,
        identifier_value: value,
        partition: partition,
        source: "test"
      },
      actor: actor()
    )
    |> Ash.create!()
  end

  test "resolves a unique live device by IP in the default partition" do
    ip = unique_ip()
    device = create_device!(%{ip: ip})

    assert {:ok, uid} = ResolveByAddress.resolve(%{ip: ip})
    assert uid == device.uid
  end

  test "prefers a partition-scoped IP identifier over the device row IP" do
    live_ip = unique_ip()
    ident_ip = unique_ip()
    device = create_device!(%{ip: live_ip})
    register_identifier!(device, :ip, ident_ip, "site-b")

    assert {:ok, uid} = ResolveByAddress.resolve(%{ip: ident_ip, partition: "site-b"})
    assert uid == device.uid
  end

  test "returns not_found for an unknown IP" do
    assert {:error, :not_found} = ResolveByAddress.resolve(%{ip: unique_ip()})
  end

  test "rejects a malformed IP" do
    assert {:error, :invalid_ip} = ResolveByAddress.resolve(%{ip: "not-an-ip"})
  end

  test "ignores a MAC that is not in inventory" do
    ip = unique_ip()
    device = create_device!(%{ip: ip})

    assert {:ok, uid} =
             ResolveByAddress.resolve(%{ip: ip, mac: "aa:bb:cc:dd:ee:ff"})

    assert uid == device.uid
  end

  test "accepts a MAC that corroborates the same device" do
    ip = unique_ip()
    device = create_device!(%{ip: ip, mac: "AA:BB:CC:11:22:33"})
    register_identifier!(device, :mac, "AABBCC112233")

    assert {:ok, uid} =
             ResolveByAddress.resolve(%{ip: ip, mac: "aa:bb:cc:11:22:33"})

    assert uid == device.uid
  end

  test "conflicts when MAC resolves to a different device than the IP" do
    ip_a = unique_ip()
    ip_b = unique_ip()
    device_a = create_device!(%{ip: ip_a})
    device_b = create_device!(%{ip: ip_b, mac: "DE:AD:BE:EF:00:01"})
    register_identifier!(device_b, :mac, "DEADBEEF0001")

    assert {:error, {:mac_ip_conflict, ip_uid, mac_uid}} =
             ResolveByAddress.resolve(%{ip: ip_a, mac: "de:ad:be:ef:00:01"})

    assert ip_uid == device_a.uid
    assert mac_uid == device_b.uid
  end

  test "does not mint a device on a miss" do
    ip = unique_ip()
    assert {:error, :not_found} = ResolveByAddress.resolve(%{ip: ip})

    assert {:ok, []} =
             Device
             |> Ash.Query.for_read(:by_ip, %{ip: ip, include_deleted: false}, actor: actor())
             |> Ash.read()
  end
end

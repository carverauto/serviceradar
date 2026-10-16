defmodule ServiceRadar.Inventory.EndpointInventoryFleetOrdinalTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.EndpointInventoryFleetOrdinal
  alias ServiceRadar.Inventory.FleetIdentity
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:endpoint_inventory_fleet_ordinal_test)}
  end

  test "allocates a stable ordinal for a device uid", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-fleet-ordinal-device-#{unique}")

    assert {:ok, ordinal} = EndpointInventoryFleetOrdinal.ensure_allocated(device.uid)
    assert is_integer(ordinal)
    assert ordinal > 0

    assert {:ok, ^ordinal} = EndpointInventoryFleetOrdinal.ensure_allocated(device.uid)
    assert EndpointInventoryFleetOrdinal.ordinal_for(device.uid) == ordinal
  end

  test "does not allocate ordinals for service component ids" do
    assert {:ok, nil} = EndpointInventoryFleetOrdinal.ensure_allocated("serviceradar:core-elx")
    assert EndpointInventoryFleetOrdinal.ordinal_for("serviceradar:core-elx") == nil
  end

  test "canonical and raw bulk writers allocate once without burning IDs on repeated lookup", %{
    actor: actor
  } do
    uid = "sr:identity-#{System.unique_integer([:positive])}"
    device = create_device!(actor, uid)
    ordinal = FleetIdentity.device_ordinal(uid)
    assert ordinal > 0

    assert %{rows: [[last_value]]} =
             Repo.query!("SELECT currval('platform.device_fleet_ordinals_ordinal_seq')")

    assert {:ok, ^ordinal} = FleetIdentity.ensure_device(uid)
    assert {:ok, ^ordinal} = EndpointInventoryFleetOrdinal.ensure_allocated(device.uid)

    assert %{rows: [[^last_value]]} =
             Repo.query!("SELECT currval('platform.device_fleet_ordinals_ordinal_seq')")

    raw_uid = "sr:raw-#{System.unique_integer([:positive])}"
    Repo.query!("INSERT INTO platform.ocsf_devices(uid, type_id) VALUES ($1, 0)", [raw_uid])
    assert {:ok, raw_ordinal} = FleetIdentity.ensure_device(raw_uid)
    assert raw_ordinal > ordinal
  end

  test "delete and legitimate restore retain identity while stale merge restores are denied", %{
    actor: actor
  } do
    uid = "sr:lifecycle-#{System.unique_integer([:positive])}"
    device = create_device!(actor, uid)
    ordinal = FleetIdentity.device_ordinal(uid)
    epoch = FleetIdentity.epoch()
    assert is_binary(epoch)

    Repo.query!(
      "UPDATE platform.ocsf_devices SET deleted_at = now(), deleted_reason = 'manual' WHERE uid = $1",
      [uid]
    )

    assert FleetIdentity.device_ordinal(uid) == nil
    assert {:ok, nil} = FleetIdentity.ensure_device(uid)
    restore!(uid, actor)
    assert FleetIdentity.device_ordinal(uid) == ordinal
    assert FleetIdentity.epoch() == epoch

    Repo.query!(
      "UPDATE platform.ocsf_devices SET deleted_at = now(), deleted_reason = 'merged' WHERE uid = $1",
      [uid]
    )

    assert {:ok, nil} = FleetIdentity.ensure_device(uid)
    merged = %{device | deleted_at: DateTime.utc_now(), deleted_reason: "merged"}

    assert {:error, _} =
             merged
             |> Ash.Changeset.for_update(:restore, %{}, actor: actor)
             |> Ash.update(actor: actor)

    assert FleetIdentity.device_ordinal(uid) == nil
    restore!(uid, actor, allow_retained: true)
    assert FleetIdentity.device_ordinal(uid) == ordinal
  end

  test "interface identities follow canonical pairs and retain deleted assignments", %{
    actor: actor
  } do
    a = create_device!(actor, "sr:interface-a-#{System.unique_integer([:positive])}").uid
    b = create_device!(actor, "sr:interface-b-#{System.unique_integer([:positive])}").uid
    insert_interface!(a, "ifindex:7")
    insert_interface!(b, "ifindex:7")
    first = FleetIdentity.interface_ordinal(a, "ifindex:7")
    second = FleetIdentity.interface_ordinal(b, "ifindex:7")
    assert first != second
    assert {:ok, ^first} = FleetIdentity.ensure_interface(a, "ifindex:7")

    Repo.query!(
      "DELETE FROM platform.discovered_interfaces WHERE device_id = $1 AND interface_uid = 'ifindex:7'",
      [a]
    )

    assert FleetIdentity.interface_ordinal(a, "ifindex:7") == nil
    insert_interface!(a, "ifindex:7")
    assert FleetIdentity.interface_ordinal(a, "ifindex:7") == first

    insert_interface!(a, "ifindex:8")
    moved = FleetIdentity.interface_ordinal(a, "ifindex:8")

    Repo.query!(
      "UPDATE platform.discovered_interfaces SET device_id = $2 WHERE device_id = $1 AND interface_uid = 'ifindex:8'",
      [a, b]
    )

    assert FleetIdentity.interface_ordinal(a, "ifindex:8") == nil
    assert {:ok, moved_ordinal} = FleetIdentity.ensure_interface(b, "ifindex:8")
    assert moved_ordinal > 0
    assert moved_ordinal != moved
    assert FleetIdentity.interface_ordinal(b, "ifindex:8") == moved_ordinal
    assert FleetIdentity.interface_ordinal(b, "ifindex:7") == second
  end

  test "unsigned high ordinals survive reads and bounded resumable reconciliation", %{
    actor: actor
  } do
    uid = "sr:unsigned-#{System.unique_integer([:positive])}"
    create_device!(actor, uid)
    high = 2_147_483_648 + rem(System.unique_integer([:positive]), 1_000_000)

    Repo.query!("UPDATE platform.device_fleet_ordinals SET ordinal = $2 WHERE uid = $1", [
      uid,
      high
    ])

    assert {:ok, ^high} = FleetIdentity.ensure_device(uid)
    assert FleetIdentity.device_ordinal(uid) == high
    assert {:error, :invalid_page_limit} = FleetIdentity.backfill_devices(nil, limit: 501)

    assert {:ok, %{cursor: cursor, count: 1, done?: false}} =
             FleetIdentity.backfill_devices(nil, limit: 1)

    assert is_binary(cursor)
    assert {:ok, %{count: count}} = FleetIdentity.backfill_devices(cursor, limit: 1)
    assert count <= 1
    assert FleetIdentity.device_ordinal(uid) == high
  end

  test "permanent dictionary entries reject destructive cleanup", %{actor: actor} do
    uid = "sr:permanent-#{System.unique_integer([:positive])}"
    create_device!(actor, uid)

    assert_raise Postgrex.Error, ~r/Persistent fleet identities cannot be deleted/, fn ->
      Repo.query!("DELETE FROM platform.device_fleet_ordinals WHERE uid = $1", [uid])
    end
  end

  defp insert_interface!(uid, interface) do
    Repo.query!(
      "INSERT INTO platform.discovered_interfaces(device_id, interface_uid, timestamp) VALUES ($1, $2, now())",
      [uid, interface]
    )
  end

  defp restore!(uid, actor, args \\ []) do
    require Ash.Query

    result =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid == ^uid)
      |> Ash.bulk_update(:restore, Map.new(args), actor: actor, return_errors?: true)

    assert %Ash.BulkResult{status: :success} = result
  end

  defp create_device!(actor, uid) do
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: "host01.example.com",
        type_id: 0,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end

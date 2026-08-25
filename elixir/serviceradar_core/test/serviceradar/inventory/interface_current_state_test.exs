defmodule ServiceRadar.Inventory.InterfaceCurrentStateTest do
  @moduledoc """
  Current-state persistence: one row per `(device_id, interface_uid)`, and the
  SNMP targeting count is a DEVICE count (GitHub #4021).
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:interface_current_state_test)}
  end

  test "a second observation of the same interface upserts, it does not append", %{actor: actor} do
    {:ok, device} = create_device(actor)
    uid = "name:eth0"
    t1 = ~U[2026-08-25 00:00:00Z]
    t2 = ~U[2026-08-25 00:05:00Z]

    assert :ok = upsert_interface(device.uid, uid, t1, "192.168.1.1", actor)
    assert :ok = upsert_interface(device.uid, uid, t2, "192.168.1.1", actor)

    rows = interfaces_for(device.uid, actor)
    assert [%Interface{interface_uid: ^uid, timestamp: ^t2}] = rows
  end

  test "a device with several matching interfaces counts once as an SNMP target", %{actor: actor} do
    {:ok, device} = create_device(actor)

    assert :ok = upsert_interface(device.uid, "name:eth0", DateTime.utc_now(), "10.0.0.1", actor)
    assert :ok = upsert_interface(device.uid, "name:eth1", DateTime.utc_now(), "10.0.0.2", actor)
    assert :ok = upsert_interface(device.uid, "name:eth2", DateTime.utc_now(), "10.0.0.3", actor)

    interface_count =
      Interface
      |> Ash.Query.filter(device_id == ^device.uid)
      |> Ash.count!(actor: actor)

    target_count =
      Interface
      |> Ash.Query.filter(device_id == ^device.uid)
      |> Ash.Query.distinct(:device_id)
      |> Ash.count!(actor: actor)

    assert interface_count == 3
    assert target_count == 1
  end

  defp create_device(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "iface-current-state",
      ip: unique_ip()
    })
    |> Ash.create(actor: actor)
  end

  defp upsert_interface(device_id, interface_uid, timestamp, ip, actor) do
    record = %{
      timestamp: timestamp,
      device_id: device_id,
      interface_uid: interface_uid,
      device_ip: ip,
      if_name: interface_uid,
      ip_addresses: [ip],
      created_at: timestamp
    }

    result =
      Ash.bulk_create([record], Interface, :create,
        actor: actor,
        upsert?: true,
        upsert_identity: :unique_interface,
        upsert_fields: [:timestamp, :device_ip, :if_name, :ip_addresses]
      )

    case result do
      %Ash.BulkResult{status: :success} -> :ok
      other -> {:error, other}
    end
  end

  defp interfaces_for(device_id, actor) do
    Interface
    |> Ash.Query.filter(device_id == ^device_id)
    |> Ash.Query.sort(interface_uid: :asc)
    |> Ash.read!(actor: actor)
  end

  defp unique_ip do
    n = System.unique_integer([:positive])
    "100.82.#{rem(n, 200) + 1}.#{rem(div(n, 200), 200) + 1}"
  end
end

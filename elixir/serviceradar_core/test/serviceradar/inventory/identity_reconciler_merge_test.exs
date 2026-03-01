defmodule ServiceRadar.Inventory.IdentityReconcilerMergeTest do
  @moduledoc """
  Integration coverage for merge behavior with interface observations.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, IdentityReconciler, Interface}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_merge_test)
    handler_id = "identity-reconciler-merge-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:serviceradar, :identity_reconciler, :merge, :executed],
          [:serviceradar, :identity_reconciler, :merge, :failed]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    {:ok, actor: actor}
  end

  test "merge reassigns interface observations and drops duplicates", %{actor: actor} do
    from_uid = "sr:" <> Ecto.UUID.generate()
    to_uid = "sr:" <> Ecto.UUID.generate()

    assert {:ok, _from_device} = create_device(actor, from_uid, "merge-from")
    assert {:ok, _to_device} = create_device(actor, to_uid, "merge-to")

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    earlier = DateTime.add(timestamp, -60, :second)

    assert {:ok, _} = create_interface(actor, to_uid, timestamp, "ifindex:1", 1, "eth0")
    assert {:ok, _} = create_interface(actor, from_uid, timestamp, "ifindex:1", 1, "eth0")
    assert {:ok, _} = create_interface(actor, from_uid, earlier, "ifindex:2", 2, "eth1")

    assert :ok = IdentityReconciler.merge_devices(from_uid, to_uid, actor: actor)

    assert_receive {:telemetry_event, [:serviceradar, :identity_reconciler, :merge, :executed],
                    %{count: 1}, telemetry_metadata}

    assert telemetry_metadata.reason == "identity_resolution"
    assert telemetry_metadata.manual_override == false
    assert telemetry_metadata.from_device_id == from_uid
    assert telemetry_metadata.to_device_id == to_uid

    assert {:error, _} = Device.get_by_uid(from_uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(to_uid, false, actor: actor)

    assert {:ok, interfaces} = list_interfaces(actor, to_uid)
    assert length(interfaces) == 2

    assert Enum.any?(interfaces, fn iface ->
             iface.interface_uid == "ifindex:1" and iface.timestamp == timestamp
           end)

    assert Enum.any?(interfaces, fn iface ->
             iface.interface_uid == "ifindex:2" and iface.timestamp == earlier
           end)

    assert {:ok, []} = list_interfaces(actor, from_uid)
  end

  test "manual merge reason emits manual override telemetry", %{actor: actor} do
    from_uid = "sr:" <> Ecto.UUID.generate()
    to_uid = "sr:" <> Ecto.UUID.generate()

    assert {:ok, _from_device} = create_device(actor, from_uid, "merge-from-manual")
    assert {:ok, _to_device} = create_device(actor, to_uid, "merge-to-manual")

    assert :ok =
             IdentityReconciler.merge_devices(from_uid, to_uid,
               actor: actor,
               reason: "manual_merge"
             )

    assert_receive {:telemetry_event, [:serviceradar, :identity_reconciler, :merge, :executed],
                    %{count: 1}, telemetry_metadata}

    assert telemetry_metadata.reason == "manual_merge"
    assert telemetry_metadata.manual_override == true
  end

  defp create_device(actor, uid, hostname) do
    attrs = %{
      uid: uid,
      hostname: hostname,
      ip: "10.0.0.#{:rand.uniform(200)}"
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp create_interface(actor, device_id, timestamp, interface_uid, if_index, if_name) do
    attrs = %{
      timestamp: timestamp,
      device_id: device_id,
      interface_uid: interface_uid,
      if_index: if_index,
      if_name: if_name
    }

    Interface
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp list_interfaces(actor, device_id) do
    Interface
    |> Ash.Query.filter(device_id == ^device_id)
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read(actor: actor)
  end
end

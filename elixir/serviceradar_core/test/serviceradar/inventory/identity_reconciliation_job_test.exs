defmodule ServiceRadar.Inventory.IdentityReconciliationJobTest do
  @moduledoc """
  Integration coverage for scheduled reconciliation job merges.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, Interface, MergeAudit}
  alias ServiceRadar.Jobs.JobSchedule
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciliation_job_test)
    {:ok, actor: actor}
  end

  test "scheduled reconciliation merges duplicates and reassigns interfaces", %{actor: actor} do
    mac = "AA:BB:CC:DD:EE:FF"
    mac_with_space = mac <> " "

    {:ok, device_a} = create_device(actor, "reconcile-a")
    {:ok, device_b} = create_device(actor, "reconcile-b")

    assert {:ok, _} = register_identifier(actor, device_a.uid, :mac, mac)
    assert {:ok, _} = register_identifier(actor, device_b.uid, :mac, mac_with_space)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _} = create_interface(actor, device_b.uid, timestamp, "ifindex:99", 99, "eth99")

    schedule = ensure_identity_schedule(actor)

    assert {:ok, _} =
             schedule
             |> Ash.Changeset.for_update(:run_identity_reconciliation, %{})
             |> Ash.update(actor: actor)

    {remaining_id, merged_id} =
      case Device.get_by_uid(device_a.uid, false, actor: actor) do
        {:ok, _} -> {device_a.uid, device_b.uid}
        _ -> {device_b.uid, device_a.uid}
      end

    assert {:error, _} = Device.get_by_uid(merged_id, false, actor: actor)

    assert {:ok, interfaces} = list_interfaces(actor, remaining_id)
    assert Enum.any?(interfaces, &(&1.interface_uid == "ifindex:99"))

    assert {:ok, []} = list_interfaces(actor, merged_id)

    assert {:ok, [audit | _]} = MergeAudit.get_merged_to(merged_id, actor: actor)
    assert audit.to_device_id == remaining_id
  end

  defp ensure_identity_schedule(actor) do
    case JobSchedule.get_by_job_key("device_identity_reconciliation", actor: actor) do
      {:ok, %JobSchedule{} = schedule} ->
        schedule

      _ ->
        attrs = %{
          job_key: "device_identity_reconciliation",
          cron: "*/5 * * * *",
          enabled: true
        }

        {:ok, schedule} =
          JobSchedule
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(actor: actor)

        schedule
    end
  end

  defp create_device(actor, hostname) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: "10.11.0.#{:rand.uniform(200)}"
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

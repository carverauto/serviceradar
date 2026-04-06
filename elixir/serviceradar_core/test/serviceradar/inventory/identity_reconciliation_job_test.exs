defmodule ServiceRadar.Inventory.IdentityReconciliationJobTest do
  @moduledoc """
  Integration coverage for scheduled reconciliation job merges.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Jobs.JobSchedule
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciliation_job_test)
    {:ok, actor: actor}
  end

  test "scheduled reconciliation does not merge MAC-only duplicates", %{actor: actor} do
    mac = "AA:BB:CC:DD:EE:FF"
    mac_with_space = mac <> " "

    {:ok, device_a} = create_device(actor, "reconcile-a")
    {:ok, device_b} = create_device(actor, "reconcile-b")

    assert :ok = register_strong_identifiers(actor, device_a.uid, %{mac: mac})
    assert :ok = register_strong_identifiers(actor, device_b.uid, %{mac: mac_with_space})

    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    assert {:ok, _} = create_interface(actor, device_b.uid, timestamp, "ifindex:99", 99, "eth99")

    schedule = ensure_identity_schedule(actor)

    assert {:ok, _} =
             schedule
             |> Ash.Changeset.for_update(:run_identity_reconciliation, %{})
             |> Ash.update(actor: actor)

    assert {:ok, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(device_b.uid, false, actor: actor)

    assert {:ok, interfaces_a} = list_interfaces(actor, device_a.uid)
    refute Enum.any?(interfaces_a, &(&1.interface_uid == "ifindex:99"))

    assert {:ok, interfaces_b} = list_interfaces(actor, device_b.uid)
    assert Enum.any?(interfaces_b, &(&1.interface_uid == "ifindex:99"))

    assert {:ok, []} = MergeAudit.get_merged_to(device_a.uid, actor: actor)
    assert {:ok, []} = MergeAudit.get_merged_to(device_b.uid, actor: actor)
  end

  test "register-time reconciliation merges duplicates with non-MAC strong identifier", %{
    actor: actor
  } do
    shared_armis_id = "armis-reconcile-#{System.unique_integer([:positive])}"

    {:ok, device_a} = create_device(actor, "reconcile-strong-a")
    {:ok, device_b} = create_device(actor, "reconcile-strong-b")

    assert :ok = register_strong_identifiers(actor, device_a.uid, %{armis_id: shared_armis_id})
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    assert {:ok, _} =
             create_interface(actor, device_b.uid, timestamp, "ifindex:101", 101, "eth101")

    assert :ok = register_strong_identifiers(actor, device_b.uid, %{armis_id: shared_armis_id})

    {remaining_id, merged_id} =
      case Device.get_by_uid(device_a.uid, false, actor: actor) do
        {:ok, _} -> {device_a.uid, device_b.uid}
        _ -> {device_b.uid, device_a.uid}
      end

    assert {:error, _} = Device.get_by_uid(merged_id, false, actor: actor)

    assert {:ok, interfaces} = list_interfaces(actor, remaining_id)
    assert Enum.any?(interfaces, &(&1.interface_uid == "ifindex:101"))

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

  defp unique_device_ip(seed) do
    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "10.11.#{third}.#{fourth}"
  end

  defp register_strong_identifiers(actor, device_id, ids) do
    case ServiceRadar.Inventory.IdentityReconciler.register_identifiers(device_id, ids,
           actor: actor
         ) do
      :ok -> :ok
      other -> other
    end
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

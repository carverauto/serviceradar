defmodule ServiceRadar.Inventory.DeviceSoftDeleteTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, DeviceCleanupSettings, DeviceCleanupWorker, SyncIngestor}
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query
  import Ecto.Query

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:device_soft_delete_test)
    {:ok, actor: actor}
  end

  test "soft delete hides device from default reads", %{actor: actor} do
    uid = unique_uid()
    ip = unique_ip(uid)
    mac = unique_mac()

    {:ok, device} = create_device(actor, uid, ip, mac)
    {:ok, _} = soft_delete_device(actor, device, "cleanup")

    assert {:ok, []} =
             Device
             |> Ash.Query.filter(uid == ^uid)
             |> read_results(actor)

    assert {:ok, [deleted]} =
             Device
             |> Ash.Query.for_read(:read, %{include_deleted: true})
             |> Ash.Query.filter(uid == ^uid)
             |> read_results(actor)

    assert deleted.deleted_at
    assert deleted.deleted_by
  end

  test "restore clears tombstone and returns device to default reads", %{actor: actor} do
    uid = unique_uid()
    ip = unique_ip(uid)
    mac = unique_mac()

    {:ok, device} = create_device(actor, uid, ip, mac)
    {:ok, _} = soft_delete_device(actor, device, "user_requested")

    {:ok, _restored} =
      device
      |> Ash.Changeset.for_update(:restore, %{}, actor: actor)
      |> Ash.update()

    assert {:ok, [restored]} =
             Device
             |> Ash.Query.filter(uid == ^uid)
             |> read_results(actor)

    assert is_nil(restored.deleted_at)
    assert is_nil(restored.deleted_by)
    assert is_nil(restored.deleted_reason)
  end

  test "sync ingestor restores deleted devices when identity matches", %{actor: actor} do
    ip = unique_ip()
    mac = unique_mac()
    netbox_device_id = "netbox-#{System.unique_integer([:positive])}"

    uid =
      IdentityReconciler.generate_deterministic_device_id(%{
        agent_id: nil,
        armis_id: nil,
        integration_id: nil,
        netbox_id: netbox_device_id,
        mac: String.replace(mac, ":", ""),
        ip: ip,
        partition: "default"
      })

    {:ok, device} = create_device(actor, uid, ip, mac)
    {:ok, _} = soft_delete_device(actor, device, "integration_refresh")

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "restored-#{uid}",
      "source" => "netbox",
      "metadata" => %{"netbox_device_id" => netbox_device_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert {:ok, [restored]} =
             Device
             |> Ash.Query.for_read(:read, %{include_deleted: true})
             |> Ash.Query.filter(uid == ^uid)
             |> read_results(actor)

    assert is_nil(restored.deleted_at)
    assert is_nil(restored.deleted_by)
  end

  test "cleanup worker purges devices past retention window", %{actor: actor} do
    {:ok, _settings} =
      ensure_cleanup_settings(actor, %{
        retention_days: 1,
        cleanup_interval_minutes: 60,
        batch_size: 100,
        enabled: true
      })

    {:ok, old_device} = create_device(actor, unique_uid(), unique_ip(), unique_mac())
    {:ok, recent_device} = create_device(actor, unique_uid(), unique_ip(), unique_mac())

    {:ok, _} = soft_delete_device(actor, old_device, "stale")
    {:ok, _} = soft_delete_device(actor, recent_device, "recent")

    old_cutoff = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)

    from(d in "ocsf_devices",
      where: d.uid == ^old_device.uid,
      update: [set: [deleted_at: ^old_cutoff]]
    )
    |> Repo.update_all([], prefix: "platform")

    job = struct(Oban.Job, args: %{"manual" => true})
    assert :ok = DeviceCleanupWorker.perform(job)

    assert {:ok, []} =
             Device
             |> Ash.Query.for_read(:read, %{include_deleted: true})
             |> Ash.Query.filter(uid == ^old_device.uid)
             |> read_results(actor)

    assert {:ok, [remaining]} =
             Device
             |> Ash.Query.for_read(:read, %{include_deleted: true})
             |> Ash.Query.filter(uid == ^recent_device.uid)
             |> read_results(actor)

    assert remaining.deleted_at
  end

  defp create_device(actor, uid, ip, mac) do
    attrs = %{
      uid: uid,
      ip: ip,
      mac: mac,
      hostname: "device-#{uid}"
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp soft_delete_device(actor, device, reason) do
    deleted_by = Map.get(actor, :id) || Map.get(actor, :email)

    device
    |> Ash.Changeset.for_update(
      :soft_delete,
      %{deleted_reason: reason, deleted_by: deleted_by},
      actor: actor
    )
    |> Ash.update()
  end

  defp ensure_cleanup_settings(actor, attrs) do
    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{} = settings} ->
        settings
        |> Ash.Changeset.for_update(:update, attrs)
        |> Ash.update(actor: actor)

      {:ok, nil} ->
        DeviceCleanupSettings
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(actor: actor)

      {:error, reason} ->
        flunk("failed to load cleanup settings: #{inspect(reason)}")
    end
  end

  defp read_results(query, actor) do
    case Ash.read(query, actor: actor) do
      {:ok, %Ash.Page.Keyset{results: results}} -> {:ok, results}
      other -> other
    end
  end

  defp unique_uid do
    "device-#{System.unique_integer([:positive])}"
  end

  defp unique_ip(uid \\ nil) do
    seed = uid || System.unique_integer([:positive])
    octet = rem(:erlang.phash2(seed), 200) + 20
    "10.42.#{octet}.#{rem(octet * 7, 250) + 2}"
  end

  defp unique_mac do
    suffix = Integer.to_string(:rand.uniform(255), 16) |> String.pad_leading(2, "0")
    "AA:BB:CC:DD:EE:#{String.upcase(suffix)}"
  end
end

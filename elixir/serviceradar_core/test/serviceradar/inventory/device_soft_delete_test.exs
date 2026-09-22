defmodule ServiceRadar.Inventory.DeviceSoftDeleteTest do
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

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

    restore_query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid == ^uid)

    assert %Ash.BulkResult{status: :success} =
             Ash.bulk_update(restore_query, :restore, %{},
               actor: actor,
               return_records?: false,
               return_errors?: true
             )

    assert {:ok, [restored]} =
             Device
             |> Ash.Query.filter(uid == ^uid)
             |> read_results(actor)

    assert is_nil(restored.deleted_at)
    assert is_nil(restored.deleted_by)
    assert is_nil(restored.deleted_reason)
  end

  describe "managed-state actions" do
    test ":mark_managed sets is_managed true", %{actor: actor} do
      {:ok, device} = create_device(actor, unique_uid(), unique_ip(), unique_mac())

      # A fresh device defaults to unmanaged, so assert the default first and
      # then the transition -- otherwise this only proves the create default.
      refute device.is_managed

      assert {:ok, managed} = mark_device(device, :mark_managed, actor)
      assert managed.is_managed
    end

    test ":mark_unmanaged clears is_managed for a device with no agent_id", %{actor: actor} do
      {:ok, device} = create_device(actor, unique_uid(), unique_ip(), unique_mac())

      # Start from managed, or this asserts the create-time default rather than
      # the action clearing the flag.
      assert {:ok, managed} = mark_device(device, :mark_managed, actor)
      assert managed.is_managed

      assert {:ok, unmanaged} = mark_device(managed, :mark_unmanaged, actor)
      refute unmanaged.is_managed
    end

    test ":mark_unmanaged refuses an agent-backed device", %{actor: actor} do
      uid = unique_uid()
      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, device} = create_device(actor, uid, unique_ip(), unique_mac(), %{agent_id: agent_id})

      # Mark it managed first. Without this the device is already unmanaged by
      # default, so "it is still unmanaged" would prove nothing about the guard.
      assert {:ok, managed} = mark_device(device, :mark_managed, actor)
      assert managed.is_managed

      # The validator runs while the changeset for the action is built, so an
      # agent-backed device is rejected before the update touches the row. The
      # bulk path cannot rely on this -- see BulkState's is_nil(agent_id)
      # filter, because Ash skips a validation whose atomic/3 returns :ok.
      changeset = Ash.Changeset.for_update(managed, :mark_unmanaged, %{}, actor: actor)

      refute changeset.valid?
      assert changeset.errors != []
      assert {:error, _error} = Ash.update(changeset)

      assert {:ok, [reloaded]} =
               Device
               |> Ash.Query.filter(uid == ^uid)
               |> read_results(actor)

      assert reloaded.agent_id == agent_id
      assert reloaded.is_managed
    end
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
    {:ok, _} = register_identifier(actor, device.uid, :mac, IdentityReconciler.normalize_mac(mac))
    {:ok, _} = register_identifier(actor, device.uid, :netbox_device_id, netbox_device_id)
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

    Repo.update_all(
      from(d in "ocsf_devices",
        where: d.uid == ^old_device.uid,
        update: [set: [deleted_at: ^old_cutoff]]
      ),
      [],
      prefix: "platform"
    )

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

  test "keyset pagination returns all matching devices from a single large-limit page", %{
    actor: actor
  } do
    # Regression guard for the truncation observed in the field:
    # Ash.read!(query, page: [limit: 5000, count: true]) returned 251 results
    # with more?: false when Ash.count! returned 345 -- all rows were present
    # but the query came back short without signalling it. Root cause: no
    # explicit ORDER BY, so the database's chosen scan stopped early.
    # Device.read now declares sort: [uid: :asc] via prepare build(...).
    tag = "pagn-regression-#{System.unique_integer([:positive])}"

    created_uids =
      for i <- 1..8 do
        uid = "#{tag}-#{i}"
        ip = "198.51.100.#{i}"
        mac = unique_mac()
        {:ok, _} = create_device(actor, uid, ip, mac)
        uid
      end

    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false})
      |> Ash.Query.filter(like(uid, ^"#{tag}-%"))

    expected_count = Ash.count!(query, actor: actor)
    assert expected_count == 8

    {:ok, page} = Ash.read(query, actor: actor, page: [limit: 100, count: true])
    assert page.more? == false
    assert length(page.results) == expected_count

    returned_uids = page.results |> Enum.map(& &1.uid) |> Enum.sort()
    assert returned_uids == Enum.sort(created_uids)
  end

  defp create_device(actor, uid, ip, mac, extra_attrs \\ %{}) do
    attrs = Map.merge(%{uid: uid, ip: ip, mac: mac, hostname: "device-#{uid}"}, extra_attrs)

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp mark_device(device, action, actor) do
    device
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.update()
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

  defp register_identifier(actor, device_id, type, value) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:upsert, %{
      device_id: device_id,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      confidence: :strong,
      source: "device_soft_delete_test"
    })
    |> Ash.create(actor: actor)
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

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
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
    seed =
      case uid do
        nil -> System.unique_integer([:positive, :monotonic])
        value -> :erlang.phash2(value, 62_500)
      end

    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "10.42.#{third}.#{fourth}"
  end

  defp unique_mac do
    seed = System.unique_integer([:positive, :monotonic])
    octet_4 = rem(div(seed, 65_536), 256)
    octet_5 = rem(div(seed, 256), 256)
    octet_6 = rem(seed, 256)

    Enum.map_join([0xAA, 0xBB, 0xCC, octet_4, octet_5, octet_6], ":", fn octet ->
      octet
      |> Integer.to_string(16)
      |> String.pad_leading(2, "0")
      |> String.upcase()
    end)
  end
end

defmodule ServiceRadar.Inventory.DeviceSoftDeleteTest do
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Sync.DeviceWrites
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

  # #4615: an agent check-in restores its soft-deleted device, and a restore is an identity
  # transition however it happens.
  test "agent check-in restores a soft-deleted device with an identity_revision bump", %{
    actor: actor
  } do
    agent_id = "soft-delete-agent-#{System.unique_integer([:positive])}"
    attrs = agent_attrs(agent_id)

    assert {:ok, uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
    {:ok, [device]} = read_including_deleted(uid, actor)
    {:ok, deleted} = soft_delete_device(actor, device, "operator_cleanup")

    assert {:ok, ^uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

    {:ok, [restored]} = read_including_deleted(uid, actor)
    assert is_nil(restored.deleted_at)
    assert is_nil(restored.deleted_reason)
    assert restored.identity_revision == deleted.identity_revision + 1
    assert [["operator_cleanup"]] = revival_audit_reasons(uid)
  end

  # #4615: a check-in never writes a merged-away device back to life. Resolution follows a
  # merge redirect, so a check-in reaches the tombstone only when it has none to follow
  # (here: a merge tombstone with no merge_audit row); the device then stays deleted.
  test "agent check-in never revives a merged-away device", %{actor: actor} do
    agent_id = "merged-agent-#{System.unique_integer([:positive])}"
    attrs = agent_attrs(agent_id)

    assert {:ok, uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
    {:ok, [device]} = read_including_deleted(uid, actor)
    {:ok, tombstone} = soft_delete_device(actor, device, "merged")

    assert {:error, {:merged_away_device, ^uid}} =
             AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

    {:ok, [after_check_in]} = read_including_deleted(uid, actor)
    assert after_check_in.deleted_at
    assert after_check_in.deleted_reason == "merged"
    assert after_check_in.identity_revision == tombstone.identity_revision
    assert revival_audit_reasons(uid) == []
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
    {:ok, deleted} = soft_delete_device(actor, device, "integration_refresh")

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

    # A revival is an identity transition, whichever writer performs it (#4614).
    assert restored.identity_revision == deleted.identity_revision + 1

    assert [["integration_refresh"]] = revival_audit_reasons(uid),
           "the revival must leave a device_revival_audit row naming the tombstone it cleared"
  end

  # #4614: a device merged into another is never written back to life by the upsert.
  # BatchResolver follows merge redirects, so the upsert reaches a merged-away uid only when
  # a merge lands between resolution and the write; this drives the write directly, as that
  # race would.
  test "the device upsert never revives a merged-away device", %{actor: actor} do
    # Resolver follows merge redirects only for ServiceRadar uids (`sr:<uuid>`).
    {:ok, merged_away} = create_device(actor, sr_uid(), unique_ip(), unique_mac())
    {:ok, survivor} = create_device(actor, sr_uid(), unique_ip(), unique_mac())

    assert :ok =
             MergeEngine.merge_devices(merged_away.uid, survivor.uid,
               actor: actor,
               reason: "device_soft_delete_test"
             )

    {:ok, [tombstone]} = read_including_deleted(merged_away.uid, actor)
    assert tombstone.deleted_reason == "merged"

    now = DateTime.truncate(DateTime.utc_now(), :second)

    record = %{
      uid: merged_away.uid,
      hostname: "stale-write-#{merged_away.uid}",
      discovery_sources: ["device_soft_delete_test"],
      last_seen_time: now,
      modified_time: now
    }

    assert {:ok, remap} = DeviceWrites.bulk_upsert_devices([record])

    assert remap == %{merged_away.uid => survivor.uid},
           "the batch's dependent writes must follow the merge to the survivor"

    {:ok, [after_write]} = read_including_deleted(merged_away.uid, actor)
    assert after_write.deleted_at == tombstone.deleted_at
    assert after_write.deleted_reason == "merged"
    assert after_write.hostname == tombstone.hostname
    assert after_write.identity_revision == tombstone.identity_revision
    assert revival_audit_reasons(merged_away.uid) == []
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

  test "keyset pagination completeness: single large-limit page returns all matching rows", %{
    actor: actor
  } do
    tag = "pagn-#{System.unique_integer([:positive])}"

    created_uids =
      for i <- 1..8 do
        uid = "#{tag}-#{i}"
        {:ok, _} = create_device(actor, uid, "198.51.100.#{i}", unique_mac())
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

  defp agent_attrs(agent_id) do
    %{
      hostname: "host-#{agent_id}",
      os: "linux",
      arch: "amd64",
      partition: "default",
      source_ip: unique_ip(),
      capabilities: []
    }
  end

  defp read_including_deleted(uid, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid == ^uid)
    |> read_results(actor)
  end

  defp revival_audit_reasons(uid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT previous_deleted_reason
        FROM platform.device_revival_audit
        WHERE device_uid = $1
        ORDER BY event_id
        """,
        [uid]
      )

    rows
  end

  defp read_results(query, actor) do
    case Ash.read(query, actor: actor) do
      {:ok, %Ash.Page.Keyset{results: results}} -> {:ok, results}
      other -> other
    end
  end

  defp sr_uid, do: "sr:" <> Ecto.UUID.generate()

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

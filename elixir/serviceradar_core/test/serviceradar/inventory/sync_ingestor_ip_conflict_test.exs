defmodule ServiceRadar.Inventory.SyncIngestorIpConflictTest do
  @moduledoc """
  Regression coverage for active-IP unique-index handling in bulk device upserts.

  Source-authoritative integration identifiers must not be rebound to whichever
  unrelated device currently owns an IP. Contested IPs are dropped from the
  incoming strong device (pre-resolved before insert when the holder is already
  visible, or via reactive recovery on a true race). Same-batch handoffs must
  free the relinquished IP for the new claimant rather than clearing it.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_ip_conflict_test)
    {:ok, actor: actor}
  end

  test "preserves generic integration identity when active-IP is already held", %{
    actor: actor
  } do
    ip = unique_test_ip()
    integration_id = "integration-#{System.unique_integer([:positive])}"

    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "preexisting",
        ip: ip
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => ip,
      "hostname" => "incoming",
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }

    log =
      capture_log(fn ->
        assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
      end)

    # Reactive unique-violation path must not fire for a stable, already-visible
    # holder (#4796). Outcome assertions below are the source of truth.
    refute log =~ "Bulk device upsert hit active-IP conflict"
    refute log =~ "ocsf_devices_unique_active_ip_idx"

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert length(devices_at_ip) == 1
    [%Device{uid: canonical_uid}] = devices_at_ip
    assert canonical_uid == existing.uid

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value == ^integration_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: integration_device_uid}] = List.wrap(identifiers)
    assert integration_device_uid != canonical_uid

    {:ok, integration_device} = Device.get_by_uid(integration_device_uid, false, actor: actor)
    assert integration_device.ip == nil
  end

  test "pre-resolves a batch with colliding strong identities without choosing an IP owner", %{
    actor: actor
  } do
    ip = unique_test_ip()
    first_id = "integration-first-#{System.unique_integer([:positive])}"
    second_id = "integration-second-#{System.unique_integer([:positive])}"

    updates = [
      integration_update(first_id, ip, "first-incoming"),
      integration_update(second_id, ip, "second-incoming")
    ]

    log =
      capture_log(fn ->
        assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)
      end)

    refute log =~ "Bulk device upsert hit active-IP conflict"
    refute log =~ "ocsf_devices_unique_active_ip_idx"

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value in ^[first_id, second_id]
      )
      |> Ash.read(actor: actor)

    assert identifiers |> Enum.map(& &1.device_id) |> Enum.uniq() |> length() == 2

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    # Neither strong identity may silently win the free IP by record order.
    assert devices_at_ip == []
  end

  test "same-batch handoff moves IP from previous owner to new strong claimant", %{
    actor: actor
  } do
    ip_x = unique_test_ip()
    ip_y = unique_test_ip()
    owner_id = "owner-#{System.unique_integer([:positive])}"
    claimer_id = "claimer-#{System.unique_integer([:positive])}"

    # Seed owner A on X through the real ingest path so identifiers exist.
    assert :ok =
             SyncIngestor.ingest_updates(
               [integration_update(owner_id, ip_x, "owner-a")],
               actor: actor
             )

    owner_uid = device_uid_for_integration!(owner_id, actor)
    {:ok, %Device{ip: ^ip_x}} = Device.get_by_uid(owner_uid, false, actor: actor)

    # One batch: A moves X→Y while new strong B claims X.
    updates = [
      integration_update(owner_id, ip_y, "owner-a-moved"),
      integration_update(claimer_id, ip_x, "claimer-b")
    ]

    assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)

    claimer_uid = device_uid_for_integration!(claimer_id, actor)
    assert claimer_uid != owner_uid

    {:ok, owner} = Device.get_by_uid(owner_uid, false, actor: actor)
    {:ok, claimer} = Device.get_by_uid(claimer_uid, false, actor: actor)

    assert owner.ip == ip_y
    assert claimer.ip == ip_x

    {:ok, at_x} =
      Device
      |> Ash.Query.filter(ip == ^ip_x and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert Enum.map(at_x, & &1.uid) == [claimer_uid]
  end

  test "same-batch blank-IP clear frees the slot for a new strong claimant", %{
    actor: actor
  } do
    ip_x = unique_test_ip()
    owner_id = "blank-owner-#{System.unique_integer([:positive])}"
    claimer_id = "blank-claimer-#{System.unique_integer([:positive])}"

    assert :ok =
             SyncIngestor.ingest_updates(
               [integration_update(owner_id, ip_x, "owner-a")],
               actor: actor
             )

    owner_uid = device_uid_for_integration!(owner_id, actor)

    # A→"" is an explicit clear under upsert SQL (not omit/keep). B must inherit X.
    updates = [
      integration_update(owner_id, "", "owner-a-cleared"),
      integration_update(claimer_id, ip_x, "claimer-b")
    ]

    assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)

    claimer_uid = device_uid_for_integration!(claimer_id, actor)
    {:ok, owner} = Device.get_by_uid(owner_uid, false, actor: actor)
    {:ok, claimer} = Device.get_by_uid(claimer_uid, false, actor: actor)

    # Upsert SQL maps blank EXCLUDED.ip to NULL, not empty string.
    assert owner.ip == nil
    assert claimer.ip == ip_x

    {:ok, at_x} =
      Device
      |> Ash.Query.filter(ip == ^ip_x and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert Enum.map(at_x, & &1.uid) == [claimer_uid]
  end

  test "plugin inventory snapshot AWX host keeps identity without stealing live IP", %{
    actor: actor
  } do
    ip = unique_test_ip()
    integration_id = "awx:host:host-#{System.unique_integer([:positive])}"

    {:ok, agent_device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "agent-holder",
        ip: ip
      })
      |> Ash.create(actor: actor)

    # Complete plugin inventories strip integration_* from ocsf_devices.metadata
    # but still register typed identifiers — model that path, not the thin
    # metadata-only shape.
    update = %{
      "ip" => ip,
      "hostname" => "awx-host",
      "source" => "awx",
      "metadata" => %{
        "integration_type" => "plugin_device_discovery",
        "integration_id" => integration_id,
        "plugin_inventory_snapshot" => true
      }
    }

    for _ <- 1..3 do
      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
    end

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value == ^integration_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: awx_uid}] = List.wrap(identifiers)
    assert awx_uid != agent_device.uid

    {:ok, awx_device} = Device.get_by_uid(awx_uid, false, actor: actor)
    assert awx_device.ip == nil
    # Snapshot path must not leave integration_id on the device row.
    refute is_map(awx_device.metadata) and Map.has_key?(awx_device.metadata, "integration_id")

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert Enum.map(devices_at_ip, & &1.uid) == [agent_device.uid]
  end

  test "concurrent distinct strong identities race on a free IP without dual holders", %{
    actor: actor
  } do
    ip = unique_test_ip()
    first_id = "race-a-#{System.unique_integer([:positive])}"
    second_id = "race-b-#{System.unique_integer([:positive])}"

    # Barrier after both prechecks complete (not merely task entry), so both
    # writers observe a free IP before either insert_all runs.
    parent = self()
    barrier = make_ref()
    precheck_count = :atomics.new(1, signed: false)

    previous_hooks = Application.get_env(:serviceradar_core, :device_writes_test_hooks)

    Application.put_env(:serviceradar_core, :device_writes_test_hooks, %{
      after_active_ip_precheck: fn ->
        n = :atomics.add_get(precheck_count, 1, 1)

        if n <= 2 do
          send(parent, {:precheck_done, barrier, n})

          receive do
            {:go, ^barrier} -> :ok
          after
            10_000 -> flunk("post-precheck barrier timeout")
          end
        end
      end
    })

    on_exit(fn ->
      case previous_hooks do
        nil -> Application.delete_env(:serviceradar_core, :device_writes_test_hooks)
        hooks -> Application.put_env(:serviceradar_core, :device_writes_test_hooks, hooks)
      end
    end)

    task_a =
      Task.async(fn ->
        SyncIngestor.ingest_updates(
          [integration_update(first_id, ip, "race-a")],
          actor: actor
        )
      end)

    task_b =
      Task.async(fn ->
        SyncIngestor.ingest_updates(
          [integration_update(second_id, ip, "race-b")],
          actor: actor
        )
      end)

    assert_receive {:precheck_done, ^barrier, 1}, 10_000
    assert_receive {:precheck_done, ^barrier, 2}, 10_000
    send(task_a.pid, {:go, barrier})
    send(task_b.pid, {:go, barrier})

    assert :ok = Task.await(task_a, 30_000)
    assert :ok = Task.await(task_b, 30_000)

    first_uid = device_uid_for_integration!(first_id, actor)
    second_uid = device_uid_for_integration!(second_id, actor)
    assert first_uid != second_uid

    {:ok, first} = Device.get_by_uid(first_uid, false, actor: actor)
    {:ok, second} = Device.get_by_uid(second_uid, false, actor: actor)

    holders =
      [first, second]
      |> Enum.filter(fn device -> device.ip == ip end)
      |> Enum.map(& &1.uid)

    # Exactly one survivor: free-IP races must not leave the address unowned
    # and must not dual-hold under the unique active-IP index.
    assert length(holders) == 1

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert length(devices_at_ip) == 1
    assert hd(devices_at_ip).uid in [first_uid, second_uid]
  end

  defp integration_update(integration_id, ip, hostname) do
    %{
      "ip" => ip,
      "hostname" => hostname,
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }
  end

  defp device_uid_for_integration!(integration_id, actor) do
    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value == ^integration_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: uid}] = List.wrap(identifiers)
    uid
  end

  defp unique_test_ip do
    <<third, fourth, _rest::binary>> = :crypto.hash(:sha256, Ash.UUID.generate())
    "100.124.#{1 + rem(third, 250)}.#{1 + rem(fourth, 250)}"
  end
end

defmodule ServiceRadar.Inventory.SyncIngestorIpConflictTest do
  @moduledoc """
  Regression coverage for active-IP unique-index handling in bulk device upserts.

  Source-authoritative integration identifiers must not be rebound to whichever
  unrelated device currently owns an IP. Contested IPs are dropped from the
  incoming strong device (pre-resolved before insert when the holder is already
  visible, or via reactive recovery on a true race). Same-batch handoffs must
  free the relinquished IP for the new claimant rather than clearing it.

  Interactive device edits (`Device :update`, GitHub #4357) take the same
  index through the atomic single-record path: a taken IP must surface as an
  `ip` "has already been taken" validation error instead of
  `Ash.Error.Unknown`. Inactive and stale holders retain their addresses
  when a conflicting update is rejected.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusObservation
  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusSnapshot
  alias ServiceRadar.Ash.NotificationQueue
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.Inventory.Discovery.Decoders
  alias ServiceRadar.Inventory.Identity.Address
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.Sync.DeviceWrites
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.IdentifierArchiveFixtures

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

  # #4705: an existing device never adopts a provisional seed. A device that moves onto an
  # address a sweep has seeded keeps its own record and takes the address, and the conflict is
  # recorded. The write used to land on the seed instead, leaving the device at its old address
  # on every sync. A seed is nothing but its address, so the release soft-deletes it as
  # seed_released (add-source-id-succession D8): it used to stay live, an addressless record
  # nothing removed but ephemeral expiry.
  test "an existing device moving onto a sweep-seeded address takes it and retires the seed", %{
    actor: actor
  } do
    seed = move_onto_seed!(actor)

    assert {:error, _} = Device.get_by_uid(seed.uid, false, actor: actor)
    assert %DateTime{} = seed.deleted_at
    assert seed.deleted_reason == "seed_released"
    assert seed.deleted_by == "system:seed_release"
    assert seed.hostname == nil
    assert_received {:seed_released, %{count: 1}, %{deleted_reason: "seed_released"}}
    # The seed is not one of the batch's records, so the release hints it itself.
    seed_uid = seed.uid
    assert_receive {:devices_invalidated, [^seed_uid]}
  end

  # The release is a raw update: its hint waits for the transaction, and a rollback drops it.
  test "a released holder is hinted only once its transaction commits", %{actor: actor} do
    ip = unique_test_ip()
    holder = create_device!(actor, "released-holder", ip)
    holder_uid = holder.uid
    release = fn -> DeviceWrites.lock_and_clear_for_upsert([], [], [{holder_uid, ip}]) end
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, DevicePubSub.invalidation_topic())

    assert {:error, :synthetic_failure} =
             NotificationQueue.with_queue(fn ->
               Repo.transaction(fn ->
                 release.()
                 Repo.rollback(:synthetic_failure)
               end)
             end)

    refute_received {:devices_invalidated, [^holder_uid]}
    assert {:ok, _device} = Device.get_by_uid(holder_uid, false, actor: actor)

    assert {:ok, :ok} = NotificationQueue.with_queue(fn -> Repo.transaction(release) end)
    assert_receive {:devices_invalidated, [^holder_uid]}
    assert {:ok, %Device{ip: nil}} = Device.get_by_uid(holder_uid, false, actor: actor)
  end

  test "a seed's alias of the address it releases does not keep it live", %{actor: actor} do
    seed = move_onto_seed!(actor, %{}, &detect_alias!(&1, &1.ip, actor))

    assert seed.deleted_reason == "seed_released"
    assert_received {:seed_released, %{count: 1}, _metadata}
  end

  # D8 retires a released seed only when the address is all it is. Anything more anchors the
  # record: the release clears its address and it stays live.
  test "a seed with an identifier row releases the address and stays live", %{actor: actor} do
    actor
    |> move_onto_seed!(%{}, &register_mac!(&1, actor))
    |> assert_seed_kept()
  end

  test "a seed with an archived identifier releases the address and stays live", %{
    actor: actor
  } do
    actor
    |> move_onto_seed!(%{}, &IdentifierArchiveFixtures.archive!(:mac, register_mac!(&1, actor)))
    |> assert_seed_kept()
  end

  test "a seed another source has reported releases the address and stays live", %{
    actor: actor
  } do
    actor
    |> move_onto_seed!(%{discovery_sources: ["sweep", "mapper"]})
    |> assert_seed_kept()
  end

  test "a seed with an alias of another address releases the address and stays live", %{
    actor: actor
  } do
    actor
    |> move_onto_seed!(%{}, &detect_alias!(&1, unique_test_ip(), actor))
    |> assert_seed_kept()
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

  # Unboxed: each ingest writes inside its own fenced transaction (Identity.Fence),
  # and two open transactions cannot share one sandbox connection, so the second
  # writer could never reach its precheck while the first holds the barrier.
  @tag sandbox: :unboxed
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
    on_exit(fn -> TestSupport.delete_device_fixtures!([first_uid, second_uid]) end)
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

  # A lost active-IP race inside the identity fence must reach the fence as a
  # retryable Postgres error. When the write opened a nested Repo.transaction
  # (the rollup bypass every batch over the bulk-refresh threshold takes, or an
  # address release), DBConnection marked the connection failed and the fence
  # saw "transaction rolling back" instead, so the whole batch failed. The race
  # is staged inside the fenced write: right after the precheck, a competing
  # device takes the address the batch is about to claim.
  describe "an active-IP race lost inside the identity fence" do
    test "is retried when the batch bypasses inventory rollups", %{actor: actor} do
      ip = unique_test_ip()
      integration_id = "bulk-race-#{System.unique_integer([:positive])}"

      # Any batch larger than the threshold takes the bypass; zero puts a
      # one-record batch on that path.
      put_test_env(:inventory_rollup_bulk_refresh_threshold, 0)
      prechecks = take_address_on_first_precheck(ip, actor)

      assert :ok =
               SyncIngestor.ingest_updates(
                 [integration_update(integration_id, ip, "bulk-race")],
                 actor: actor
               )

      assert :atomics.get(prechecks, 1) >= 2

      {:ok, device} =
        Device.get_by_uid(device_uid_for_integration!(integration_id, actor), false, actor: actor)

      assert device.ip == ip
    end

    test "is retried when the batch also releases an address", %{actor: actor} do
      {old_ip, seed_ip} = seed_ip_pair()
      free_ip = unique_test_ip()
      armis_id = "armis-release-race-#{System.unique_integer([:positive])}"
      integration_id = "release-race-#{System.unique_integer([:positive])}"

      assert :ok = SyncIngestor.ingest_updates([armis_update(armis_id, old_ip, 0)], actor: actor)
      armis_uid = device_uid_for_armis!(armis_id, actor)

      seed =
        create_device!(actor, nil, seed_ip, %{
          uid: "sr:" <> Ecto.UUID.generate(),
          discovery_sources: ["sweep"],
          metadata: %{"identity_state" => "provisional", "identity_source" => "sweep_ip_seed"}
        })

      prechecks = take_address_on_first_precheck(free_ip, actor)

      # Moving onto the seed's address releases it; the second record claims
      # the address the competing device takes after the precheck.
      assert :ok =
               SyncIngestor.ingest_updates(
                 [
                   armis_update(armis_id, seed_ip, 60),
                   integration_update(integration_id, free_ip, "release-race")
                 ],
                 actor: actor
               )

      assert :atomics.get(prechecks, 1) >= 2

      {:ok, armis_device} = Device.get_by_uid(armis_uid, false, actor: actor)
      assert armis_device.ip == seed_ip

      {:ok, seed} = Device.get_by_uid(seed.uid, true, actor: actor)
      assert seed.ip == nil

      {:ok, claimant} =
        Device.get_by_uid(device_uid_for_integration!(integration_id, actor), false, actor: actor)

      assert claimant.ip == free_ip
    end
  end

  # A tombstone keeps the address it had when it was deleted. Once a live device
  # holds that address, a revival that kept it would put two live rows on one
  # address, so every attempt of the batch failed on the unique active-IP index.
  describe "reviving a tombstone whose address a live device now holds" do
    test "a revival with no incoming address comes back without the stale one", %{actor: actor} do
      ip = unique_test_ip()
      {tombstone, holder} = tombstone_with_taken_address!(ip, actor)

      assert {:ok, _remap} = DeviceWrites.bulk_upsert_devices([upsert_record(tombstone.uid, nil)])

      {:ok, revived} = Device.get_by_uid(tombstone.uid, false, actor: actor)
      assert is_nil(revived.deleted_at)
      assert is_nil(revived.ip)

      {:ok, holder} = Device.get_by_uid(holder.uid, false, actor: actor)
      assert holder.ip == ip
    end

    test "a revival takes the incoming address even when it ranks below the stored one", %{
      actor: actor
    } do
      ip = unique_test_ip()
      link_local = "169.254.77.#{rem(System.unique_integer([:positive, :monotonic]), 254) + 1}"
      {tombstone, holder} = tombstone_with_taken_address!(ip, actor)

      assert Address.rank(link_local) < Address.rank(ip)

      assert {:ok, _remap} =
               DeviceWrites.bulk_upsert_devices([upsert_record(tombstone.uid, link_local)])

      {:ok, revived} = Device.get_by_uid(tombstone.uid, false, actor: actor)
      assert is_nil(revived.deleted_at)
      assert revived.ip == link_local

      {:ok, holder} = Device.get_by_uid(holder.uid, false, actor: actor)
      assert holder.ip == ip
    end
  end

  describe "interactive device update IP conflicts (GitHub #4357)" do
    test "update reports a usable ip error when another active device owns the IP", %{
      actor: actor
    } do
      {taken_ip, free_ip} = doc_ip_pair()
      _holder = create_device!(actor, "4357-holder", taken_ip)
      subject = create_device!(actor, "4357-subject", free_ip)

      assert {:error, %Invalid{errors: errors}} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert Enum.any?(errors, &ip_taken_error?/1)
    end

    test "update preserves an inactive holder and reports a usable ip error", %{actor: actor} do
      {taken_ip, free_ip} = doc_ip_pair()
      holder = create_device!(actor, "4357-inactive-holder", taken_ip)
      subject = create_device!(actor, "4357-inactive-subject", free_ip)

      {:ok, _} = Device.mark_inactive(holder, actor: actor)

      assert {:error, %Invalid{errors: errors}} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert Enum.any?(errors, &ip_taken_error?/1)

      assert {:ok, %Device{ip: ^taken_ip}} =
               Device.get_by_uid(holder.uid, false, actor: actor)

      assert {:ok, %Device{ip: ^free_ip}} =
               Device.get_by_uid(subject.uid, false, actor: actor)
    end

    test "update preserves a stale holder and reports a usable ip error", %{actor: actor} do
      {taken_ip, free_ip} = doc_ip_pair()
      holder = create_device!(actor, "4357-stale-holder", taken_ip)
      subject = create_device!(actor, "4357-stale-subject", free_ip)

      stale_at =
        DateTime.utc_now()
        |> DateTime.shift(day: -30)
        |> DateTime.truncate(:second)
        |> DateTime.to_naive()

      {:ok, _} =
        Repo.query("UPDATE platform.ocsf_devices SET last_seen_time = $1 WHERE uid = $2", [
          stale_at,
          holder.uid
        ])

      assert {:error, %Invalid{errors: errors}} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert Enum.any?(errors, &ip_taken_error?/1)

      assert {:ok, %Device{ip: ^taken_ip}} =
               Device.get_by_uid(holder.uid, false, actor: actor)

      assert {:ok, %Device{ip: ^free_ip}} =
               Device.get_by_uid(subject.uid, false, actor: actor)
    end

    test "update keeps working when resubmitting the device's own IP", %{actor: actor} do
      {ip, _free_ip} = doc_ip_pair()
      subject = create_device!(actor, "4357-self", ip)

      assert {:ok, updated} =
               subject
               |> Ash.Changeset.for_update(:update, %{hostname: "4357-renamed", ip: ip})
               |> Ash.update(actor: actor)

      assert updated.hostname == "4357-renamed"
      assert updated.ip == ip
    end

    test "update succeeds when the previous holder was soft-deleted", %{actor: actor} do
      {taken_ip, free_ip} = doc_ip_pair()
      holder = create_device!(actor, "4357-deleted-holder", taken_ip)
      subject = create_device!(actor, "4357-deleted-subject", free_ip)

      {:ok, _} = Device.soft_delete(holder, "test-retired", "test", actor: actor)

      assert {:ok, updated} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert updated.ip == taken_ip
    end

    test "update succeeds when the requested IP is unassigned", %{actor: actor} do
      {new_ip, old_ip} = doc_ip_pair()
      subject = create_device!(actor, "4357-free-subject", old_ip)

      assert {:ok, updated} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: new_ip})
               |> Ash.update(actor: actor)

      assert updated.ip == new_ip

      assert {:ok, %Device{ip: ^new_ip}} =
               Device.get_by_uid(subject.uid, false, actor: actor)
    end

    test "same IP in another partition does not conflict", %{actor: actor} do
      {taken_ip, free_ip} = doc_ip_pair()

      other =
        create_device!(actor, "4357-other-partition", taken_ip, %{partition: "test-partition"})

      subject = create_device!(actor, "4357-partition-subject", free_ip)

      assert {:ok, updated} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert updated.ip == taken_ip

      assert {:ok, %Device{ip: ^taken_ip}} =
               Device.get_by_uid(other.uid, false, actor: actor)
    end
  end

  describe "primary address preference (GitHub #3905)" do
    test "the SQL rank and the Elixir rank agree", %{actor: _actor} do
      # Two implementations exist on purpose: the upsert must compare against
      # the CURRENT row, which only SQL sees, while alias/in-memory decisions
      # need it in Elixir. Two implementations drift unless something pins them,
      # so this is that something.
      addresses = [
        "8.8.8.8",
        "152.117.116.178",
        "10.0.0.5",
        "192.168.1.1",
        "172.16.0.1",
        "172.15.0.1",
        "172.32.0.1",
        "100.64.0.1",
        "127.0.0.1",
        "169.254.1.1",
        "0.0.0.0",
        "2001:4860:4860::8888",
        "::1",
        "::",
        "fd2f:420a:24b1:1:f692:bfff:fe75:c72a",
        "fe80::f692:bfff:fe75:c72b",
        "fe90::1",
        "febf::1",
        "fec0::1",
        "fc00::1",
        "fdff::1",
        "::ffff:192.168.1.1",
        "::ffff:8.8.8.8",
        # Forms real collectors actually send: SNMP reports link-locals with a
        # zone, and interface addresses arrive in CIDR form.
        "fe80::1%eth0",
        "192.168.1.1/24",
        "0.0.0.0/0",
        "  10.0.0.5  ",
        "not-an-ip",
        ""
      ]

      %{rows: rows} =
        Repo.query!(
          "SELECT a, platform.sr_address_rank(a) FROM unnest($1::text[]) AS a",
          [addresses]
        )

      sql_ranks = Map.new(rows, fn [address, rank] -> {address, rank} end)

      mismatched =
        Enum.filter(addresses, fn address ->
          Address.rank(address) != Map.fetch!(sql_ranks, address)
        end)

      assert mismatched == [],
             "SQL and Elixir rankings disagree for: " <>
               Enum.map_join(mismatched, ", ", fn address ->
                 "#{address} (elixir=#{Address.rank(address)} sql=#{Map.fetch!(sql_ranks, address)})"
               end)

      # The strength the upsert guard compares: the family first, then the rank.
      %{rows: rows} =
        Repo.query!(
          "SELECT a, platform.sr_address_strength(a) FROM unnest($1::text[]) AS a",
          [addresses ++ ["169.254.1.5", "2001:db8::3", "::ffff:169.254.1.1"]]
        )

      strength_mismatches =
        for [address, sql] <- rows, Address.strength(address) != sql, do: {address, sql}

      assert strength_mismatches == [],
             "SQL and Elixir strengths disagree: #{inspect(strength_mismatches)}"
    end

    test "the SQL guard and the Elixir chooser keep a primary unless the incoming is stronger" do
      # {stored, incoming, replaces?}: a usable IPv4 over any IPv6, a routable
      # address of either family over a link-local of either family, otherwise the
      # higher rank within the family. Equal strength never replaces.
      cases = [
        {"192.168.0.3", "2001:db8::3", false},
        {"2001:db8::3", "192.168.0.3", true},
        {"169.254.1.5", "2001:db8::5", true},
        {"2001:db8::5", "169.254.1.5", false},
        {"fe80::9", "192.0.2.9", true},
        {"fe80::9", "169.254.1.9", false},
        {"169.254.1.9", "fe80::9", false},
        {"10.1.0.5", "203.0.113.5", true},
        {"203.0.113.5", "10.1.0.5", false},
        {"192.0.2.6", "198.51.100.6", false},
        {"fd00::5", "2001:db8::5", true},
        {"::ffff:192.0.2.1", "2001:db8::1", false},
        {"192.0.2.3", "fd00::3", false}
      ]

      %{rows: rows} =
        Repo.query!(
          """
          SELECT s, i, platform.sr_address_strength(i) > platform.sr_address_strength(s)
          FROM unnest($1::text[], $2::text[]) AS c(s, i)
          """,
          [Enum.map(cases, &elem(&1, 0)), Enum.map(cases, &elem(&1, 1))]
        )

      sql = Map.new(rows, fn [stored, incoming, replaces?] -> {{stored, incoming}, replaces?} end)

      wrong =
        for {stored, incoming, expected} <- cases,
            Map.fetch!(sql, {stored, incoming}) != expected or
              Address.better?(incoming, stored) != expected,
            do: {stored, incoming, expected}

      assert wrong == [], "keep-unless-stronger disagrees for #{inspect(wrong)}"
    end

    test "a link-local sighting does not overwrite a routable primary", %{actor: actor} do
      mac = unique_universal_mac()
      routable = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, routable)], actor: actor)
      assert device_ip_for_mac(mac, actor) == routable

      # This is the #3905 mechanism: NDP census sightings arrive carrying a
      # link-local, and before the rank guard they replaced the primary.
      assert :ok =
               SyncIngestor.ingest_updates(
                 [mac_update(mac, "fe80::f692:bfff:fe75:c72b")],
                 actor: actor
               )

      assert device_ip_for_mac(mac, actor) == routable,
             "a link-local sighting clobbered the routable primary"
    end

    test "a single-sighting source re-IPs once the old address leaves its window", %{
      actor: actor
    } do
      # A sweep reports one address per sighting, which says nothing about the
      # device's other addresses. Its stored primary is replaced at equal or lower
      # strength only after the sweep has stopped sighting it for the window; a
      # public-to-private re-address is a real move and lands then.
      mac = unique_universal_mac()
      public_ip = unused_address(fn n -> "203.0.113.#{rem(n, 250) + 1}" end)
      private_ip = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, public_ip)], actor: actor)
      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, private_ip)], actor: actor)
      assert device_ip_for_mac(mac, actor) == public_ip

      age_primary_sighting!(mac)
      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, private_ip)], actor: actor)

      assert device_ip_for_mac(mac, actor) == private_ip,
             "a re-IP was refused after the old address left the window; devices would freeze"
    end

    test "a dual-stack census snapshot keeps the usable IPv4 primary", %{actor: actor} do
      # The flip: the census emitted one sighting per address, the batch kept the
      # last, and the guard tied a global IPv6 (rank 50) with a private IPv4 (40).
      mac = unique_universal_mac()
      ipv4 = unused_private_ip()
      ipv6 = unused_address(fn n -> "2001:db8::#{Integer.to_string(n, 16)}" end)

      link_local =
        "fe80::a8ff:fe00:#{Integer.to_string(rem(System.unique_integer([:positive]), 65_535), 16)}"

      assert :ok =
               SyncIngestor.ingest_updates(census_snapshot(mac, [ipv4, link_local, ipv6]),
                 actor: actor
               )

      assert :ok =
               SyncIngestor.ingest_updates(census_snapshot(mac, [ipv6, ipv4, link_local]),
                 actor: actor
               )

      device = device_row_for_mac(mac)
      assert device.ip == ipv4
      assert device.name == ipv4
      assert MapSet.subset?(MapSet.new([ipv4, ipv6]), live_ip_aliases(device.uid))
      refute MapSet.member?(live_ip_aliases(device.uid), link_local)
    end

    test "a census snapshot listing only the IPv6 keeps the IPv4 until it leaves the window", %{
      actor: actor
    } do
      # The ARP row aged out of the census while NDP still lists the device. The
      # IPv4 is absent from a complete snapshot, but an absence takes a weaker class
      # only after the window; otherwise the next full snapshot flips it back.
      mac = unique_universal_mac()
      ipv4 = unused_private_ip()
      ipv6 = unused_address(fn n -> "2001:db8::#{Integer.to_string(n, 16)}" end)

      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [ipv4, ipv6]), actor: actor)
      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [ipv6]), actor: actor)

      assert device_ip_for_mac(mac, actor) == ipv4,
             "a census snapshot without the ARP row moved a usable IPv4 primary to the IPv6"

      age_primary_sighting!(mac)
      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [ipv6]), actor: actor)

      assert device_ip_for_mac(mac, actor) == ipv6
    end

    test "absence takes the same or a stronger class, never a weaker one, in SQL and Elixir" do
      # {stored, incoming, weaker class?}: classes are usable IPv4, routable IPv6,
      # link-local; a same-class re-IP is never a downgrade.
      cases = [
        {"192.168.0.3", "2001:db8::3", true},
        {"203.0.113.5", "10.1.0.5", false},
        {"10.1.0.5", "203.0.113.5", false},
        {"2001:db8::5", "fd00::5", false},
        {"2001:db8::5", "fe80::5", true},
        {"192.0.2.3", "169.254.1.3", true},
        {"169.254.1.9", "fe80::9", false},
        {"2001:db8::3", "192.168.0.3", false}
      ]

      %{rows: rows} =
        Repo.query!(
          """
          SELECT s, i,
                 platform.sr_address_strength(i) / 100 < platform.sr_address_strength(s) / 100
          FROM unnest($1::text[], $2::text[]) AS c(s, i)
          """,
          [Enum.map(cases, &elem(&1, 0)), Enum.map(cases, &elem(&1, 1))]
        )

      sql = Map.new(rows, fn [stored, incoming, weaker?] -> {{stored, incoming}, weaker?} end)

      wrong =
        for {stored, incoming, expected} <- cases,
            Map.fetch!(sql, {stored, incoming}) != expected or
              Address.class_downgrade?(incoming, stored) != expected,
            do: {stored, incoming, expected}

      assert wrong == [], "class downgrade disagrees for #{inspect(wrong)}"
    end

    test "another source reporting a different IPv4 does not move the primary", %{actor: actor} do
      mac = unique_universal_mac()
      census_ip = unused_private_ip()
      other_ip = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [census_ip]), actor: actor)
      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, other_ip)], actor: actor)

      assert device_ip_for_mac(mac, actor) == census_ip
    end

    test "two NICs both sighted keep the first primary, in either order", %{actor: actor} do
      mac = unique_universal_mac()
      # The stored primary is the higher address, so the batch's lowest-address
      # tie-break alone would move it.
      first = unused_address(fn n -> "198.51.100.#{rem(n, 250) + 1}" end)
      second = unused_address(fn n -> "192.0.2.#{rem(n, 250) + 1}" end)

      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [first]), actor: actor)

      assert :ok =
               SyncIngestor.ingest_updates(census_snapshot(mac, [second, first]), actor: actor)

      assert device_ip_for_mac(mac, actor) == first

      assert :ok =
               SyncIngestor.ingest_updates(census_snapshot(mac, [first, second]), actor: actor)

      assert device_ip_for_mac(mac, actor) == first
    end

    test "a census re-IP replaces once the census no longer sights the old address", %{
      actor: actor
    } do
      mac = unique_universal_mac()
      old_ip = unused_private_ip()
      new_ip = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [old_ip]), actor: actor)
      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [new_ip]), actor: actor)

      assert device_ip_for_mac(mac, actor) == new_ip
    end

    test "a census snapshot with a higher-rank IPv4 moves a private primary", %{actor: actor} do
      mac = unique_universal_mac()
      private_ip = unused_private_ip()
      public_ip = unused_address(fn n -> "203.0.113.#{rem(n, 250) + 1}" end)

      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [private_ip]), actor: actor)

      assert :ok =
               SyncIngestor.ingest_updates(census_snapshot(mac, [public_ip, private_ip]),
                 actor: actor
               )

      assert device_ip_for_mac(mac, actor) == public_ip
    end

    test "an IPv6-only device that gains a usable IPv4 switches primary", %{actor: actor} do
      mac = unique_universal_mac()
      ipv4 = unused_private_ip()
      ipv6 = unused_address(fn n -> "2001:db8::#{Integer.to_string(n, 16)}" end)

      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [ipv6]), actor: actor)
      assert device_ip_for_mac(mac, actor) == ipv6

      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [ipv4, ipv6]), actor: actor)

      device = device_row_for_mac(mac)
      assert device.ip == ipv4
      assert MapSet.member?(live_ip_aliases(device.uid), ipv6)
    end

    test "a ULA still cannot overwrite a routable primary", %{actor: actor} do
      mac = unique_universal_mac()
      routable = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, routable)], actor: actor)

      assert :ok =
               SyncIngestor.ingest_updates(
                 [mac_update(mac, "fd2f:420a:24b1:1:f692:bfff:fe75:c7ef")],
                 actor: actor
               )

      assert device_ip_for_mac(mac, actor) == routable,
             "a ULA clobbered a routable primary"
    end

    test "a routable address promotes a link-local primary", %{actor: actor} do
      mac = unique_universal_mac()
      link_local = "fe80::f692:bfff:fe75:c7ab"
      routable = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, link_local)], actor: actor)
      assert device_ip_for_mac(mac, actor) == link_local

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, routable)], actor: actor)

      assert device_ip_for_mac(mac, actor) == routable,
             "a routable address did not promote over a link-local primary"
    end

    test "a device with only link-local addresses keeps one", %{actor: actor} do
      # 8 of the 18 affected devices have no routable address at all. Leaving
      # them with no address would trade a poor answer for none.
      mac = unique_universal_mac()

      assert :ok =
               SyncIngestor.ingest_updates(
                 [mac_update(mac, "fe80::f692:bfff:fe75:c7cd")],
                 actor: actor
               )

      assert :ok =
               SyncIngestor.ingest_updates(
                 [mac_update(mac, "fe80::f692:bfff:fe75:c7ce")],
                 actor: actor
               )

      assert device_ip_for_mac(mac, actor) in [
               "fe80::f692:bfff:fe75:c7cd",
               "fe80::f692:bfff:fe75:c7ce"
             ]
    end
  end

  describe "a link-local-only device" do
    test "keeps its link-local primary with no name until a routable address arrives", %{
      actor: actor
    } do
      mac = unique_universal_mac()
      suffix = Integer.to_string(rem(System.unique_integer([:positive]), 65_535), 16)
      fe80 = "fe80::a8ff:fe01:#{suffix}"

      apipa =
        unused_address(fn n -> "169.254.#{rem(div(n, 250), 250) + 1}.#{rem(n, 250) + 1}" end)

      routable = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [fe80]), actor: actor)
      assert %{ip: ^fe80, name: nil} = device_row_for_mac(mac)

      # fe80:: and 169.254/16 are equally strong: neither displaces the other.
      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [apipa, fe80]), actor: actor)
      assert :ok = SyncIngestor.ingest_updates(census_snapshot(mac, [fe80, apipa]), actor: actor)
      assert %{ip: ^fe80, uid: uid} = device_row_for_mac(mac)
      assert live_ip_aliases(uid) == MapSet.new()

      assert :ok =
               SyncIngestor.ingest_updates(census_snapshot(mac, [fe80, routable]), actor: actor)

      assert device_ip_for_mac(mac, actor) == routable
    end
  end

  describe "an address replaced by a sync" do
    # The replaced address is kept as an alias in the transaction that replaces it. Had the
    # replacement committed without its alias, the old address would be recorded nowhere, and a
    # replay would read the new address as the held one. The alias table refuses inserts here,
    # and a trigger is DDL, so this case runs in this serial module.
    test "an alias write that fails rolls the replacement back", %{actor: actor} do
      integration_id = "integration-#{System.unique_integer([:positive])}"
      {held_ip, declared_ip} = doc_ip_pair()

      assert :ok =
               SyncIngestor.ingest_updates(
                 [integration_update(integration_id, held_ip, "node03")],
                 actor: actor
               )

      uid = device_uid_for_integration!(integration_id, actor)
      refuse_alias_inserts!()

      assert {:error, _reason} =
               SyncIngestor.ingest_updates(
                 [integration_update(integration_id, declared_ip, "node03")],
                 actor: actor
               )

      assert {:ok, %Device{ip: ^held_ip}} = Device.get_by_uid(uid, false, actor: actor)
      assert {:ok, []} = DeviceAliasState.lookup_for_device(uid, :ip, held_ip, actor: actor)
    end
  end

  # The trigger is created in the test's sandbox transaction, which is rolled back. The on_exit
  # drop runs before that, pass or fail, and removes it even where the test is not sandboxed.
  defp refuse_alias_inserts! do
    name = "refuse_alias_insert_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION platform.#{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'alias insert refused'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{name} BEFORE INSERT ON platform.device_alias_states
    FOR EACH ROW EXECUTE FUNCTION platform.#{name}()
    """)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON platform.device_alias_states")
      Repo.query!("DROP FUNCTION IF EXISTS platform.#{name}()")
    end)
  end

  # `sweep` is a mapper_like_source?, so SourcePolicy.include_mac_identifier?/1
  # only admits the MAC when identity_mac_kind names a real chassis address --
  # without it the MAC is an observation and no device is keyed by it.
  defp mac_update(mac, ip) do
    %{
      "ip" => ip,
      "mac" => mac,
      "source" => "sweep",
      "metadata" => %{
        "identity_mac" => mac,
        "identity_mac_kind" => "primary"
      }
    }
  end

  # One complete census snapshot of `mac` at `ips`, through the real decoder, stamped
  # the way DiscoveryIngestor stamps a census payload.
  defp census_snapshot(mac, ips) do
    now = System.os_time(:nanosecond)

    observations =
      Enum.map(ips, fn ip ->
        %DeviceCensusObservation{
          mac: String.downcase(mac),
          ip: ip,
          kind:
            if(String.contains?(ip, ":"),
              do: :DEVICE_CENSUS_KIND_IPV6_NDP,
              else: :DEVICE_CENSUS_KIND_ARP_REPLY
            ),
          interface_index: 2,
          first_seen_unix_nano: now - 60_000_000_000,
          last_seen_unix_nano: now
        }
      end)

    {:ok, rows, _stats} =
      %DeviceCensusSnapshot{
        observations: observations,
        snapshot_id: "eth0-#{now}",
        interface_name: "eth0",
        generated_at_unix_nano: now,
        complete: true,
        chunk_count: 1
      }
      |> DeviceCensusSnapshot.encode()
      |> Decoders.Census.decode()

    Enum.map(rows, fn row ->
      row
      |> Map.put("source", "netprobe-census")
      |> Map.update!("metadata", fn metadata ->
        Map.merge(metadata, %{
          "identity_source" => "netprobe_census",
          "discovery_source" => "netprobe-census",
          "source" => "netprobe-census"
        })
      end)
    end)
  end

  defp device_row_for_mac(mac) do
    normalized = mac |> String.replace(":", "") |> String.upcase()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT d.uid, d.ip, d.name
        FROM platform.ocsf_devices d
        JOIN platform.device_identifiers i ON i.device_id = d.uid
        WHERE i.identifier_type = 'mac' AND i.identifier_value = $1
        """,
        [normalized]
      )

    assert [[uid, ip, name]] = rows
    %{uid: uid, ip: ip, name: name}
  end

  defp live_ip_aliases(uid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT alias_value FROM platform.device_alias_states
        WHERE device_id = $1 AND alias_type = 'ip'
          AND state IN ('detected', 'confirmed', 'updated')
        """,
        [uid]
      )

    MapSet.new(rows, fn [value] -> value end)
  end

  # The window is measured from the recording source's last sighting.
  defp age_primary_sighting!(mac) do
    %{uid: uid} = device_row_for_mac(mac)

    Repo.query!(
      "UPDATE platform.ocsf_devices SET ip_seen_at = now() - interval '30 days' WHERE uid = $1",
      [uid]
    )
  end

  defp unused_address(build) do
    fn -> System.unique_integer([:positive, :monotonic]) end
    |> Stream.repeatedly()
    |> Enum.find_value(fn n ->
      ip = build.(n)

      case Repo.query("SELECT 1 FROM platform.ocsf_devices WHERE ip = $1 LIMIT 1", [ip]) do
        {:ok, %{rows: []}} -> ip
        _ -> nil
      end
    end)
  end

  # unique_test_ip/0 does not consult the database, so two of these tests drew
  # the same address and collided on ocsf_devices_unique_active_ip_idx.
  defp unused_private_ip do
    fn -> System.unique_integer([:positive, :monotonic]) end
    |> Stream.repeatedly()
    |> Enum.find_value(fn n ->
      ip = "10.#{rem(div(n, 65_025), 250) + 1}.#{rem(div(n, 255), 250) + 1}.#{rem(n, 250) + 1}"

      case Repo.query("SELECT 1 FROM platform.ocsf_devices WHERE ip = $1 LIMIT 1", [ip]) do
        {:ok, %{rows: []}} -> ip
        _ -> nil
      end
    end)
  end

  defp device_ip_for_mac(mac, actor) do
    normalized = mac |> String.replace(":", "") |> String.upcase()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT d.ip
        FROM platform.ocsf_devices d
        JOIN platform.device_identifiers i ON i.device_id = d.uid
        WHERE i.identifier_type = 'mac' AND i.identifier_value = $1
        """,
        [normalized]
      )

    case rows do
      [[ip]] ->
        ip

      other ->
        flunk(
          "expected exactly one device for #{mac}, got #{inspect(other)} (actor #{inspect(actor)})"
        )
    end
  end

  defp unique_universal_mac do
    [:positive]
    |> System.unique_integer()
    |> Integer.to_string(16)
    |> String.pad_leading(10, "0")
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&("A8:" <> &1))
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

  # Two addresses in 198.18.0.0/15 from one monotonic draw, one in each /16, so they never
  # equal each other or wrap onto another test's pair.
  defp seed_ip_pair do
    n = System.unique_integer([:positive, :monotonic])
    host = "#{rem(div(n, 254), 254) + 1}.#{rem(n, 254) + 1}"
    {"198.18." <> host, "198.19." <> host}
  end

  # An Armis sync observed at `ip`, stamped `offset` seconds from now.
  defp armis_update(armis_id, ip, offset) do
    %{
      "ip" => ip,
      "hostname" => "armis-4705",
      "source" => "armis",
      "last_seen_time" => DateTime.to_iso8601(DateTime.shift(DateTime.utc_now(), second: offset)),
      "metadata" => %{"integration_type" => "armis", "armis_device_id" => armis_id}
    }
  end

  # The #4705 move: an Armis device synced at one address is synced again at the address of a
  # sweep seed. `anchor` gives the seed whatever it has beyond the address before the move.
  # Asserts the device took the address and the conflict was recorded, and returns the seed as
  # the move left it, deleted or not, with the seed_released events and invalidation hints the
  # move emitted waiting in the mailbox.
  defp move_onto_seed!(actor, seed_attrs \\ %{}, anchor \\ fn _seed -> :ok end) do
    {old_ip, new_ip} = seed_ip_pair()
    armis_id = "armis-4705-#{System.unique_integer([:positive])}"

    assert :ok = SyncIngestor.ingest_updates([armis_update(armis_id, old_ip, 0)], actor: actor)
    device_uid = device_uid_for_armis!(armis_id, actor)

    seed =
      create_device!(
        actor,
        nil,
        new_ip,
        Map.merge(
          %{
            uid: "sr:" <> Ecto.UUID.generate(),
            discovery_sources: ["sweep"],
            metadata: %{"identity_state" => "provisional", "identity_source" => "sweep_ip_seed"}
          },
          seed_attrs
        )
      )

    anchor.(seed)

    handler_id = "seed-released-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :inventory, :seed_released],
        &__MODULE__.forward_seed_released/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, DevicePubSub.invalidation_topic())

    assert :ok = SyncIngestor.ingest_updates([armis_update(armis_id, new_ip, 60)], actor: actor)

    assert device_uid_for_armis!(armis_id, actor) == device_uid
    {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
    assert device.ip == new_ip

    decisions =
      IdentityDecision
      |> Ash.Query.filter(decision_kind == :ip_conflict and subject == ^new_ip)
      |> Ash.read!(actor: actor)

    assert Enum.any?(decisions, &(Enum.sort(&1.device_uids) == Enum.sort([device_uid, seed.uid])))

    {:ok, seed} = Device.get_by_uid(seed.uid, true, actor: actor)
    assert seed.ip == nil
    seed
  end

  # A single-batch ingest runs in its caller, so only this test's own events are forwarded.
  @doc false
  def forward_seed_released(_event, measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:seed_released, measurements, metadata})
  end

  defp assert_seed_kept(seed) do
    assert is_nil(seed.deleted_at)
    assert is_nil(seed.deleted_reason)
    refute_received {:seed_released, _measurements, _metadata}
  end

  defp register_mac!(device, actor) do
    mac = String.replace(unique_universal_mac(), ":", "")

    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:upsert, %{
        device_id: device.uid,
        identifier_type: :mac,
        identifier_value: mac,
        partition: "default",
        confidence: :strong,
        source: "test"
      })
      |> Ash.create(actor: actor)

    mac
  end

  defp detect_alias!(device, ip, actor) do
    {:ok, _alias_state} =
      DeviceAliasState.create_detected(
        %{
          device_id: device.uid,
          partition: "default",
          alias_type: :ip,
          alias_value: ip,
          metadata: %{}
        },
        actor: actor
      )
  end

  defp device_uid_for_armis!(armis_id, actor) do
    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type == :armis_device_id and identifier_value == ^armis_id)
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: uid}] = List.wrap(identifiers)
    uid
  end

  # Monotonic, not a random draw: the hash-of-a-UUID version could repeat, and a repeated
  # address is indistinguishable from the conflict this file exists to test.
  defp unique_test_ip do
    n = System.unique_integer([:positive, :monotonic])
    "100.124.#{rem(div(n, 254), 254) + 1}.#{rem(n, 254) + 1}"
  end

  # Documentation-range pair from a single monotonic draw. The two addresses
  # are in different /24s, so they can never equal each other: an intra-test
  # collision is always the conflict under test, never the fixture.
  defp doc_ip_pair do
    n = System.unique_integer([:positive, :monotonic])
    {"203.0.113.#{rem(n, 254) + 1}", "198.51.100.#{rem(n, 254) + 1}"}
  end

  defp create_device!(actor, hostname, ip, extra \\ %{}) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{uid: "sr:4357-#{Ecto.UUID.generate()}", hostname: hostname, ip: ip}, extra)
      )
      |> Ash.create(actor: actor)

    device
  end

  defp ip_taken_error?(error) do
    fields = List.wrap(Map.get(error, :fields) || []) ++ List.wrap(Map.get(error, :field))
    :ip in fields and Map.get(error, :message) == "has already been taken"
  end

  # A revivable tombstone that still stores `ip`, and the live device that took
  # the address after the tombstone was deleted.
  defp tombstone_with_taken_address!(ip, actor) do
    tombstone = create_device!(actor, "revival-tombstone", ip)

    Repo.query!(
      "UPDATE platform.ocsf_devices SET deleted_at = now(), deleted_reason = $2 WHERE uid = $1",
      [tombstone.uid, "no_armis_source"]
    )

    {tombstone, create_device!(actor, "revival-live-holder", ip)}
  end

  # The field set a sync batch's device records carry, with synthetic values.
  defp upsert_record(uid, ip) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    %{
      uid: uid,
      partition: "default",
      ip: ip,
      mac: nil,
      hostname: "revival-tombstone",
      name: "revival-tombstone",
      type: "host",
      type_id: 0,
      vendor_name: nil,
      model: nil,
      os: %{},
      hw_info: %{},
      network_interfaces: [],
      is_available: true,
      is_managed: false,
      is_active: true,
      owner: nil,
      metadata: %{},
      tags: %{},
      discovery_sources: ["integration-test"],
      first_seen_time: now,
      last_seen_time: now,
      created_time: now,
      modified_time: now
    }
  end

  # Counts active-IP prechecks. On the first, a competing device takes `ip` inside
  # the fenced write, so the batch's insert hits the unique active-IP index; the
  # competitor rolls back with that attempt, so only a retried attempt can land.
  defp take_address_on_first_precheck(ip, actor) do
    prechecks = :atomics.new(1, signed: false)

    put_test_env(:device_writes_test_hooks, %{
      after_active_ip_precheck: fn ->
        if :atomics.add_get(prechecks, 1, 1) == 1 do
          create_device!(actor, "competing-holder", ip)
        end

        :ok
      end
    })

    prechecks
  end

  defp put_test_env(key, value) do
    previous = Application.fetch_env(:serviceradar_core, key)
    Application.put_env(:serviceradar_core, key, value)

    on_exit(fn ->
      case previous do
        {:ok, previous_value} -> Application.put_env(:serviceradar_core, key, previous_value)
        :error -> Application.delete_env(:serviceradar_core, key)
      end
    end)
  end
end

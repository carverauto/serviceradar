defmodule ServiceRadarWebNG.Topology.BitmapReplicaLifecycleDBTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.FleetIdentity
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.NetworkDiscovery.World
  alias ServiceRadar.Repo
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.BitmapExpression
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapPublisher
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldLoader

  @moduletag :topology_atlas_db
  @moduletag timeout: 180_000
  @actor SystemActor.system(:bitmap_replica_lifecycle_test)
  @authority <<23::256>>

  setup context do
    # Only the replica/late-commit cases need independent committed connections.
    if context[:sandbox] == :unboxed do
      ServiceRadar.TestSupport.checkout_repo!(context)
    else
      # BitmapPublisher sets REPEATABLE READ inside its transaction, which a boxed
      # sandbox runs as a savepoint. PostgreSQL accepts that only when the level is
      # unchanged, so the shared owner opens the sandbox at the same level.
      opts = [shared: true, isolation: "REPEATABLE READ"]

      opts =
        case ServiceRadar.TestSupport.sandbox_ownership_timeout(context) do
          nil -> opts
          timeout -> Keyword.put(opts, :ownership_timeout, timeout)
        end

      owner = Sandbox.start_owner!(Repo, opts)
      on_exit(fn -> ServiceRadar.TestSupport.stop_repo_owner(owner, shared: true) end)
    end

    suffix = Ecto.UUID.generate()
    ids = Enum.map(~w(first second late higher restarted), &("sr:bitmap-replica-#{suffix}-" <> &1))
    vendor = "bitmap-replica-#{suffix}"

    previous =
      Map.new(
        [:god_view_enabled, :bitmap_tag_keys],
        &{&1, Application.fetch_env(:serviceradar_web_ng, &1)}
      )

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    Application.put_env(:serviceradar_web_ng, :bitmap_tag_keys, [])

    on_exit(fn ->
      try do
        if context[:sandbox] == :unboxed do
          Repo.query!("SELECT platform.refresh_device_inventory_rollups()")
          ServiceRadar.TestSupport.delete_device_fixtures!(ids)
        end
      after
        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
          {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
        end)
      end
    end)

    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})

    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: __MODULE__.IsolatedPubSub}, id: :isolated_pubsub))

    %{ids: ids, vendor: vendor}
  end

  @tag sandbox: :unboxed
  test "world loader resumes projection turns, leaves stable incomplete identities alone, yields pages to geometry, and detects late commits",
       %{
         ids: [first_id, _second_id, late_id, higher_id, unrelated_id],
         vendor: vendor
       } do
    prior_manifest = World.active_manifest(:system)
    prior_head = world_head_row()
    prior_layout = layout_stamp(prior_head)

    previous =
      case prior_manifest do
        {:ok, %{generation: generation}} -> generation
        {:error, :not_ready} -> 0
      end

    versions = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    [first_version, next_version] = versions
    padding = Enum.map(1..501, &"sr:loader-padding-#{vendor}-#{&1}")

    on_exit(fn ->
      # ExUnit has stopped the supervised loader/publisher before teardown.
      Enum.each(versions, &delete_staged_world/1)
      restore_world_head(prior_head, prior_layout)
      assert world_head_row() == prior_head
      assert World.active_manifest(:system) == prior_manifest

      for version <- versions do
        uuid = Ecto.UUID.dump!(version)

        assert %{num_rows: 0} =
                 Repo.query!(
                   "SELECT layout_version FROM platform.topology_world_layouts WHERE layout_version = $1",
                   [uuid]
                 )
      end

      Repo.query!("SELECT platform.refresh_device_inventory_rollups()")
      ServiceRadar.TestSupport.delete_device_fixtures!(padding)
    end)

    first = create(first_id, vendor, true)
    seed_padding(padding)
    first_ordinal = FleetIdentity.device_ordinal(first.uid)
    ids = [first_id, late_id]
    stage_world(first_version, ids)
    stage_world(next_version, ids)
    assert {:ok, %{generation: generation}} = World.activate_relayout(previous, first_version)
    assert generation > previous

    publisher_tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: :publisher_tasks))
    cache_tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 4}, id: :cache_tasks))
    loader_tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: :loader_tasks))

    owner =
      start_supervised!({BitmapIndex, name: BitmapIndex, task_supervisor: publisher_tasks, pubsub: ServiceRadar.PubSub})

    await_members(owner, vendor, [first_ordinal])
    cache = start_supervised!({WorldCache, task_supervisor: cache_tasks, pubsub: ServiceRadar.PubSub})
    observer = observe_loader_queries(loader_tasks)
    paging = observe_loader_queries(loader_tasks, true)
    loader = start_supervised!({WorldLoader, cache: cache, task_supervisor: loader_tasks, pubsub: ServiceRadar.PubSub})

    # The padded dictionary spans at least two pages. Each page is a separate
    # supervised turn that resumes from the owner's retained cursor.
    assert_receive {:loader_page, ^paging, disabled_turn, first_cursor}, 10_000

    # Disabling Atlas between pages releases the staged projection and returns
    # the loader to ordinary head polling instead of the page cadence.
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, false)
    release_page(paging, disabled_turn)
    await_task(disabled_turn)
    assert_receive {:loader_query, ^observer, disabled_check, :head, _} when disabled_check != disabled_turn, 10_000
    await_task(disabled_check)
    await_loader_idle(loader)
    assert is_nil(:sys.get_state(loader).projection)
    assert {:ok, %{ordinals: nil}} = WorldCache.world(cache)
    drain_loader_queries(observer)
    drain_loader_queries(paging)
    refute_receive {:loader_query, ^observer, _, :head, _}, 1_000

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    await_members(owner, vendor, [first_ordinal])
    send(loader, :refresh)
    assert_receive {:loader_page, ^paging, first_turn, ^first_cursor}, 10_000
    release_page(paging, first_turn)
    assert_receive {:loader_page, ^paging, second_turn, resumed_cursor}, 10_000
    assert second_turn != first_turn
    assert resumed_cursor != first_cursor

    # A cancelled turn keeps the staged cursor; the next turn polls the head
    # again and then retries the same page rather than restarting the scan.
    Process.exit(second_turn, :kill)
    assert_receive {:loader_page, ^paging, retry_turn, ^resumed_cursor}, 10_000
    assert retry_turn != second_turn
    assert_received {:loader_query, ^paging, ^retry_turn, :head, _}

    # Reproduce native completion without its worker's result message. The
    # dictionary padding has no geometry rows; the first device is this world's
    # only assigned identity. Sealing the real retained resource before killing
    # the paused worker must not trap its successor in sealed-page retries.
    staged = :sys.get_state(loader).projection
    assert {:ok, _} = TopologyAtlas.apply_ordinals(staged.world, staged.mapping, [{first_id, first_ordinal}])
    assert {:ok, %{ready: true}} = TopologyAtlas.seal_ordinals(staged.world, staged.mapping)
    Process.exit(retry_turn, :kill)
    :telemetry.detach(paging)
    expected = [first_ordinal, 0]
    {assignment, progress} = await_projection(cache, first_version, ids, expected)
    await_loader_idle(loader)
    drain_loader_queries(observer)

    # Cross the former 60s incomplete-map retry using the real owner timer. No
    # timestamp injection or configurable test-only polling interval is needed.
    stable = make_ref()
    Process.send_after(self(), {:stable_interval, stable}, 61_000)
    assert_receive {:stable_interval, ^stable}, 62_000
    send(loader, :refresh)
    assert_receive {:loader_query, ^observer, stable_task, :progress, _}, 10_000
    await_task(stable_task)
    await_loader_idle(loader)
    assert {^assignment, ^progress} = await_projection(cache, first_version, ids, expected)
    refute_receive {:loader_query, ^observer, _, :page, _}
    drain_loader_queries(observer)

    # Sequence allocation precedes commit: MAX alone misses this lower identity.
    # The higher commit also changes progress, so the elapsed first-world scan
    # becomes eligible again.
    {writer, token, _backend, late_ordinal} = hold_device_commit(late_id, vendor)

    try do
      # Hold a real completed 500-row source page while the normal publication
      # message reaches the owner. A second connection publishes the next world.
      barrier = observe_loader_queries(loader_tasks, true)
      higher = create(higher_id, vendor, true)
      higher_ordinal = FleetIdentity.device_ordinal(higher.uid)
      assert late_ordinal < higher_ordinal
      assert {:ok, {high_water, before_count} = before_progress} = BitmapSource.dictionary_progress()
      assert high_water == higher_ordinal
      send(loader, :refresh)
      assert_receive {:loader_query, ^barrier, paging_task, :page, 500}, 10_000

      try do
        assert {:ok, %{generation: next_generation}} = World.activate_relayout(generation, next_version)

        await_value(
          fn -> WorldCache.manifest(cache) end,
          &match?({:ok, %{observed_generation: ^next_generation, catching_up: true}}, &1)
        )
      after
        :telemetry.detach(barrier)
        release_page(barrier, paging_task)
      end

      await_task(paging_task)
      assert_receive {:loader_query, ^observer, ^paging_task, :page, 500}
      refute_receive {:loader_query, ^observer, ^paging_task, :page, _}
      await_projection(cache, next_version, ids, expected, before_progress)
      await_loader_idle(loader)
      drain_loader_queries(observer)

      send(writer.pid, {:commit, token})
      assert {:ok, :ok} = Task.await(writer, 10_000)
      after_progress = {high_water, before_count + 1}
      assert {:ok, ^after_progress} = BitmapSource.dictionary_progress()

      # The late commit becomes eligible once the next world's incomplete map
      # crosses the same real owner retry interval.
      late = make_ref()
      Process.send_after(self(), {:late_interval, late}, 61_000)
      assert_receive {:late_interval, ^late}, 62_000
      send(loader, :refresh)
      complete = [first_ordinal, late_ordinal]
      {complete_assignment, ^after_progress} = await_projection(cache, next_version, ids, complete, after_progress)
      await_loader_idle(loader)
      drain_loader_queries(observer)

      # A new identity outside this immutable, completely mapped world cannot
      # change any assignment. Poll the real owner without counting or paging it.
      create(unrelated_id, vendor, false)
      assert {:ok, {_higher_water, count}} = BitmapSource.dictionary_progress()
      assert count == before_count + 2
      send(loader, :refresh)
      assert_receive {:loader_query, ^observer, complete_task, :head, _}, 10_000
      await_task(complete_task)
      await_loader_idle(loader)
      assert {^complete_assignment, ^after_progress} = await_projection(cache, next_version, ids, complete)
      refute_receive {:loader_query, ^observer, _, :progress, _}
      refute_receive {:loader_query, ^observer, _, :page, _}
    after
      if Process.alive?(writer.pid), do: Task.shutdown(writer, :brutal_kill)
    end
  end

  test "one accepted revision combines current address sources, removes replacements, and fails explicitly on incomplete input",
       %{
         ids: [first_id, second_id | _],
         vendor: vendor
       } do
    first = create(first_id, vendor, true)
    second = create(second_id, vendor, true)
    Repo.update_all(from(d in Device, where: d.uid == ^first.uid), set: [ip: "192.0.2.7"])
    Repo.update_all(from(d in Device, where: d.uid == ^second.uid), set: [ip: "192.0.2.8"])
    first_ordinal = FleetIdentity.device_ordinal(first.uid)
    second_ordinal = FleetIdentity.device_ordinal(second.uid)

    create_resource(Interface, %{
      device_id: second.uid,
      interface_uid: "example-shared",
      timestamp: DateTime.utc_now(),
      ip_addresses: ["192.0.2.7"]
    })

    active_alias =
      DeviceAliasState
      |> Ash.Changeset.for_create(:detect, %{device_id: first.uid, alias_type: :ip, alias_value: "198.51.100.7"},
        actor: @actor
      )
      |> Ash.create!()

    interface =
      create_resource(Interface, %{
        device_id: first.uid,
        interface_uid: "example-port",
        timestamp: DateTime.utc_now(),
        ip_addresses: ["2001:db8::7", "192.0.2.9"]
      })

    host = create_resource(VirtualizationHost, %{provider: "example", provider_ref: first.uid, name: "Synthetic host"})

    nic =
      create_resource(VirtualizationNetworkInterface, %{
        provider: "example",
        provider_ref: first.uid,
        name: "example-nic",
        host_id: host.id,
        device_uid: first.uid,
        exists: true,
        active: false,
        address: "203.0.113.7/24",
        ip_addresses: []
      })

    {:ok, info} = BitmapSource.initialize()
    epoch = <<42::128>>
    {:ok, index} = Native.bitmap_index_new(info.dictionary_epoch, epoch, :device, info.supported_facets)
    current = Map.merge(info, %{device: index, index_epoch: epoch})
    on_exit(fn -> Native.bitmap_index_close(index) end)
    ordinals = [first_ordinal, second_ordinal]

    assert {:ok, _} = publish_addresses(current, ordinals, 1)

    for {cidr, expected} <- [
          {"192.0.2.7", Enum.sort(ordinals)},
          {"192.0.2.8", [second_ordinal]},
          {"192.0.2.9", [first_ordinal]},
          {"198.51.100.7", [first_ordinal]},
          {"2001:db8::/64", [first_ordinal]},
          {"203.0.113.7", [first_ordinal]},
          {"203.0.113.0", []}
        ] do
      assert {:ok, ^expected} = address_members(current, cidr)
    end

    active_alias |> Ash.Changeset.for_update(:mark_stale, %{}, actor: @actor) |> Ash.update!()
    Ash.destroy!(interface, actor: @actor)
    nic |> Ash.Changeset.for_update(:update, %{exists: false}, actor: @actor) |> Ash.update!()
    assert {:ok, _} = publish_addresses(current, [first_ordinal], 2)

    for cidr <- ["192.0.2.9", "198.51.100.7", "2001:db8::7", "203.0.113.7"] do
      assert {:ok, []} = address_members(current, cidr)
    end

    page_addresses = Enum.map(1..0x1F5, &"2001:db8::#{Integer.to_string(&1, 16)}")

    Repo.query!(
      "INSERT INTO platform.discovered_interfaces (device_id, interface_uid, timestamp, ip_addresses) VALUES ($1, 'example-page', now(), $2::text[])",
      [first.uid, page_addresses]
    )

    assert {:ok, _} = publish_addresses(current, [first_ordinal], 3)

    for address <- page_addresses do
      assert {:ok, [^first_ordinal]} = address_members(current, address <> "/128")
    end

    Repo.query!(
      "DELETE FROM platform.discovered_interfaces WHERE device_id = $1 AND interface_uid = 'example-page'",
      [first.uid]
    )

    assert {:ok, _} = publish_addresses(current, [first_ordinal], 4)

    for address <- page_addresses do
      assert {:ok, []} = address_members(current, address <> "/128")
    end

    assert {:ok, primary} = address_members(current, "192.0.2.7")
    assert primary == Enum.sort(ordinals)

    Repo.query!(
      "INSERT INTO platform.discovered_interfaces (device_id, interface_uid, timestamp, ip_addresses) VALUES ($1, 'example-cap', now(), $2::text[])",
      [first.uid, List.duplicate("192.0.2.99", 4_097)]
    )

    assert {:ok, _} = publish_addresses(current, [first_ordinal], 5)
    assert {:error, "ip_unavailable"} = address_members(current, "192.0.2.7")
    Repo.update_all(from(d in Device, where: d.uid == ^second.uid), set: [vendor_name: "example-updated"])
    assert {:ok, _} = publish_addresses(current, [second_ordinal], 6)
    assert {:error, "ip_unavailable"} = address_members(current, "192.0.2.7")
    assert {:ok, [^second_ordinal]} = selected_members(current, %{"facet" => "vendor", "value" => "example-updated"})
    assert {:ok, %{ready: true, ip_available: false}} = Native.bitmap_index_status(index)
  end

  @tag sandbox: :unboxed
  test "independent publishers recover missed notifications, late commits behind the cursor, and a cold restart", %{
    ids: [first_id, second_id, late_id, higher_id, restarted_id],
    vendor: vendor
  } do
    first = create(first_id, vendor, true)
    second = create(second_id, vendor, false)
    one = start_replica(:one, ServiceRadar.PubSub)
    two = start_replica(:two, __MODULE__.IsolatedPubSub)
    first_ordinal = FleetIdentity.device_ordinal(first.uid)
    second_ordinal = FleetIdentity.device_ordinal(second.uid)
    await_members(one, vendor, [first_ordinal])
    await_members(two, vendor, [first_ordinal])

    set_available(first, false)
    set_available(second, true)
    await_members(one, vendor, [second_ordinal])
    # This publisher never subscribes to the notifier's PubSub. It must converge
    # through its production periodic keyset scan without an injected rescan event.
    await_members(two, vendor, [second_ordinal])

    [[reader_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    {writer, token, writer_backend, late_ordinal} = hold_device_commit(late_id, vendor)

    try do
      refute reader_backend == writer_backend
      assert is_integer(late_ordinal) and late_ordinal > 0
      higher = create(higher_id, vendor, true)
      higher_ordinal = FleetIdentity.device_ordinal(higher.uid)
      assert late_ordinal < higher_ordinal
      assert nil == FleetIdentity.device_ordinal(late_id)

      # Observing the higher ordinal on the isolated publisher proves its scan
      # passed the uncommitted identity. Allocation order is not commit order.
      await_members(two, vendor, [second_ordinal, higher_ordinal])
      send(writer.pid, {:commit, token})
      assert {:ok, :ok} = Task.await(writer, 10_000)
      expected = Enum.sort([second_ordinal, late_ordinal, higher_ordinal])
      await_members(one, vendor, expected)
      await_members(two, vendor, expected)

      {:ok, previous} = BitmapIndex.snapshot(two)
      :ok = stop_supervised({:replica, :two})
      assert {:ok, %{ready: false, cardinality: 0}} = Native.bitmap_index_status(previous.device)
      restarted = create(restarted_id, vendor, true)
      replacement = start_owner(:two, __MODULE__.IsolatedPubSub, __MODULE__.TwoTasks)
      await_members(replacement, vendor, Enum.sort([FleetIdentity.device_ordinal(restarted.uid) | expected]))
      {:ok, current} = BitmapIndex.snapshot(replacement)
      assert current.dictionary_epoch == previous.dictionary_epoch
      refute current.index_epoch == previous.index_epoch
    after
      if Process.alive?(writer.pid), do: Task.shutdown(writer, :brutal_kill)
    end
  end

  @tag sandbox: :unboxed
  test "publisher contention keeps pending updates without reporting a source failure", %{
    ids: [first_id | _],
    vendor: vendor
  } do
    first = create(first_id, vendor, true)
    owner = start_replica(:one, ServiceRadar.PubSub)
    ordinal = FleetIdentity.device_ordinal(first.uid)
    await_members(owner, vendor, [ordinal])

    {:ok, current} =
      await_value(fn -> BitmapIndex.snapshot(owner) end, fn
        {:ok, %{progress: %{pending_dirty: 0, reconciling: false}}} -> true
        _ -> false
      end)

    {:ok, held_stage} =
      await_value(
        fn ->
          with {:ok, status} <- Native.bitmap_index_status(current.device) do
            Native.bitmap_index_begin_publish(current.device, status.revision, <<99::64>>, [], true)
          end
        end,
        &match?({:ok, _}, &1)
      )

    handler = {__MODULE__, :publisher_contention, make_ref()}
    event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _timings, metadata, test_owner ->
          if String.upcase(to_string(metadata.query)) == "ROLLBACK" and
               self() in Task.Supervisor.children(__MODULE__.OneTasks) do
            send(test_owner, {:publisher_rollback, handler, self()})
          end
        end,
        self()
      )

    try do
      set_available(first, false)

      for _ <- 1..2 do
        assert_receive {:publisher_rollback, ^handler, task}, 10_000
        await_task(task)
      end

      assert {:ok, %{progress: progress}} = BitmapIndex.snapshot(owner)
      refute progress.source_error
      refute progress.reconciling
      assert progress.pending_dirty > 0
      assert {:ok, [^ordinal]} = members(owner, vendor)
    after
      :telemetry.detach(handler)
      Native.bitmap_publish_abort(held_stage)
    end

    # Recovery comes from the retained work, before the ordinary 30-second scan.
    await_members(owner, vendor, [], System.monotonic_time(:millisecond) + 10_000)
  end

  test "a capacity-rejected page does not prevent later deletions from restoring publication", %{vendor: vendor} do
    keys = Enum.map(1..25, &"capacity-#{&1}")
    Application.put_env(:serviceradar_web_ng, :bitmap_tag_keys, keys)
    Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")

    rows =
      for n <- 1..1_000 do
        %{
          uid: "sr:#{vendor}-capacity-#{n}",
          vendor_name: vendor,
          is_available: true,
          tags: if(n <= 500, do: %{}, else: capacity_tags(keys, n))
        }
      end

    {1_000, _} = Repo.insert_all(Device, rows)
    owner = start_replica(:one, __MODULE__.IsolatedPubSub)

    {:ok, current} =
      await_value(fn -> BitmapIndex.snapshot(owner) end, fn
        {:ok, %{progress: %{reconciling: false}}} -> true
        _ -> false
      end)

    # Pause only the BEAM owner while filling its real native resource through
    # the publication API. Extra synthetic ordinals occupy the unchanged native
    # budget without requiring a large database fixture or a test-only limit.
    :ok = :sys.suspend(owner)

    try do
      await_value(fn -> Task.Supervisor.children(__MODULE__.OneTasks) end, &(&1 == []))
      {first, deleted} = Enum.split(rows, 500)

      for {row, n} <- Enum.with_index(first, 1) do
        Repo.update_all(from(d in Device, where: d.uid == ^row.uid), set: [tags: capacity_tags(keys, n)])
      end

      deleted_ids = Enum.map(deleted, & &1.uid)
      {500, _} = Repo.update_all(from(d in Device, where: d.uid in ^deleted_ids), set: [deleted_at: DateTime.utc_now()])
      filled = fill_index_capacity(current)
      first_ids = Enum.map(first, & &1.uid)
      {:ok, ordinals} = BitmapSource.resolve_ids(first_ids)

      # Establish that this exact source page really is refused under pressure;
      # the owner must get past it to discover the later tombstones.
      assert {:error, {:capacity, %{rows: refused}}} = publish_addresses(current, ordinals, 77)
      assert length(refused) == 500
      assert {:ok, unchanged} = Native.bitmap_index_status(current.device)
      assert unchanged.revision == filled.revision
      send(owner, :devices_rescan)
      :ok = :sys.resume(owner)

      await_value(fn -> BitmapIndex.snapshot(owner) end, fn
        {:ok, %{progress: %{capacity_blocked: true, source_error: true}}} -> true
        _ -> false
      end)

      # With the old retry-at-the-same-cursor behavior, none of these later
      # deletions are published and this observable cardinality never falls.
      await_value(fn -> Native.bitmap_index_status(current.device) end, fn
        {:ok, %{cardinality: count}} -> count == filled.cardinality - 500
        _ -> false
      end)

      send(owner, :devices_rescan)

      await_value(fn -> BitmapIndex.snapshot(owner) end, fn
        {:ok, %{progress: progress}} ->
          not progress.capacity_blocked and not progress.source_error and not progress.reconciling and
            progress.pending_dirty == 0 and progress.last_reconciled_at != current.progress.last_reconciled_at

        _ ->
          false
      end)

      assert {:ok, [first_ordinal]} = BitmapSource.resolve_ids([hd(first).uid])

      assert {:ok, [^first_ordinal]} =
               selected_members(current, %{"facet" => "tag:capacity-1", "value" => capacity_tags(keys, 1)["capacity-1"]})
    after
      :sys.resume(owner)
    end
  end

  defp capacity_tags(keys, n), do: Map.new(keys, &{&1, String.pad_trailing("#{&1}-#{n}-", 200, "x")})

  defp fill_index_capacity(current) do
    attrs = Enum.map(current.supported_facets, &{&1, "capacity-padding"})
    {:ok, initial} = Native.bitmap_index_status(current.device)

    0..65_535
    |> Enum.chunk_every(500)
    |> Enum.reduce_while(initial, fn batch, previous ->
      rows = Enum.map(batch, &{&1 * 65_536 + 65_535, true, attrs})

      case Native.bitmap_index_publish(current.device, previous.revision, "capacity-#{hd(batch)}", rows, true) do
        {:ok, status} -> {:cont, status}
        {:error, "native_memory_budget"} -> {:halt, {:full, previous}}
        error -> flunk("unexpected capacity fixture result: #{inspect(error)}")
      end
    end)
    |> case do
      {:full, status} -> status
      _ -> flunk("synthetic sparse postings did not reach the native memory budget")
    end
  end

  defp hold_device_commit(uid, vendor) do
    parent = self()
    token = make_ref()

    writer =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: 120_000)

        try do
          Repo.transaction(
            fn ->
              # Keep identity triggers active, but avoid the singleton rollup
              # lock so a second transaction can commit its higher ordinal.
              Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")

              Repo.query!(
                "INSERT INTO platform.ocsf_devices (uid, vendor_name, is_available) VALUES ($1, $2, true)",
                [uid, vendor]
              )

              [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:allocated_uncommitted, token, backend, FleetIdentity.device_ordinal(uid)})

              receive do
                {:commit, ^token} -> :ok
              after
                90_000 -> raise "late-commit fixture was not released"
              end
            end,
            timeout: 100_000
          )
        after
          Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:allocated_uncommitted, ^token, backend, ordinal}, 10_000
    {writer, token, backend, ordinal}
  end

  defp seed_padding(ids) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")

      Enum.each(Enum.chunk_every(ids, 500), fn page ->
        Repo.query!(
          "INSERT INTO platform.ocsf_devices (uid, vendor_name) SELECT uid, 'invented-padding' FROM unnest($1::text[]) AS uid",
          [page]
        )
      end)
    end)

    Repo.query!("SELECT platform.refresh_device_inventory_rollups()")
  end

  defp stage_world(version, ids) do
    positions =
      ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, n} ->
        %{
          device_id: id,
          label: "Synthetic loader node",
          x: n * 100,
          y: n * 100,
          min_zoom: 0,
          parent_id: nil,
          component_id: "invented-loader-component",
          component_z: 0,
          component_x: 0,
          component_y: 0,
          placement_depth: 4,
          active: true
        }
      end)

    assert :ok =
             World.stage_candidate(
               version,
               %{source_digest: "invented-loader", node_count: length(ids), relation_count: 0},
               positions,
               []
             )
  end

  defp world_head_row do
    case Repo.query!("SELECT id, active_layout_version, generation, updated_at FROM platform.topology_world_head") do
      %{rows: []} -> nil
      %{rows: [row]} -> row
    end
  end

  defp layout_stamp(nil), do: nil
  defp layout_stamp([_id, nil, _generation, _updated_at]), do: nil

  defp layout_stamp([_id, version, _generation, _updated_at]) do
    case Repo.query!(
           "SELECT status, updated_at FROM platform.topology_world_layouts WHERE layout_version = $1",
           [version]
         ) do
      %{rows: []} -> nil
      %{rows: [row]} -> row
    end
  end

  defp delete_staged_world(version) do
    uuid = Ecto.UUID.dump!(version)
    Repo.query!("DELETE FROM platform.topology_world_head WHERE active_layout_version = $1", [uuid])

    for table <- ~w(topology_world_relations topology_world_positions topology_world_layouts) do
      Repo.query!("DELETE FROM platform.#{table} WHERE layout_version = $1", [uuid])
    end
  end

  defp restore_world_head(nil, _layout) do
    Repo.query!("DELETE FROM platform.topology_world_head")
  end

  defp restore_world_head([id, version, generation, updated_at], layout) do
    Repo.query!("DELETE FROM platform.topology_world_head")

    Repo.query!(
      """
      INSERT INTO platform.topology_world_head (id, active_layout_version, generation, updated_at)
      VALUES ($1, $2, $3, $4)
      """,
      [id, version, generation, updated_at]
    )

    case layout do
      [status, layout_updated_at] ->
        Repo.query!(
          """
          UPDATE platform.topology_world_layouts
          SET status = $1, updated_at = $2
          WHERE layout_version = $3
          """,
          [status, layout_updated_at, version]
        )

      nil ->
        :ok
    end
  end

  defp observe_loader_queries(tasks, hold_page? \\ false) do
    handler = {__MODULE__, make_ref()}
    event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _timings, metadata, owner ->
          query = String.upcase(to_string(metadata.query))

          kind =
            cond do
              String.contains?(query, "TOPOLOGY_WORLD_HEAD") -> :head
              String.contains?(query, "DEVICE_FLEET_ORDINALS") and String.contains?(query, "COUNT(*)") -> :progress
              String.contains?(query, "DEVICE_FLEET_ORDINALS") -> :page
              true -> nil
            end

          # A timed Ash read runs in its own task, so attribute each query to
          # the loader turn among the executing process and its callers.
          children = if kind, do: Task.Supervisor.children(tasks), else: []
          turn = Enum.find([self() | Process.get(:"$callers", [])], &(&1 in children))

          if turn do
            rows =
              case metadata.result do
                {:ok, %{num_rows: count}} -> count
                _ -> :failed
              end

            send(owner, {:loader_query, handler, turn, kind, rows})
            if kind == :page, do: send(owner, {:loader_page, handler, turn, metadata.params})

            if hold_page? and kind == :page do
              send(owner, {:loader_hold, handler, turn, self()})

              receive do
                {:continue_loader, ^handler} -> :ok
              after
                30_000 -> raise "loader page fixture was not released"
              end
            end
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  # The held query may run in a process below the turn; release that process.
  defp release_page(handler, turn) do
    assert_receive {:loader_hold, ^handler, ^turn, worker}, 10_000
    send(worker, {:continue_loader, handler})
  end

  defp drain_loader_queries(handler) do
    receive do
      {:loader_query, ^handler, _, _, _} -> drain_loader_queries(handler)
      {:loader_page, ^handler, _, _} -> drain_loader_queries(handler)
      {:loader_hold, ^handler, _, _} -> drain_loader_queries(handler)
    after
      0 -> :ok
    end
  end

  defp await_task(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
    assert reason in [:normal, :noproc]
  end

  defp await_loader_idle(loader), do: await_value(fn -> :sys.get_state(loader).active end, &is_nil/1)

  defp await_projection(cache, version, ids, expected, progress \\ nil) do
    # Return only scalar evidence; keep test observations from pinning obsolete
    # native resources after the cache replaces a world or mapping.
    fn ->
      {:ok, snapshot} =
        await_value(fn -> WorldCache.world(cache) end, fn
          {:ok, %{manifest: %{layout_version: ^version}, ordinals: %{mapping: mapping}} = current} ->
            (is_nil(progress) or current.dictionary_ordinal == progress) and
              TopologyAtlas.device_ordinals(current.world, mapping, ids) == {:ok, expected}

          _ ->
            false
        end)

      assert snapshot.ordinals.info.mapped == Enum.count(expected, &(&1 != 0))
      assert snapshot.ordinals.info.total == length(ids)
      {snapshot.ordinals.info.assignment, snapshot.dictionary_ordinal}
    end
    |> Task.async()
    |> Task.await(20_000)
  end

  defp await_value(read, ready?, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000
    result = read.()

    cond do
      ready?.(result) ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("loader did not converge: #{inspect(result)}")

      true ->
        receive do
        after
          10 -> await_value(read, ready?, deadline)
        end
    end
  end

  defp start_replica(id, pubsub) do
    name = if id == :one, do: __MODULE__.OneTasks, else: __MODULE__.TwoTasks
    start_supervised!(Supervisor.child_spec({Task.Supervisor, name: name, max_children: 1}, id: {:tasks, id}))
    start_owner(id, pubsub, name)
  end

  defp start_owner(id, pubsub, tasks) do
    start_supervised!(Supervisor.child_spec({BitmapIndex, task_supervisor: tasks, pubsub: pubsub}, id: {:replica, id}))
  end

  defp create(uid, vendor, available) do
    Device
    |> Ash.Changeset.for_create(:create, %{uid: uid, vendor_name: vendor, is_available: available}, actor: @actor)
    |> Ash.create!()
  end

  defp create_resource(resource, attrs),
    do: resource |> Ash.Changeset.for_create(:create, attrs, actor: @actor) |> Ash.create!()

  defp publish_addresses(current, ordinals, sequence) do
    BitmapPublisher.publish(
      current,
      fn ->
        with {:ok, rows} <- BitmapSource.fetch(ordinals, current.supported_facets), do: {:ok, %{rows: rows}}
      end,
      fn _ -> true end,
      sequence
    )
  end

  defp address_members(current, cidr) do
    selected_members(current, %{"ip_cidr" => cidr})
  end

  defp selected_members(current, expression) do
    {:ok, parsed} = BitmapExpression.parse(%{"expression" => expression}, current.supported_facets)

    with {:ok, {query, _, _, _}} <-
           Native.bitmap_index_query(
             current.device,
             current.dictionary_epoch,
             current.index_epoch,
             :device,
             @authority,
             parsed.program,
             1_000
           ) do
      try do
        Native.bitmap_query_page(query, @authority, 0, 128, 1_000)
      after
        Native.bitmap_query_close(query)
      end
    end
  end

  defp set_available(device, value) do
    device |> Ash.Changeset.for_update(:set_availability, %{is_available: value}, actor: @actor) |> Ash.update!()
  end

  defp await_members(owner, vendor, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 45_000
    actual = members(owner, vendor)

    cond do
      actual == {:ok, expected} ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("replica membership did not converge: #{inspect(actual)}")

      true ->
        Process.sleep(25)
        await_members(owner, vendor, expected, deadline)
    end
  end

  defp members(owner, vendor) do
    with {:ok, snapshot} <- BitmapIndex.snapshot(owner),
         {:ok, parsed} <-
           BitmapExpression.parse(
             %{
               "expression" => %{
                 "all" => [%{"facet" => "vendor", "value" => vendor}, %{"facet" => "availability", "value" => "healthy"}]
               }
             },
             snapshot.supported_facets
           ),
         {:ok, {query, _revision, _source, count}} <-
           Native.bitmap_index_query(
             snapshot.device,
             snapshot.dictionary_epoch,
             snapshot.index_epoch,
             :device,
             @authority,
             parsed.program,
             1_000
           ) do
      try do
        with {:ok, ordinals} <- Native.bitmap_query_page(query, @authority, 0, 128, 1_000) do
          assert count == length(ordinals)
          {:ok, ordinals}
        end
      after
        Native.bitmap_query_close(query)
      end
    end
  end
end

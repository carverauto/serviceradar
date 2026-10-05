defmodule ServiceRadarWebNG.Topology.WorldHealthSourceDBTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Topology.WorldHealthSource
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldHealth
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldTile

  @moduletag :topology_atlas_db

  setup do
    :ok = Sandbox.checkout(Repo)
    %{scope: Scope.for_user(SystemActor.system(:world_health_source_test))}
  end

  test "health follows persisted availability and identity changes while missing and deleted devices stay unknown", %{
    scope: scope
  } do
    ready = create_device(scope, "sr:health-ready", true, %{})
    down = create_device(scope, "sr:health-down", false, %{"identity_source" => "inventory"})
    create_device(scope, "sr:health-unobserved", nil, %{})
    create_device(scope, "sr:health-no-metadata", true, nil)
    sighting = create_device(scope, "sr:health-sighting", true, %{"identity_source" => "mapper_topology_sighting"})

    ids = [ready.uid, down.uid, "sr:health-unobserved", "sr:health-no-metadata", sighting.uid, "sr:health-absent"]

    assert {:ok,
            [
              %{device_id: "sr:health-ready", state: :healthy},
              %{device_id: "sr:health-down", state: :unavailable},
              %{device_id: "sr:health-unobserved", state: :unknown},
              %{device_id: "sr:health-no-metadata", state: :healthy},
              %{device_id: "sr:health-sighting", state: :unknown},
              %{device_id: "sr:health-absent", state: :unknown}
            ]} = WorldHealthSource.fetch(ids)

    ready
    |> Ash.Changeset.for_update(:set_availability, %{is_available: false}, scope: scope)
    |> Ash.update!()

    sighting
    |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: %{"identity_source" => "inventory"}}, scope: scope)
    |> Ash.update!()

    down
    |> Ash.Changeset.for_update(:soft_delete, %{deleted_reason: "synthetic health source test"}, scope: scope)
    |> Ash.update!()

    assert {:ok,
            [
              %{device_id: "sr:health-ready", state: :unavailable},
              %{device_id: "sr:health-down", state: :unknown},
              %{device_id: "sr:health-unobserved", state: :unknown},
              %{device_id: "sr:health-no-metadata", state: :healthy},
              %{device_id: "sr:health-sighting", state: :healthy},
              %{device_id: "sr:health-absent", state: :unknown}
            ]} = WorldHealthSource.fetch(ids)
  end

  test "a full bounded request preserves every identity and rejects overflow", %{scope: scope} do
    device = create_device(scope, "sr:health-final-member", true, %{})
    missing = Enum.map(1..499, &"sr:health-missing-#{&1}")
    ids = missing ++ [device.uid]

    assert {:ok, rows} = WorldHealthSource.fetch(ids)
    assert Enum.map(rows, & &1.device_id) == ids
    assert Enum.all?(Enum.take(rows, 499), &(&1.state == :unknown))
    assert List.last(rows) == %{device_id: device.uid, state: :healthy}
    assert {:error, :invalid_batch} = WorldHealthSource.fetch(ids ++ ["sr:health-overflow"])
    assert {:ok, []} = WorldHealthSource.fetch([])
  end

  test "failed first-page source read retries with backoff without another rescan hint", %{scope: scope} do
    device = create_device(scope, "sr:health-retry", true, %{})
    pubsub = __MODULE__.RetryPubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    tasks = start_supervised!({Task.Supervisor, []})
    cache = start_supervised!({WorldCache, task_supervisor: tasks, pubsub: pubsub})
    version = "00000000-0000-4000-8000-000000000481"
    {:ok, builder} = TopologyAtlas.new_builder(version, 0)
    :ok = TopologyAtlas.add_positions(builder, [
      %{device_id: device.uid, label: "Synthetic retry device", x: 300_000, y: 300_000,
        min_zoom: 0, parent_id: nil, component_id: "invented-retry-component",
        component_z: 0, component_x: 0, component_y: 0, placement_depth: 0, active: true}
    ])
    {:ok, world} = TopologyAtlas.finish_world(builder)
    manifest = %{layout_version: version, generation: 1, zmax: 0}
    prepared = Map.new(TileKey.low_zoom(manifest), fn key ->
      {:ok, tile} = WorldTile.build(world, key)
      {key, tile}
    end)
    assert :ok = WorldCache.install(world, manifest, prepared, cache)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    ExUnit.CaptureLog.capture_log(fn ->
      # The task initially has no sandbox access, so its real first-page source
      # query fails. Restore database access only after observing that failure.
      health = start_supervised!({WorldHealth, cache: cache, task_supervisor: tasks, pubsub: pubsub})
      failed = await_snapshot(health, &(&1.progress.source_status == :stale))
      assert failed.progress.reconciled_since == nil
      assert :ok = Sandbox.mode(Repo, {:shared, self()})

      recovered = await_snapshot(health, &(&1.progress.source_status == :current))
      assert %DateTime{} = recovered.progress.reconciled_since
      assert %DateTime{} = recovered.progress.last_read_at
      refute recovered.progress.reconciling
      assert {:ok, %{observed: 1}} = TopologyAtlas.health_info(recovered.world, recovered.health)
    end)
  end

  defp await_snapshot(health, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000
    case WorldHealth.snapshot(health) do
      {:ok, snapshot} ->
        if predicate.(snapshot), do: snapshot, else: await_next_snapshot(health, predicate, deadline)
      _ -> await_next_snapshot(health, predicate, deadline)
    end
  end

  defp await_next_snapshot(health, predicate, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("world health did not recover before its retry deadline")
    end
    Process.sleep(20)
    await_snapshot(health, predicate, deadline)
  end

  defp create_device(scope, uid, available, metadata) do
    Device
    |> Ash.Changeset.for_create(:create, %{uid: uid, is_available: available, metadata: metadata}, scope: scope)
    |> Ash.create!()
  end
end

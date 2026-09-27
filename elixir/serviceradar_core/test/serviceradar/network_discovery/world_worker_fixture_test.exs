defmodule ServiceRadar.NetworkDiscovery.WorldWorkerFixtureTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dgraph
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.World
  alias ServiceRadar.NetworkDiscovery.WorldLayout
  alias ServiceRadar.NetworkDiscovery.WorldWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TopologyAtlas

  @moduletag :external
  @moduletag :world_worker_fixture

  test "real source pages publish atomically and a rebuild during execution schedules the missing snapshot" do
    prefix = "sr:world-fixture-#{Ash.UUID.generate()}"
    ids = Enum.map(1..504, &"#{prefix}-#{&1}")
    assert {:error, :not_ready} = World.active_manifest(scope())

    Enum.each(Enum.take(ids, 503), fn id ->
      assert :ok = Dgraph.upsert_device(%{id: id, hostname: "node.example.com"})
    end)

    inventory =
      Enum.map(Enum.take(ids, 503), &%{uid: &1, hostname: "inventory.example.com", type_id: 12})

    assert %Ash.BulkResult{status: :success} =
             Ash.bulk_create(inventory, Device, :create,
               actor: actor(),
               batch_size: 500,
               return_errors?: true
             )

    edges =
      Enum.map(0..501, fn index ->
        edge(Enum.at(ids, index), Enum.at(ids, rem(index + 1, 502)))
      end)

    parallel =
      Map.merge(edge(hd(ids), Enum.at(ids, 1)), %{
        if_name_ab: "eth7",
        if_name_ba: "eth9",
        if_index_ab: 7,
        if_index_ba: 9
      })

    edges = [parallel | edges]
    assert :ok = Dgraph.rebuild_canonical(edges)
    job = reconcile_job!()
    version = job.args["layout_version"]

    try do
      WorldLayout
      |> Ash.Changeset.for_create(:initialize_stage, %{
        layout_version: version,
        source_digest: "synthetic-pending",
        node_count: 0,
        relation_count: 0
      })
      |> Ash.create!(actor: actor())

      publish_while_source_changes(job, version, List.last(ids), edges)

      assert {:ok, %{generation: 1, node_count: 503, relation_count: 503}} =
               World.active_manifest(scope())

      assert {:ok, nil} = World.lookup_device(scope(), version, List.last(ids))
      before = placements()
      assert map_size(before) == 503
      assert Enum.all?(Map.values(before), &(&1.label == "inventory.example.com"))

      completed = Repo.get!(Oban.Job, job.id, prefix: "platform")
      assert completed.state == "completed"
      refute completed.args["observed_request"] == completed.meta["request_id"]
      assert {:ok, followup} = WorldWorker.ensure_scheduled()
      assert followup.id != job.id
      assert DateTime.diff(followup.scheduled_at, DateTime.utc_now(), :second) <= 1
      assert_drain_success()

      assert {:ok, %{generation: 2, node_count: 504, relation_count: 503} = manifest} =
               World.active_manifest(scope())

      after_positions = placements()
      assert Map.take(after_positions, Map.keys(before)) == before

      {world, relations} = reload_world([500, 4], [500, 3])
      assert {:ok, %{node_count: 504, relation_count: 503}} = TopologyAtlas.world_info(world)
      assert {:ok, %{device_id: isolated}} = TopologyAtlas.search(world, Enum.at(ids, 502))
      assert isolated == Enum.at(ids, 502)

      assert Enum.count(relations, &(&1.source_id == hd(ids) and &1.target_id == Enum.at(ids, 1))) ==
               2

      assert %{source_if_index: 7, target_if_index: 9} =
               Enum.find(relations, &(&1.source_if_name == "eth7"))

      assert {:ok, tile} = TopologyAtlas.tile(world, 0, 0, 0)

      # Interface identity is persisted across a cold cache reload, while an
      # index-only binding change must not alter the tile's geometry identity.
      assert :ok = Dgraph.rebuild_canonical([%{parallel | if_index_ab: 23} | tl(edges)])
      assert_drain_success()
      assert {:ok, %{generation: 3, source_digest: digest}} = World.active_manifest(scope())
      refute digest == manifest.source_digest
      {updated_world, updated_relations} = reload_world([500, 4], [500, 3])

      assert %{source_if_index: 23, target_if_index: 9} =
               Enum.find(updated_relations, &(&1.source_if_name == "eth7"))

      assert {:ok, updated_tile} = TopologyAtlas.tile(updated_world, 0, 0, 0)
      assert updated_tile.revision == tile.revision
    after
      cleanup(version, ids, job.id)
    end

    verify_million_device_persistence()
  end

  # The native hierarchy is a declared Bazel input, shared with the browser
  # acceptance. Persist and reload it through the production publication API;
  # counting generated rows alone would not prove the database path at scale.
  defp verify_million_device_persistence do
    path = Path.join(System.fetch_env!("TEST_TMPDIR"), "rust/topology-atlas/million_world.tsv")
    version = Ash.UUID.generate()

    metadata = %{
      source_digest: "invented-million-hierarchy",
      node_count: 1_000_000,
      relation_count: 2_000_000
    }

    positions = fixture_rows(path, "p", &fixture_position/1)
    relations = fixture_rows(path, "r", &fixture_relation/1)
    samples = positions |> Enum.take(3) |> Map.new(&{&1.device_id, {&1.x, &1.y}})

    IO.puts("WORLD_SCALE_PHASE persist")

    {persist_us, result} =
      :timer.tc(fn -> World.stage_candidate(version, metadata, positions, relations) end)

    assert :ok = result
    {publish_us, result} = :timer.tc(fn -> World.activate_relayout(0, version) end)
    assert {:ok, %{node_count: 1_000_000, relation_count: 2_000_000}} = result

    for {table, expected} <- [
          {"topology_world_positions", 1_000_000},
          {"topology_world_relations", 2_000_000}
        ] do
      assert %{rows: [[^expected]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.#{table} WHERE layout_version = $1::uuid AND active",
                 [Ecto.UUID.dump!(version)]
               )
    end

    IO.puts("WORLD_SCALE_PHASE reload persist_ms=#{div(persist_us, 1000)}")

    {reload_us, result} =
      :timer.tc(fn ->
        World.stream_active(nil, fn
          {:manifest, manifest}, nil ->
            TopologyAtlas.new_builder(manifest.layout_version, manifest.zmax)

          {:positions, rows}, builder ->
            :ok = TopologyAtlas.add_positions(builder, rows)
            {:ok, builder}

          {:relations, rows}, builder ->
            :ok = TopologyAtlas.add_relations(builder, rows)
            {:ok, builder}
        end)
      end)

    assert {:ok, builder} = result
    {index_us, result} = :timer.tc(fn -> TopologyAtlas.finish_world(builder) end)
    assert {:ok, world} = result

    assert {:ok, %{node_count: 1_000_000, relation_count: 2_000_000}} =
             TopologyAtlas.world_info(world)

    for {id, {x, y}} <- samples do
      assert {:ok, %{x: ^x, y: ^y}} = TopologyAtlas.search(world, id)
    end

    {_id, {x, y}} = Enum.at(samples, 0)

    {query_us, result} =
      :timer.tc(fn -> TopologyAtlas.tile(world, 16, div(x, 256), div(y, 256)) end)

    assert {:ok, _tile} = result
    [_, peak_kib] = Regex.run(~r/^VmHWM:\s+(\d+) kB$/m, File.read!("/proc/self/status"))

    IO.puts(
      "WORLD_SCALE_MEASUREMENTS " <>
        Jason.encode!(%{
          persist_ms: div(persist_us, 1000),
          publish_ms: div(publish_us, 1000),
          reload_ms: div(reload_us, 1000),
          index_ms: div(index_us, 1000),
          high_zoom_query_us: query_us,
          beam_peak_resident_kib: String.to_integer(peak_kib)
        })
    )

    # The guarded lifecycle owns and drops this entire scratch database after
    # this final case. Do not spend another full write pass deleting its rows.
  end

  defp fixture_rows(path, kind, decoder) do
    path
    |> File.stream!()
    |> Stream.filter(&String.starts_with?(&1, kind <> "\t"))
    |> Stream.map(&(&1 |> String.trim_trailing("\n") |> String.split("\t") |> decoder.()))
  end

  defp fixture_position(["p", id, label, x, y, zoom, parent, component, z, cx, cy, depth]) do
    %{
      device_id: id,
      label: label,
      x: String.to_integer(x),
      y: String.to_integer(y),
      min_zoom: String.to_integer(zoom),
      parent_id: if(parent == "", do: nil, else: parent),
      component_id: component,
      component_z: String.to_integer(z),
      component_x: String.to_integer(cx),
      component_y: String.to_integer(cy),
      placement_depth: String.to_integer(depth),
      active: true
    }
  end

  defp fixture_relation(["r", id, source, target]) do
    %{
      relation_id: id,
      source_id: source,
      target_id: target,
      evidence_class: "direct-physical",
      active: true
    }
  end

  defp publish_while_source_changes(job, version, new_id, edges) do
    owner = self()

    locker =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

            Repo.query!(
              "SELECT layout_version FROM platform.topology_world_layouts WHERE layout_version = $1::uuid FOR UPDATE",
              [Ecto.UUID.dump!(version)]
            )

            send(owner, {:stage_locked, backend})

            receive do
              :release -> :ok
            after
              120_000 -> raise "fixture stage lock was not released"
            end
          end,
          timeout: 150_000
        )
      end)

    try do
      assert_receive {:stage_locked, locker_backend}, 10_000

      worker =
        Task.async(fn ->
          Repo.checkout(
            fn ->
              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
              send(owner, {:worker_backend, backend})
              Oban.drain_queue(queue: :topology_world, with_limit: 1)
            end,
            timeout: 180_000
          )
        end)

      try do
        assert_receive {:worker_backend, worker_backend}, 10_000

        assert_blocked(
          worker_backend,
          locker_backend,
          System.monotonic_time(:millisecond) + 60_000
        )

        executing = Repo.get!(Oban.Job, job.id, prefix: "platform")
        assert executing.state == "executing"
        assert executing.args["observed_request"] == job.meta["request_id"]
        assert :ok = Dgraph.upsert_device(%{id: new_id, hostname: "added.example.com"})
        assert :ok = Dgraph.rebuild_canonical(edges)
        assert reconcile_job!().id == job.id
        send(locker.pid, :release)
        assert {:ok, :ok} = Task.await(locker, 10_000)

        assert %{success: 1, failure: 0, snoozed: 0, discard: 0, cancelled: 0} =
                 Task.await(worker, 120_000)
      after
        send(locker.pid, :release)
        Task.shutdown(worker, :brutal_kill)
      end
    after
      send(locker.pid, :release)
      Task.shutdown(locker, :brutal_kill)
    end
  end

  defp assert_blocked(worker, locker, deadline) do
    %{rows: [[blocked]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND $2 = ANY(pg_blocking_pids(pid)))",
        [worker, locker]
      )

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("actual worker did not reach the owned stage lock after reading its source")

      true ->
        Process.sleep(20)
        assert_blocked(worker, locker, deadline)
    end
  end

  defp assert_drain_success do
    assert %{success: 1, failure: 0, snoozed: 0, discard: 0, cancelled: 0} =
             Oban.drain_queue(
               queue: :topology_world,
               with_limit: 1,
               with_scheduled: DateTime.utc_now()
             )
  end

  defp reconcile_job! do
    Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(WorldWorker) and
            job.state in ["available", "scheduled", "executing", "retryable"]
      ),
      prefix: "platform"
    )
  end

  defp placements do
    assert {:ok, placements} =
             World.stream_active(%{}, fn
               {:positions, rows}, acc ->
                 {:ok,
                  Enum.reduce(
                    rows,
                    acc,
                    &Map.put(
                      &2,
                      &1.device_id,
                      Map.take(&1, [
                        :x,
                        :y,
                        :label,
                        :min_zoom,
                        :parent_id,
                        :component_id,
                        :component_z,
                        :component_x,
                        :component_y,
                        :placement_depth
                      ])
                    )
                  )}

               _event, acc ->
                 {:ok, acc}
             end)

    placements
  end

  defp reload_world(position_sizes, relation_sizes) do
    assert {:ok, state} =
             World.stream_active(%{position_sizes: [], relation_sizes: [], relations: []}, fn
               {:manifest, manifest}, acc ->
                 assert {:ok, builder} =
                          TopologyAtlas.new_builder(manifest.layout_version, manifest.zmax)

                 {:ok, Map.put(acc, :builder, builder)}

               {:positions, rows}, acc ->
                 assert :ok = TopologyAtlas.add_positions(acc.builder, rows)
                 {:ok, %{acc | position_sizes: acc.position_sizes ++ [length(rows)]}}

               {:relations, rows}, acc ->
                 assert :ok = TopologyAtlas.add_relations(acc.builder, rows)

                 {:ok,
                  %{
                    acc
                    | relation_sizes: acc.relation_sizes ++ [length(rows)],
                      relations: acc.relations ++ rows
                  }}
             end)

    assert state.position_sizes == position_sizes
    assert state.relation_sizes == relation_sizes
    assert {:ok, world} = TopologyAtlas.finish_world(state.builder)
    {world, state.relations}
  end

  defp edge(source, target) do
    %{
      source: source,
      target: target,
      kind: :canonical_topology,
      protocol: "lldp",
      evidence_class: "direct-physical",
      if_name_ab: "eth1",
      if_name_ba: "eth2",
      if_index_ab: 1,
      if_index_ba: 2
    }
  end

  defp cleanup(version, ids, first_job_id) do
    Repo.query!(
      "DELETE FROM platform.topology_world_head WHERE active_layout_version = $1::uuid",
      [
        Ecto.UUID.dump!(version)
      ]
    )

    Repo.query!("DELETE FROM platform.topology_world_relations WHERE layout_version = $1::uuid", [
      Ecto.UUID.dump!(version)
    ])

    Repo.query!("DELETE FROM platform.topology_world_positions WHERE layout_version = $1::uuid", [
      Ecto.UUID.dump!(version)
    ])

    Repo.query!("DELETE FROM platform.topology_world_layouts WHERE layout_version = $1::uuid", [
      Ecto.UUID.dump!(version)
    ])

    Repo.delete_all(
      from(job in Oban.Job,
        where: job.worker == ^Oban.Worker.to_string(WorldWorker) and job.id >= ^first_job_id
      ),
      prefix: "platform"
    )

    Repo.query!("DELETE FROM platform.ocsf_devices WHERE uid = ANY($1::text[])", [ids])

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.topology_world_layouts WHERE layout_version = $1::uuid",
               [
                 Ecto.UUID.dump!(version)
               ]
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.ocsf_devices WHERE uid = ANY($1::text[])",
               [ids]
             )

    refute Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == ^Oban.Worker.to_string(WorldWorker) and job.id >= ^first_job_id
             ),
             prefix: "platform"
           )

    assert {:error, :not_ready} = World.active_manifest(scope())
  end

  defp actor, do: SystemActor.system(:topology_world_fixture)
  defp scope, do: %{actor: actor()}
end

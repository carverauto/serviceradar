defmodule ServiceRadar.NetworkDiscovery.WorldTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.World
  alias ServiceRadar.NetworkDiscovery.WorldInventory
  alias ServiceRadar.NetworkDiscovery.WorldLayout
  alias ServiceRadar.NetworkDiscovery.WorldPosition
  alias ServiceRadar.NetworkDiscovery.WorldRelation
  alias ServiceRadar.NetworkDiscovery.WorldRetention
  alias ServiceRadar.NetworkDiscovery.WorldRetentionWorker
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  test "staging stays invisible and bootstrap follows every bounded page" do
    # 5,003 positions crosses the stream reload page size (5,000) by 3, so the
    # bootstrap read below must span two pages rather than returning everything at once.
    position_count = 5_003
    positions = Enum.map(1..position_count, &position/1)
    version = Ecto.UUID.generate()
    metadata = %{source_digest: "synthetic-cold-start", node_count: position_count, relation_count: 0}
    assert :ok = World.stage_candidate(version, metadata, positions, [])
    assert {:error, :not_ready} = World.active_manifest(scope())
    assert {:ok, nil} = World.lookup_device(scope(), version, "sr:host01")

    assert {:ok,
            %{layout_version: ^version, generation: 1, node_count: ^position_count, relation_count: 0}} =
             World.activate_relayout(0, version)

    assert {:ok, %{manifest: %{node_count: ^position_count}, batches: [5_000, 3], ids: ids}} =
             World.stream_active(%{batches: [], ids: MapSet.new()}, fn
               {:manifest, manifest}, acc ->
                 {:ok, Map.put(acc, :manifest, manifest)}

               {:positions, rows}, acc ->
                 {:ok,
                  %{
                    acc
                    | batches: acc.batches ++ [length(rows)],
                      ids: Enum.reduce(rows, acc.ids, &MapSet.put(&2, &1.device_id))
                  }}

               {:relations, []}, acc ->
                 {:ok, acc}
             end)

    assert ids == MapSet.new(positions, & &1.device_id)
  end

  test "incremental retirement, return and display updates preserve coordinates and parallel relations" do
    original = [position(1), position(2)]

    blue = %{
      relation("link-blue", 1, 2)
      | source_if_index: 13,
        source_if_name: "eth13",
        target_if_index: 17,
        target_if_name: "eth17"
    }

    relations = [relation("link-red", 1, 2), blue]
    layout = activate(original, relations)
    version = layout.layout_version

    assert {:ok, %{generation: 2, node_count: 1}} =
             World.publish_delta(1, %{
               deactivate_device_ids: ["sr:host02"],
               deactivate_relation_ids: ["link-red", "link-blue"],
               source_digest: "synthetic-retirement",
               node_count: 1,
               relation_count: 0
             })

    assert {:ok, nil} = World.lookup_device(scope(), version, "sr:host02")
    assert {:ok, %{positions: positions, relations: []}} = collect_world()
    assert %{active: false, x: 200, y: 400} = Enum.find(positions, &(&1.device_id == "sr:host02"))

    assert {:ok, %{generation: 3}} =
             World.publish_delta(2, %{
               activate_device_ids: ["sr:host02"],
               upsert_relations: relations,
               source_digest: "synthetic-return",
               node_count: 2,
               relation_count: 2
             })

    assert {:ok, %{generation: 4}} =
             World.publish_delta(3, %{
               update_positions: [
                 %{device_id: "sr:host01", label: "host01-renamed.example.com", min_zoom: 4},
                 %{device_id: "sr:host02", label: "host02-renamed.example.com", min_zoom: 0}
               ],
               upsert_relations: [%{blue | source_if_index: 21, source_if_name: "eth21"}],
               source_digest: "synthetic-rename",
               node_count: 2,
               relation_count: 2
             })

    assert {:ok, %{positions: after_positions, relations: after_relations}} = collect_world()

    geometry = [
      :device_id,
      :x,
      :y,
      :parent_id,
      :component_id,
      :component_z,
      :component_x,
      :component_y,
      :placement_depth
    ]

    assert Enum.map(after_positions, &Map.take(&1, geometry)) ==
             Enum.map(original, &Map.take(&1, geometry))

    assert after_relations |> Enum.map(& &1.relation_id) |> Enum.sort() == [
             "link-blue",
             "link-red"
           ]

    assert %{
             source_if_index: 21,
             source_if_name: "eth21",
             target_if_index: 17,
             target_if_name: "eth17"
           } =
             Enum.find(after_relations, &(&1.relation_id == "link-blue"))

    assert %{source_if_index: 7, target_if_index: 9} =
             Enum.find(after_relations, &(&1.relation_id == "link-red"))

    assert {:ok, %{label: "host01-renamed.example.com", min_zoom: 4, x: 100, y: 200}} =
             World.lookup_device(scope(), version, "sr:host01")

    assert {:ok, %{label: "host02-renamed.example.com", min_zoom: 0, x: 200, y: 400}} =
             World.lookup_device(scope(), version, "sr:host02")
  end

  test "a failed relation or incomplete stage cannot publish partial coordinates" do
    layout = activate([position(1)], [])

    assert {:error, :invalid_relation_endpoint} =
             World.publish_delta(1, %{
               insert_positions: [position(2)],
               upsert_relations: [relation("missing-target", 2, 3)],
               source_digest: "synthetic-rejected",
               node_count: 2,
               relation_count: 1
             })

    assert {:ok, %{generation: 1, node_count: 1}} = World.active_manifest(scope())
    assert {:ok, nil} = World.lookup_device(scope(), layout.layout_version, "sr:host02")

    assert {:ok, staged} =
             World.stage_relayout(scope(), %{
               source_digest: "synthetic-incomplete",
               node_count: 2,
               relation_count: 0
             })

    assert :ok = World.append_stage(staged.layout_version, [position(3)], [])
    assert {:error, :incomplete_world} = World.activate_relayout(1, staged.layout_version)
    assert {:ok, %{layout_version: active, generation: 1}} = World.active_manifest(scope())
    assert active == layout.layout_version

    metadata = %{source_digest: "synthetic-retry", node_count: 1, relation_count: 0}
    assert :ok = World.stage_candidate(staged.layout_version, metadata, [position(4)], [])
    assert {:ok, %{generation: 2}} = World.activate_relayout(1, staged.layout_version)
    assert {:ok, nil} = World.lookup_device(scope(), staged.layout_version, "sr:host03")
    assert {:ok, %{x: 400}} = World.lookup_device(scope(), staged.layout_version, "sr:host04")

    assert {:error, :layout_already_published} =
             World.stage_candidate(staged.layout_version, metadata, [], [])
  end

  test "explicit relayout records the authorized stage and its exact job version together" do
    actor = SystemActor.system(:topology_world_test)

    denied = %{
      actor: %{id: "synthetic-reader", role: :viewer, permissions: MapSet.new(["analytics.view"])}
    }

    authorized = %{
      actor: %{
        id: "synthetic-operator",
        role: :viewer,
        permissions: MapSet.new(["settings.networks.manage"])
      }
    }

    count = Ash.count!(WorldLayout, actor: actor)

    assert {:error, %Forbidden{}} = World.request_relayout(denied)
    assert Ash.count!(WorldLayout, actor: actor) == count

    assert {:ok, %{layout_version: version, job_id: job_id}} = World.request_relayout(authorized)

    assert %{args: %{"mode" => "relayout", "layout_version" => ^version}} =
             Repo.get!(Oban.Job, job_id, prefix: "platform")

    assert %{status: :building, node_count: 0} = Ash.get!(WorldLayout, version, actor: actor)
    assert {:error, :not_ready} = World.active_manifest(scope())
  end

  test "inventory classification streams every live device in bounded pages" do
    actor = SystemActor.system(:topology_world_test)

    devices =
      Enum.map(1..502, fn index ->
        %{uid: "sr:inventory-#{index}", type_id: 12, hostname: "host#{index}.example.com"}
      end)

    assert %Ash.BulkResult{status: :success} =
             Ash.bulk_create(devices, Device, :create,
               actor: actor,
               batch_size: 500,
               return_errors?: true
             )

    Device
    |> Ash.get!("sr:inventory-502", actor: actor)
    |> Ash.Changeset.for_update(:soft_delete, %{})
    |> Ash.update!(actor: actor)

    assert {:ok, %{sizes: [500, 1], ids: ids}} =
             WorldInventory.stream(%{sizes: [], ids: MapSet.new()}, fn rows, acc ->
               assert Enum.all?(rows, &(&1.importance == 0))

               {:ok,
                %{
                  sizes: acc.sizes ++ [length(rows)],
                  ids: Enum.reduce(rows, acc.ids, &MapSet.put(&2, &1.id))
                }}
             end)

    assert ids == MapSet.new(1..501, &"sr:inventory-#{&1}")
  end

  test "stale producers cannot overwrite a newer publication or coordinate system" do
    original = activate([position(1)], [])
    replacement = stage([%{position(1) | x: 800, y: 900}], [])
    assert {:ok, %{generation: 2}} = World.activate_relayout(1, replacement.layout_version)
    assert {:error, :stale_generation} = World.publish_delta(1, %{})
    assert {:error, :stale_generation} = World.activate_relayout(1, original.layout_version)
    assert {:ok, %{layout_version: version, generation: 2}} = World.active_manifest(scope())
    assert version == replacement.layout_version

    assert {:error, :layout_already_published} =
             World.append_stage(original.layout_version, [position(2)], [])

    assert {:ok, %{x: 800, y: 900}} = World.lookup_device(scope(), version, "sr:host01")
  end

  test "manifest and inventory permissions remain distinct and invalid grid cells are rejected" do
    layout = activate([position(1)], [])

    analytics = %{
      actor: %{id: "synthetic-viewer", role: :viewer, permissions: MapSet.new(["analytics.view"])}
    }

    inventory =
      put_in(analytics.actor.permissions, MapSet.new(["analytics.view", "devices.view"]))

    assert {:ok, %{generation: 1}} = World.active_manifest(analytics)

    assert {:ok, %{device_id: "sr:host01"}} =
             World.lookup_device(inventory, layout.layout_version, "sr:host01")

    assert {:ok, nil} = World.lookup_device(analytics, layout.layout_version, "sr:host01")
    assert {:error, :not_ready} = World.active_manifest(nil)

    assert {:error, %Forbidden{}} =
             World.stage_relayout(analytics, %{
               source_digest: "synthetic-denied",
               node_count: 0,
               relation_count: 0
             })

    assert {:ok, staged} =
             World.stage_relayout(scope(), %{
               source_digest: "synthetic-invalid-cell",
               node_count: 1,
               relation_count: 0
             })

    assert {:error, _constraint_error} =
             World.append_stage(
               staged.layout_version,
               [%{position(2) | component_z: 1, component_x: 2}],
               []
             )

    assert {:error, :incomplete_world} = World.activate_relayout(1, staged.layout_version)
  end

  @tag sandbox: :unboxed
  test "bootstrap blocks publication until every page belongs to one generation" do
    layout = activate([position(1), position(2)], [relation("first-link", 1, 2)])
    on_exit(fn -> delete_test_layout(layout.layout_version) end)
    parent = self()

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "topology:world")

    reader =
      Task.async(fn ->
        World.stream_active(%{positions: [], relations: []}, fn
          {:manifest, manifest}, acc ->
            send(parent, :reader_holds_snapshot)

            receive do
              :continue -> {:ok, Map.put(acc, :manifest, manifest)}
            after
              10_000 -> {:error, :reader_not_released}
            end

          {:positions, rows}, acc ->
            {:ok, %{acc | positions: acc.positions ++ rows}}

          {:relations, rows}, acc ->
            {:ok, %{acc | relations: acc.relations ++ rows}}
        end)
      end)

    try do
      assert_receive :reader_holds_snapshot, 10_000

      writer =
        Task.async(fn ->
          Repo.checkout(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:writer_backend, backend})

            World.publish_delta(1, %{
              insert_positions: [position(3)],
              upsert_relations: [relation("second-link", 2, 3)],
              source_digest: "synthetic-overlap",
              node_count: 3,
              relation_count: 2
            })
          end)
        end)

      try do
        assert_receive {:writer_backend, backend}, 10_000
        assert_lock_wait(backend, System.monotonic_time(:millisecond) + 10_000)
        refute_receive {:topology_world_changed, _manifest}
        send(reader.pid, :continue)

        assert {:ok,
                %{manifest: %{generation: 1}, positions: [_first, _second], relations: [_link]}} =
                 Task.await(reader, 10_000)

        assert {:ok, %{generation: 2}} = Task.await(writer, 10_000)
        assert_receive {:topology_world_changed, %{layout_version: version, generation: 2}}, 1_000
        assert version == layout.layout_version
        assert {:ok, %{positions: [_, _, _], relations: [_, _]}} = collect_world()
      after
        Task.shutdown(writer, :brutal_kill)
      end
    after
      send(reader.pid, :continue)
      Task.shutdown(reader, :brutal_kill)
    end
  end

  test "retention resumes bounded row deletion while preserving active, recent and unfinished layouts" do
    rows = Enum.map(1..503, &position/1)
    links = Enum.map(1..503, &relation("synthetic-link-#{&1}", 1, 2))
    obsolete = stage(rows, links)
    assert {:ok, %{generation: 1}} = World.activate_relayout(0, obsolete.layout_version)
    retained = stage([position(1)], [])
    assert {:ok, %{generation: 2}} = World.activate_relayout(1, retained.layout_version)
    active = stage([position(2)], [])
    assert {:ok, %{generation: 3}} = World.activate_relayout(2, active.layout_version)
    abandoned = stage(rows, [])
    fresh = stage([position(3)], [])
    assert {:ok, pending} = World.request_relayout(scope())
    assert :ok = World.append_stage(pending.layout_version, [position(4)], [])

    Enum.each(
      [obsolete, abandoned, pending],
      &age_layout(&1.layout_version, ~U[2025-04-01 00:00:00Z])
    )

    age_layout(retained.layout_version, ~U[2025-04-02 00:00:00Z])
    age_layout(active.layout_version, ~U[2025-04-03 00:00:00Z])

    # Choose a deterministic oldest candidate while the other old versions
    # remain eligible for subsequent passes.
    age_layout(obsolete.layout_version, ~U[2025-03-01 00:00:00Z])
    age_layout(pending.layout_version, ~U[2025-03-15 00:00:00Z])
    assert {:ok, %{deleted_rows: 500, deleted_layout?: false}} = WorldRetention.prune_batch()
    assert layout_rows(WorldRelation, obsolete.layout_version) == 3
    assert layout_rows(WorldPosition, obsolete.layout_version) == 503
    assert Ash.get!(WorldLayout, obsolete.layout_version, actor: scope().actor)

    assert :ok = WorldRetentionWorker.perform(%Oban.Job{})
    assert layout_rows(WorldLayout, obsolete.layout_version) == 0
    assert layout_rows(WorldLayout, abandoned.layout_version) == 0
    assert layout_rows(WorldPosition, obsolete.layout_version) == 0
    assert layout_rows(WorldRelation, obsolete.layout_version) == 0
    assert layout_rows(WorldPosition, abandoned.layout_version) == 0

    Enum.each([active, retained, fresh, pending], fn layout ->
      assert layout_rows(WorldPosition, layout.layout_version) == 1
      assert Ash.get!(WorldLayout, layout.layout_version, actor: scope().actor)
    end)

    assert {:ok, %{generation: 3, layout_version: version}} = World.active_manifest(scope())
    assert version == active.layout_version
    assert {:ok, :idle} = WorldRetention.prune_batch()

    assert :ok = Oban.cancel_job(pending.job_id)
    assert :ok = WorldRetentionWorker.perform(%Oban.Job{})
    assert layout_rows(WorldLayout, pending.layout_version) == 0
    assert layout_rows(WorldPosition, pending.layout_version) == 0
    assert {:ok, :idle} = WorldRetention.prune_batch()
  end

  defp age_layout(version, timestamp) do
    Repo.query!(
      "UPDATE platform.topology_world_layouts SET updated_at = $1 WHERE layout_version = $2::uuid",
      [
        DateTime.to_naive(timestamp),
        Ecto.UUID.dump!(version)
      ]
    )
  end

  defp layout_rows(resource, version) do
    resource
    |> Ash.Query.filter(layout_version == ^version)
    |> Ash.count!(actor: scope().actor)
  end

  defp scope, do: %{actor: SystemActor.system(:topology_world_test)}

  defp position(index) do
    id = "sr:host" <> String.pad_leading(Integer.to_string(index), 2, "0")

    %{
      device_id: id,
      label: "host#{index}.example.com",
      x: index * 100,
      y: index * 200,
      min_zoom: 4,
      parent_id: nil,
      component_id: "SITE01",
      component_z: 0,
      component_x: 0,
      component_y: 0,
      placement_depth: 8,
      active: true
    }
  end

  defp relation(id, source, target) do
    %{
      relation_id: id,
      source_id: position(source).device_id,
      target_id: position(target).device_id,
      evidence_class: "direct",
      role: nil,
      source_if_index: 7,
      source_if_name: "eth7",
      target_if_index: 9,
      target_if_name: "eth9",
      active: true
    }
  end

  defp stage(positions, relations) do
    assert {:ok, layout} =
             World.stage_relayout(scope(), %{
               source_digest: "synthetic-world",
               node_count: length(positions),
               relation_count: length(relations)
             })

    Enum.each(Enum.chunk_every(positions, 500), fn rows ->
      assert :ok = World.append_stage(layout.layout_version, rows, [])
    end)

    Enum.each(Enum.chunk_every(relations, 500), fn rows ->
      assert :ok = World.append_stage(layout.layout_version, [], rows)
    end)

    layout
  end

  defp activate(positions, relations) do
    layout = stage(positions, relations)
    assert {:ok, %{generation: 1}} = World.activate_relayout(0, layout.layout_version)
    layout
  end

  defp collect_world do
    World.stream_active(%{positions: [], relations: []}, fn
      {:manifest, manifest}, acc -> {:ok, Map.put(acc, :manifest, manifest)}
      {:positions, rows}, acc -> {:ok, %{acc | positions: acc.positions ++ rows}}
      {:relations, rows}, acc -> {:ok, %{acc | relations: acc.relations ++ rows}}
    end)
  end

  defp assert_lock_wait(backend, deadline) do
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]) do
      %{rows: [["Lock"]]} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "publication never waited for the bootstrap lock"

        Process.sleep(10)
        assert_lock_wait(backend, deadline)
    end
  end

  defp delete_test_layout(version) do
    uuid = Ecto.UUID.dump!(version)

    Repo.query!("DELETE FROM platform.topology_world_head WHERE active_layout_version = $1", [
      uuid
    ])

    Repo.query!("DELETE FROM platform.topology_world_relations WHERE layout_version = $1", [uuid])
    Repo.query!("DELETE FROM platform.topology_world_positions WHERE layout_version = $1", [uuid])
    Repo.query!("DELETE FROM platform.topology_world_layouts WHERE layout_version = $1", [uuid])

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.topology_world_layouts WHERE layout_version = $1",
               [uuid]
             )
  end
end

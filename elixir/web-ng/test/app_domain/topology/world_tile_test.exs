defmodule ServiceRadarWebNG.Topology.WorldTileTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.TileControl
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldFlow
  alias ServiceRadarWebNG.Topology.WorldOverlayReader
  alias ServiceRadarWebNG.Topology.WorldTile
  alias ServiceRadarWebNG.Topology.WorldTileTest.Upstream
  alias ServiceRadarWebNGWeb.TopologyTileController

  @moduletag :db_free
  @version "00000000-0000-4000-8000-000000000478"
  @stale "00000000-0000-4000-8000-000000000479"

  test "installed geometry serves real encoded receipts and exact relation selectors across publications" do
    {:ok, _applications} = Application.ensure_all_started(:phoenix_pubsub)
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    tasks = start_supervised!({Task.Supervisor, max_children: 4})
    cache = start_supervised!({WorldCache, task_supervisor: tasks, pubsub: pubsub})
    world = world()
    {:ok, root} = TileKey.new(@version, 0, 0, 0)
    {:ok, child} = TileKey.new(@version, 3, 0, 0)
    manifest = %{layout_version: @version, generation: 1, zmax: 16}
    assert {:ok, prepared} = WorldTile.build(world, root)
    assert <<"ARROW1", _rest::binary>> = prepared.payload
    assert byte_size(prepared.payload) <= 262_144
    assert {:ok, _revision} = TileKey.content_revision(prepared.revision)
    assert :ok = WorldCache.install(world, manifest, prepared(world, manifest), cache)
    assert {:ok, first} = WorldCache.fetch(child, :foreground, cache)

    assert {:ok, %{relations: [relation], next_cursor: nil}} =
             TopologyAtlas.tile_relations(world, first.selection)

    assert relation.relation_id == "invented-link-a-b"
    assert [%{count: 1}] = first.flow_edges

    # A fresh native world has different resources but identical geometry. The
    # cache must reuse bytes/revision and attach a selector from the new world.
    next_world = world()
    assert :ok = WorldCache.install(next_world, %{manifest | generation: 2}, prepared(next_world, manifest), cache)
    assert {:ok, second} = WorldCache.fetch(child, :foreground, cache)
    assert second.payload == first.payload
    assert second.revision == first.revision
    assert second.generation == 2

    assert {:ok, %{relations: [%{relation_id: "invented-link-a-b"}]}} =
             TopologyAtlas.tile_relations(next_world, second.selection)

    {:ok, empty_key} = TileKey.new(@version, 3, 7, 7)
    assert {:ok, empty} = WorldCache.fetch(empty_key, :foreground, cache)
    assert <<"ARROW1", _rest::binary>> = empty.payload
    assert empty.flow_edges == []

    assert {:ok, %{relations: [], next_cursor: nil}} =
             TopologyAtlas.tile_relations(next_world, empty.selection)
  end

  test "retained stale links preserve tile health and live traffic without attributing stale traffic" do
    cache = start_named_cache()
    {:ok, builder} = TopologyAtlas.new_builder(@version, 16)
    ids = Enum.map(1..4, &"invented-flow-#{&1}")
    positions = ids |> Enum.with_index(1) |> Enum.map(fn {id, n} -> position(id, n * 200_000) end)
    assert :ok = TopologyAtlas.add_positions(builder, positions)

    relations =
      for {source, target, stale} <- [
            {"invented-flow-1", "invented-flow-2", false},
            {"invented-flow-3", "invented-flow-4", true}
          ] do
        %{
          relation_id: source <> "-link",
          source_id: source,
          target_id: target,
          kind: "CANONICAL_TOPOLOGY",
          evidence_class: "direct-physical",
          telemetry_eligible: true,
          source_if_index: 1,
          target_if_index: 2,
          stale: stale
        }
      end

    assert :ok = TopologyAtlas.add_relations(builder, relations)
    assert {:ok, world} = TopologyAtlas.finish_world(builder)
    manifest = %{layout_version: @version, generation: 1, zmax: 16}
    assert :ok = WorldCache.install(world, manifest, prepared(world, manifest), cache)
    assert {:ok, health} = TopologyAtlas.new_health(world, 1)
    health_owner = __MODULE__.HealthReply

    start_supervised!(
      {Upstream, name: health_owner, reply: {:ok, %{world: world, health: health, manifest: manifest, progress: %{}}}}
    )

    assert {:ok, key} = TileKey.new(@version, 3, 0, 0)
    assert {:ok, tile} = WorldCache.fetch(key, :foreground, cache)

    assert {:ok, overlay} =
             WorldOverlayReader.prepare(key, TileControl.fence(manifest), tile.revision, nil, cache, health_owner)

    assert Enum.sum(Enum.map(overlay.health.glyphs, & &1.counts.total)) == 4
    now = ~U[2001-04-05 06:07:08Z]
    settings = %{window_seconds: 900, freshness_seconds: 120, timeout_ms: 5_000}
    request = WorldFlow.request(overlay.page.relations, now, settings)
    assert Enum.sort(request.pairs) == [{"invented-flow-1", 1}, {"invented-flow-2", 2}]

    rows =
      for id <- ["invented-flow-1", "invented-flow-3"] do
        %{
          "device_id" => id,
          "if_index" => 1,
          "direction" => "out",
          "family" => "octets",
          "status" => "measured",
          "rate" => 64,
          "observed_at" => DateTime.shift(now, second: -10),
          "previous_observed_at" => DateTime.shift(now, second: -70)
        }
      end

    flow = WorldFlow.summarize(overlay.edges, overlay.page, rows, request)
    assert flow.coverage.rendered_relations == 2
    assert flow.coverage.selected_relations == 2

    for relation <- overlay.page.relations do
      edge = Enum.find(flow.edges, &(&1.id == relation.rendered_edge_id))

      if relation.source_id == "invented-flow-1" do
        assert edge.forward.animate
        assert edge.forward.octets_per_second == 64
      else
        refute edge.forward.animate
        refute edge.reverse.animate
        assert edge.forward.octets_per_second == nil
      end
    end
  end

  test "tile HTTP classifies a stale layout before zoom and does not ask the client to retry" do
    cache = start_named_cache()
    world = world()
    manifest = %{layout_version: @version, generation: 1, zmax: 0}
    assert :ok = WorldCache.install(world, manifest, prepared(world, manifest), cache)
    {:ok, installed} = TileKey.new(@version, 0, 0, 0)
    assert {:ok, %{payload: <<"ARROW1", _rest::binary>>}} = WorldCache.fetch(installed)

    assert {409, %{"error" => "layout_changed"}, []} = http(:show, tile_params(@stale, 3))
    assert {400, %{"error" => "invalid_tile"}, []} = http(:show, tile_params(@version, 3))
  end

  test "a malformed overlay revision is rejected and a stopped overlay stays retryable" do
    assert {400, %{"error" => "invalid_revision"}, []} = http(:overlay, overlay_params(String.duplicate("A", 64)))
    assert {503, %{"error" => "world_unavailable"}, ["1"]} = http(:overlay, overlay_params(String.duplicate("a", 64)))
  end

  test "overlay and tile budget failures are client limits, not retryable unavailability" do
    upstream = Upstream

    start_supervised!(
      {upstream, name: ServiceRadarWebNG.Topology.WorldOverlay, reply: {:error, :overlay_budget_exceeded}}
    )

    assert {413, %{"error" => "topology_budget_exceeded"}, []} = http(:overlay, overlay_params(String.duplicate("b", 64)))
    stop_supervised!(upstream)

    start_supervised!({upstream, name: WorldCache, reply: {:error, :tile_budget_exceeded}})
    assert {413, %{"error" => "topology_budget_exceeded"}, []} = http(:show, tile_params(@version, 0))
  end

  test "wire and selection budget overflow generalize without losing membership" do
    for bytes <- [160_000, 1_048_576] do
      id = "invented:" <> String.duplicate("x", bytes)
      assert {:ok, builder} = TopologyAtlas.new_builder(@version, 16)
      assert :ok = TopologyAtlas.add_positions(builder, [position(id, 100)])
      assert {:ok, world} = TopologyAtlas.finish_world(builder)
      assert {:ok, key} = TileKey.new(@version, 0, 0, 0)
      assert {:ok, tile} = WorldTile.build(world, key)
      assert byte_size(tile.payload) <= 262_144
      assert {:ok, health} = TopologyAtlas.new_health(world, 1)
      assert {:ok, %{glyphs: [glyph]}} = TopologyAtlas.tile_health(world, health, tile.selection)
      assert glyph.counts == %{total: 1, observed: 0, healthy: 0, unavailable: 0, unknown: 1}
      assert {:ok, selected} = TopologyAtlas.aggregate_selection(world, tile.selection, glyph.id)
      assert {:ok, %{member_count: 1}} = TopologyAtlas.aggregate_info(selected)
    end
  end

  defp start_named_cache do
    {:ok, _applications} = Application.ensure_all_started(:phoenix_pubsub)
    pubsub = __MODULE__.NamedPubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    tasks = start_supervised!({Task.Supervisor, max_children: 4})
    start_supervised!({WorldCache, name: WorldCache, task_supervisor: tasks, pubsub: pubsub})
  end

  defp http(action, params) do
    conn = apply(TopologyTileController, action, [Plug.Test.conn(:get, "/"), params])
    {conn.status, Jason.decode!(conn.resp_body), Plug.Conn.get_resp_header(conn, "retry-after")}
  end

  defp tile_params(version, z), do: %{"layout_version" => version, "z" => Integer.to_string(z), "x" => "0", "y" => "0"}

  defp overlay_params(revision), do: Map.put(tile_params(@version, 0), "revision", revision)

  defp prepared(world, manifest) do
    Map.new(TileKey.low_zoom(manifest), fn key ->
      {:ok, tile} = WorldTile.build(world, key)
      {key, tile}
    end)
  end

  defp world do
    {:ok, builder} = TopologyAtlas.new_builder(@version, 16)

    :ok =
      TopologyAtlas.add_positions(builder, [
        position("invented-device-a", 300_000),
        position("invented-device-b", 600_000)
      ])

    :ok =
      TopologyAtlas.add_relations(builder, [
        %{relation_id: "invented-link-a-b", source_id: "invented-device-a", target_id: "invented-device-b"}
      ])

    {:ok, world} = TopologyAtlas.finish_world(builder)
    world
  end

  defp position(id, coordinate) do
    %{
      device_id: id,
      label: "Synthetic device",
      x: coordinate,
      y: coordinate,
      min_zoom: 0,
      parent_id: nil,
      component_id: "invented-component",
      component_z: 1,
      component_x: 0,
      component_y: 0,
      placement_depth: 4,
      active: true
    }
  end
end

defmodule ServiceRadarWebNG.Topology.WorldTileTest.Upstream do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :reply), name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(reply), do: {:ok, reply}

  @impl true
  def handle_call(_request, _from, reply), do: {:reply, reply, reply}
end

defmodule ServiceRadarWebNGWeb.TopologyTileChannelLiveDbTest do
  @moduledoc """
  Database-backed coverage for the tile channel's watch contract.

  The pure pieces already have owners: TileKey/TileControl logic lives in
  tile_control_test, and WorldCache admission and HTTP classification live in
  world_tile_test. What only this boundary can prove is the wiring: joining
  through the real authorization path, the ordering of a stale-layout rejection
  ahead of an over-max zoom, and the pushes a republished world produces --
  a generation fence plus an invalidation naming only the watched tiles whose
  geometry changed, never a whole graph.
  """

  use ServiceRadarWebNG.DataCase, async: false

  import Phoenix.ChannelTest

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldTile
  alias ServiceRadarWebNGWeb.TopologyTileChannel
  alias ServiceRadarWebNGWeb.UserSocket

  @moduletag :web_ng_shared_fixture_db

  @endpoint ServiceRadarWebNGWeb.Endpoint

  @version "00000000-0000-4000-8000-000000000521"
  @stale "00000000-0000-4000-8000-000000000522"

  # World coordinates are unsigned 32-bit over a 2^24 extent; at zoom 1 the
  # split is 8_388_608, so these invented devices land one per watched tile.
  @northwest {"invented-god-view-tile-northwest", 1_000_000, 1_000_000, {1, 0, 0}}
  @southeast {"invented-god-view-tile-southeast", 10_000_000, 10_000_000, {1, 1, 1}}
  @added {"invented-god-view-tile-added", 11_000_000, 11_000_000, {1, 1, 1}}

  setup do
    previous_flag = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    user = AccountsFixtures.user_fixture(%{role: :viewer})
    scope = Scope.for_user(user, permissions: RBAC.permissions_for_user(user))

    # The application-supplied cache outlives each test, so every test takes a
    # fresh generation base instead of replaying generation 1.
    generation = next_generation()
    manifest = %{layout_version: @version, generation: generation, zmax: 1}
    initial = world([@northwest, @southeast])
    :ok = WorldCache.install(initial, manifest, prepared(initial, manifest))

    on_exit(fn ->
      if is_nil(previous_flag) do
        Application.delete_env(:serviceradar_web_ng, :god_view_enabled)
      else
        Application.put_env(:serviceradar_web_ng, :god_view_enabled, previous_flag)
      end
    end)

    {:ok, scope: scope, manifest: manifest}
  end

  test "a watch for a replaced layout is rejected as layout_changed before invalid_tiles", %{
    scope: scope,
    manifest: manifest
  } do
    generation = manifest.generation
    {:ok, fence, socket} = join!(scope)
    assert fence == %{layout_version: @version, generation: generation}

    # The same watch carries a stale layout and a zoom past the installed
    # maximum; the layout fence must win, because the client cannot learn
    # anything useful about tiles until it re-reads the manifest.
    ref = push(socket, "tiles:watch", watch(@stale, [{"9", "0", "0"}]))
    assert_reply ref, :error, %{reason: "layout_changed", layout_version: @version, generation: ^generation}

    # On the installed layout the same zoom is a client error about the tiles.
    ref = push(socket, "tiles:watch", watch(@version, [{"9", "0", "0"}]))
    assert_reply ref, :error, %{reason: "invalid_tiles"}

    # A well-formed watch is acknowledged with the fence and a watch id.
    ref = push(socket, "tiles:watch", watch(@version, [{"1", "0", "0"}, {"1", "1", "1"}]))
    assert_reply ref, :ok, %{layout_version: @version, generation: ^generation, watch_id: 1}

    # The first watch has no confirmed revisions, so both watched tiles are
    # delivered as dirty before the test ends.
    assert_push "topology_invalidated", %{dirty_tiles: ["1/0/0", "1/1/1"], reset: false}, 5_000
  end

  test "invalidation pushes name only the watched tiles whose geometry changed", %{
    scope: scope,
    manifest: manifest
  } do
    generation = manifest.generation
    {:ok, _fence, socket} = join!(scope)

    ref = push(socket, "tiles:watch", watch(@version, [{"1", "0", "0"}, {"1", "1", "1"}]))
    assert_reply ref, :ok, %{watch_id: 1}

    assert_push "topology_invalidated",
                %{generation: ^generation, dirty_tiles: ["1/0/0", "1/1/1"], reset: false} = initial,
                5_000

    confirmed = initial.tiles

    # Re-watching with the revisions the client actually retains is a clean
    # acknowledgement: nothing is dirty and the geometry stays cached.
    ref = push(socket, "tiles:watch", watch_with_revisions(@version, confirmed))
    assert_reply ref, :ok, %{watch_id: 2}
    assert_push "topology_invalidated", %{generation: ^generation, dirty_tiles: [], reset: false, tiles: %{}}, 5_000

    # A new generation that adds one device inside 1/1/1 dirties only that
    # tile; the unchanged 1/0/0 keeps its cached geometry and revision.
    republished = %{manifest | generation: generation + 1}
    grew = world([@northwest, @southeast, @added])
    :ok = WorldCache.install(grew, republished, prepared(grew, republished))

    assert_push "topology_generation", %{layout_version: @version} = gen_push, 5_000
    assert gen_push.generation == generation + 1

    assert_push "topology_invalidated",
                %{dirty_tiles: ["1/1/1"], reset: false, tiles: %{"1/1/1" => revision}} = changed,
                5_000

    assert changed.generation == generation + 1
    assert revision != confirmed["1/1/1"]
    refute Map.has_key?(changed.tiles, "1/0/0")
  end

  defp join!(scope) do
    UserSocket
    |> socket("user-id", %{current_scope: scope})
    |> subscribe_and_join(TopologyTileChannel, "topology:tiles", %{})
  end

  # ExUnit shuffles test order, and the application-supplied cache keeps the
  # last generation between tests; each test therefore claims a base higher
  # than any install this module has already made.
  defp next_generation do
    next = :persistent_term.get({__MODULE__, :generation}, 0) + 100
    :persistent_term.put({__MODULE__, :generation}, next)
    next
  end

  defp watch(version, tiles), do: %{"layout_version" => version, "tiles" => Enum.map(tiles, &tile/1)}

  defp watch_with_revisions(version, confirmed) do
    %{
      "layout_version" => version,
      "tiles" => [
        %{"z" => "1", "x" => "0", "y" => "0", "revision" => confirmed["1/0/0"]},
        %{"z" => "1", "x" => "1", "y" => "1", "revision" => confirmed["1/1/1"]}
      ]
    }
  end

  defp tile({z, x, y}), do: %{"z" => z, "x" => x, "y" => y}

  defp world(devices) do
    {:ok, builder} = TopologyAtlas.new_builder(@version, 16)
    :ok = TopologyAtlas.add_positions(builder, Enum.map(devices, &position/1))

    :ok =
      TopologyAtlas.add_relations(builder, [
        %{
          relation_id: "invented-link-northwest-southeast",
          source_id: "invented-god-view-tile-northwest",
          target_id: "invented-god-view-tile-southeast"
        }
      ])

    {:ok, world} = TopologyAtlas.finish_world(builder)
    world
  end

  defp position({id, x, y, component}) do
    {component_z, component_x, component_y} = component

    %{
      device_id: id,
      label: "Synthetic device",
      x: x,
      y: y,
      min_zoom: 0,
      parent_id: nil,
      component_id: "invented-component-#{component_x}-#{component_y}",
      component_z: component_z,
      component_x: component_x,
      component_y: component_y,
      placement_depth: 4,
      active: true
    }
  end

  defp prepared(world, manifest) do
    manifest
    |> TileKey.low_zoom()
    |> Map.new(fn key ->
      {:ok, tile} = WorldTile.build(world, key)
      {key, tile}
    end)
  end
end

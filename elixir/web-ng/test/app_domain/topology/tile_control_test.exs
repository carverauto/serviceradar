defmodule ServiceRadarWebNG.Topology.TileControlTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.TileControl
  alias ServiceRadarWebNG.Topology.TileKey

  @moduletag :db_free

  @layout "00000000-0000-4000-8000-000000000001"
  @next_layout "00000000-0000-4000-8000-000000000002"
  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)

  test "wire tile addresses reject aliases and coordinates outside their quadtree" do
    assert {:ok, %TileKey{layout_version: @layout, z: 24, x: 16_777_215, y: 0}} =
             TileKey.parse(%{"layout_version" => @layout, "z" => "24", "x" => "16777215", "y" => "0"})

    for {z, x, y} <- [{25, 0, 0}, {0, 1, 0}, {2, 0, 4}, {"01", 0, 0}, {1, "-0", 0}, {1, 0, "+1"}, {1, 1.0, 0}] do
      assert {:error, :invalid_tile} = TileKey.new(@layout, z, x, y)
    end

    assert {:error, :invalid_tile} = TileKey.new("not-a-layout", 0, 0, 0)
  end

  test "watch budgets and content revisions survive normalization into the client LRU contract" do
    tile = %{"z" => 1, "x" => 0, "y" => 1, "revision" => @revision_a}

    assert {:ok, %{keys: [%TileKey{z: 1, x: 0, y: 1}], tiles: %{"1/0/1" => @revision_a}}} =
             TileKey.watch(%{"layout_version" => @layout, "tiles" => [tile]})

    for tiles <- [List.duplicate(tile, 65), [Map.put(tile, "revision", "invalid")], [Map.put(tile, "x", 2)], "1/0/1"] do
      assert {:error, :invalid_tiles} = TileKey.watch(%{"layout_version" => @layout, "tiles" => tiles})
    end
  end

  test "affine transforms place quantized neighboring boundaries at the same world coordinate" do
    {:ok, left} = TileKey.new(@layout, 2, 1, 2)
    {:ok, right} = TileKey.new(@layout, 2, 2, 2)
    left = TileKey.transform(left)
    right = TileKey.transform(right)

    assert left.origin_x == 4_194_304
    assert left.origin_y == 8_388_608
    assert right.origin_x == left.origin_x + 65_535 * left.scale
    assert left.scale == right.scale
  end

  test "coalesced publications compare with confirmed bytes and carry unchanged tiles through the generation fence" do
    confirmed = %{layout_version: @layout, generation: 3, tiles: %{"0/0/0" => @revision_a, "1/0/1" => @revision_a}}

    current = %{
      layout_version: @layout,
      generation: 7,
      watch_id: 2,
      tiles: %{"0/0/0" => @revision_b, "1/0/1" => @revision_a}
    }

    assert {:ok, %{generation: 7, watch_id: 2, reset: false, dirty_tiles: ["0/0/0"], tiles: %{"0/0/0" => @revision_b}}} =
             TileControl.reconcile(confirmed, current)

    assert {:ok, %{generation: 8, reset: false, dirty_tiles: [], tiles: %{}}} =
             TileControl.reconcile(current, %{current | generation: 8})

    assert {:error, :stale_generation} = TileControl.reconcile(current, confirmed)
    assert TileControl.fence(current) == %{layout_version: @layout, generation: 7}
  end

  test "layout replacement invalidates all watched geometry without comparing unrelated revisions" do
    previous = %{layout_version: @layout, generation: 1, tiles: %{"0/0/0" => @revision_a}}
    current = %{layout_version: @next_layout, generation: 2, tiles: %{"0/0/0" => @revision_a}}

    assert {:ok, %{reset: true, dirty_tiles: ["0/0/0"]}} = TileControl.reconcile(previous, current)
  end
end

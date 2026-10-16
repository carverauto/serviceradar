defmodule ServiceRadarWebNG.Topology.BitmapIndexNativeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.Native

  @moduletag :db_free

  test "oversized canonical values disable only their facet and preserve pinned revisions" do
    dictionary = <<5::128>>
    epoch = <<6::128>>
    authority = <<7::256>>
    assert {:ok, index} = Native.bitmap_index_new(dictionary, epoch, :device, ["vendor", "os_name"])

    assert {:ok, %{revision: 1}} =
             Native.bitmap_index_publish(index, 0, "seed", [{1, true, [{"os_name", "example-os"}]}], true)

    assert {:ok, {old_query, 1, "seed", 1}} =
             Native.bitmap_index_query(
               index,
               dictionary,
               epoch,
               :device,
               authority,
               [{0, "os_name", "example-os", 0}],
               1000
             )

    assert {:ok, %{revision: 2, cardinality: 2, unavailable_facets: ["os_name"]}} =
             Native.bitmap_index_publish(
               index,
               1,
               "changed",
               [{2, true, [{"os_name", String.duplicate("x", 257)}]}],
               true
             )

    assert {:error, "facet_unavailable"} =
             Native.bitmap_index_query(
               index,
               dictionary,
               epoch,
               :device,
               authority,
               [{0, "os_name", "example-os", 0}],
               1000
             )

    assert {:ok, {query, 2, "changed", 2}} =
             Native.bitmap_index_query(index, dictionary, epoch, :device, authority, [{0, "vendor", "unknown", 0}], 1000)

    assert {:ok, [1, 2]} = Native.bitmap_query_page(query, authority, 0, 128, 1000)
    assert {:ok, [1]} = Native.bitmap_query_page(old_query, authority, 0, 128, 1000)
    assert {:ok, _} = Native.bitmap_index_close(index)
  end

  test "typed resource calls preserve binary epochs, full unsigned IDs and portable membership" do
    dictionary = <<1::128>>
    epoch = <<2::128>>
    authority = <<3::256>>
    source = <<255, 0, 128, 1>>

    assert {:ok, index} = Native.bitmap_index_new(dictionary, epoch, :device, ["vendor", "availability"])

    assert {:ok, %{revision: 1, source_revision: ^source, cardinality: 2, ready: true}} =
             Native.bitmap_index_publish(
               index,
               0,
               source,
               [
                 {7, true, [{"vendor", "example-a"}, {"availability", "healthy"}]},
                 {4_294_967_295, true, [{"vendor", "example-b"}]}
               ],
               true
             )

    assert {:ok, {query, 1, ^source, 1}} =
             Native.bitmap_index_query(
               index,
               dictionary,
               epoch,
               :device,
               authority,
               [{0, "vendor", "example-b", 0}],
               1000
             )

    assert {:ok, [4_294_967_295]} = Native.bitmap_query_page(query, authority, 0, 128, 1000)

    assert {:ok, [1, 0]} =
             Native.bitmap_query_facets(
               query,
               authority,
               [{"availability", "unknown"}, {"availability", "healthy"}],
               1000
             )

    portable = aggregate_membership(dictionary)

    assert {:ok, {<<0, 1, 0, 1>>, <<3, 3, 3, 3>>, <<2, 2, 2, 2>>, counts}} =
             Native.bitmap_query_row_overlay(
               query,
               authority,
               dictionary,
               epoch,
               :device,
               [{:leaf, 7}, {:leaf, 4_294_967_295}, {:leaf, 0}, {:aggregate, portable}],
               1000
             )

    assert counts == <<0::little-32, 1::little-32, 0::little-32, 1::little-32>>

    assert {:error, "list_budget"} =
             Native.bitmap_index_publish(index, 1, source, List.duplicate({7, false, []}, 501), true)

    assert {:ok, 1} =
             Native.bitmap_query_intersection_count(query, authority, dictionary, epoch, :device, portable, 1000)

    assert {:error, "identity_mismatch"} =
             Native.bitmap_query_intersection_count(query, authority, dictionary, epoch, :interface, portable, 1000)

    assert {:error, "authority_mismatch"} = Native.bitmap_query_page(query, <<4::256>>, 0, 128, 1000)
    assert {:ok, _} = Native.bitmap_index_close(index)
    assert {:error, "not_ready"} = Native.bitmap_query_page(query, authority, 0, 128, 1000)
    assert {:ok, %{cardinality: 0, ready: false}} = Native.bitmap_index_status(index)
  end

  test "native reader saturation is retryable and a released response restores admission" do
    dictionary = <<11::128>>
    epoch = <<12::128>>
    authority = <<13::256>>
    assert {:ok, index} = Native.bitmap_index_new(dictionary, epoch, :device, ["vendor"])
    on_exit(fn -> Native.bitmap_index_close(index) end)
    assert {:ok, _} = Native.bitmap_index_publish(index, 0, "seed", [{17, true, [{"vendor", "example"}]}], true)

    query = fn ->
      Native.bitmap_index_query(index, dictionary, epoch, :device, authority, [{0, "vendor", "example", 0}], 1000)
    end

    pins =
      for _ <- 1..8 do
        assert {:ok, {pin, 1, "seed", 1}} = query.()
        pin
      end

    assert {:error, "pin_budget"} = saturated = query.()
    assert {:error, :query_busy} = BitmapQueries.normalize(saturated)
    assert {:ok, _} = Native.bitmap_query_close(hd(pins))
    assert {:ok, {replacement, 1, "seed", 1}} = query.()
    assert {:ok, [17]} = Native.bitmap_query_page(replacement, authority, 0, 128, 1000)

    assert {:error, :forbidden} =
             replacement
             |> Native.bitmap_query_page(<<14::256>>, 0, 128, 1000)
             |> BitmapQueries.normalize()

    for pin <- [replacement | tl(pins)], do: Native.bitmap_query_close(pin)
    assert {:ok, _} = Native.bitmap_index_close(index)
    assert {:error, :index_not_ready} = BitmapQueries.normalize(query.())
  end

  test "dirty hints use unsigned ordinals and fence full-pass acknowledgements" do
    assert {:ok, index} = Native.bitmap_index_new(<<1::128>>, <<2::128>>, :device, ["vendor"])

    assert {:ok, %{pending_count: 2, rescan_needed: true, rescan_generation: generation}} =
             Native.bitmap_index_mark_dirty(index, [4_294_967_295, 7, 7], true)

    assert {:ok, {[7], %{pending_count: 1}}} = Native.bitmap_index_take_dirty(index, 1)
    assert {:ok, %{pending_count: 2}} = Native.bitmap_index_mark_dirty(index, [7], true)
    assert {:error, "stale_reconcile"} = Native.bitmap_index_acknowledge_reconcile(index, generation)

    assert {:ok, %{pending: %{rescan_needed: true, rescan_generation: current}}} =
             Native.bitmap_index_status(index)

    assert {:ok, %{pending_count: 2, rescan_needed: false}} =
             Native.bitmap_index_acknowledge_reconcile(index, current)

    assert {:ok, {[7, 4_294_967_295], %{pending_count: 0}}} = Native.bitmap_index_take_dirty(index, 500)
    assert {:error, "list_budget"} = Native.bitmap_index_mark_dirty(index, List.duplicate(7, 501), false)
    assert {:error, "invalid_dirty_batch"} = Native.bitmap_index_mark_dirty(index, [0], false)
    assert {:ok, _} = Native.bitmap_index_close(index)
  end

  defp aggregate_membership(dictionary) do
    positions =
      for n <- 1..2 do
        %{
          device_id: "sr:overlay-#{n}.example.com",
          label: "Synthetic overlay device",
          x: n,
          y: n,
          min_zoom: 24,
          parent_id: nil,
          component_id: "synthetic-component",
          component_z: 1,
          component_x: 0,
          component_y: 0,
          placement_depth: 4,
          active: true
        }
      end

    assert {:ok, builder} = TopologyAtlas.new_builder("synthetic-overlay-layout", 16)
    assert :ok = TopologyAtlas.add_positions(builder, positions)
    assert {:ok, world} = TopologyAtlas.finish_world(builder)
    assert {:ok, mapping} = TopologyAtlas.new_ordinals(world, dictionary)

    assert {:ok, _} =
             TopologyAtlas.apply_ordinals(world, mapping, [
               {hd(positions).device_id, 7},
               {List.last(positions).device_id, 4_294_967_295}
             ])

    assert {:ok, _} = TopologyAtlas.seal_ordinals(world, mapping)
    assert {:ok, tile} = TopologyAtlas.tile(world, 0, 0, 0)
    aggregate = Enum.find(tile.glyphs, &(&1.kind == :aggregate))
    assert {:ok, selection} = TopologyAtlas.aggregate_selection(world, tile.selection, aggregate.id)
    assert {:ok, bytes} = TopologyAtlas.aggregate_ordinals(world, mapping, selection, 1000)
    bytes
  end
end

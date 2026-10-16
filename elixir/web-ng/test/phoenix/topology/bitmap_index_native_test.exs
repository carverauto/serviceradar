defmodule ServiceRadarWebNG.Topology.BitmapIndexNativeTest do
  use ExUnit.Case, async: true

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

    assert {:ok, portable} = Native.bitmap_query_view(query, authority, [7, 4_294_967_295], 1000)

    assert {:ok, [^portable, unknown]} =
             Native.bitmap_query_view_sets(query, authority, [7, 4_294_967_295], [{"availability", "unknown"}], 1000)

    assert unknown == portable

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
end

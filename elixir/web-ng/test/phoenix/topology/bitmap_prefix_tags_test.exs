defmodule ServiceRadarWebNG.Topology.BitmapPrefixTagsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.NativeEngine
  alias ServiceRadar.PrefixTags.Registry
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadarWebNG.Topology.BitmapExpression
  alias ServiceRadarWebNG.Topology.BitmapPrefixTags
  alias ServiceRadarWebNG.Topology.Native

  @moduletag :db_free
  @source "bitmap-synthetic-catalog"
  @authority <<51::256>>

  setup do
    if !Process.whereis(Registry), do: start_supervised!(Registry)
    previous = Application.fetch_env(:serviceradar_core, :prefix_tags_engine)
    Application.put_env(:serviceradar_core, :prefix_tags_engine, NativeEngine)

    on_exit(fn ->
      Store.clear(@source)

      case previous do
        {:ok, value} -> Application.put_env(:serviceradar_core, :prefix_tags_engine, value)
        :error -> Application.delete_env(:serviceradar_core, :prefix_tags_engine)
      end
    end)

    :ok
  end

  test "local label selection reaches the typed address index and live catalog cursors fence authority and source changes" do
    Store.put_rows(@source, [
      %{prefix: "192.0.2.0/24", tags: ["alpha", "shared"]},
      %{prefix: "192.0.2.7/32", tags: ["host"]},
      %{prefix: "198.51.100.0/24", tags: ["beta", "shared"]}
    ])

    assert {:error, "catalog_not_ready"} = BitmapPrefixTags.page(%{"source" => @source}, @authority, deadline())
    assert {:ok, :ready} = BitmapPrefixTags.prepare(@source, deadline())

    assert {:ok, %{labels: ["alpha"], cursor: cursor}} =
             BitmapPrefixTags.page(%{"source" => @source, "limit" => "1"}, @authority, deadline())

    assert is_binary(cursor)

    assert {:error, :invalid_cursor} =
             BitmapPrefixTags.page(%{"source" => @source, "cursor" => cursor}, <<52::256>>, deadline())

    dictionary = <<53::128>>
    epoch = <<54::128>>
    assert {:ok, index} = Native.bitmap_index_new(dictionary, epoch, :device, ["vendor"])
    on_exit(fn -> Native.bitmap_index_close(index) end)

    assert {:ok, stage} =
             Native.bitmap_index_begin_publish(index, 0, "addresses", [{1, true, []}, {2, true, []}, {3, true, []}], true)

    assert {:ok, %{ip_available: true}} =
             Native.bitmap_publish_addresses(
               stage,
               [{1, <<192, 0, 2, 7>>}, {2, <<198, 51, 100, 7>>}, {3, <<203, 0, 113, 7>>}],
               [1, 2, 3]
             )

    assert {:ok, _} = Native.bitmap_index_finish_publish(index, stage)

    for {label, expected} <- [{"alpha", [1]}, {"shared", [1, 2]}, {"missing", []}] do
      assert {:ok, parsed} =
               BitmapExpression.parse(%{"expression" => %{"prefix_tag" => %{"source" => @source, "label" => label}}}, [])

      assert {:ok, program, versions} = BitmapPrefixTags.resolve(parsed.program, deadline())
      assert :ok = BitmapPrefixTags.current(versions)

      assert {:ok, {query, _, _, _}} =
               Native.bitmap_index_query(index, dictionary, epoch, :device, @authority, program, 1_000)

      assert {:ok, ^expected} = Native.bitmap_query_page(query, @authority, 0, 128, 1_000)
      Native.bitmap_query_close(query)
    end

    {:ok, captured} = Store.capture(@source)
    Store.put_rows(@source, [%{prefix: "203.0.113.0/24", tags: ["beta", "zeta"]}])
    assert {:error, :source_changed} = BitmapPrefixTags.current(%{@source => captured.version})
    assert {:ok, :ready} = BitmapPrefixTags.prepare(@source, deadline())

    assert {:ok, %{labels: ["beta", "zeta"], cursor: nil}} =
             BitmapPrefixTags.page(%{"source" => @source, "cursor" => cursor}, @authority, deadline())

    assert [] = BitmapPrefixTags.release([@source])
    assert {:error, "catalog_not_ready"} = BitmapPrefixTags.page(%{"source" => @source}, @authority, deadline())
  end

  test "a catalog refused by the shared native budget is reported per source and retried after replacement" do
    Store.put_rows(@source, [%{prefix: "192.0.2.0/24", tags: List.duplicate("synthetic", 360_000)}])

    assert {:error, "catalog_budget"} = BitmapPrefixTags.prepare(@source, deadline())
    assert %{available: false, reason: "catalog_budget"} = source_entry(BitmapPrefixTags.descriptor())
    assert {:error, "catalog_not_ready"} = BitmapPrefixTags.page(%{"source" => @source}, @authority, deadline())

    Store.put_rows(@source, [%{prefix: "192.0.2.0/24", tags: ["synthetic"]}])

    assert {:ok, :ready} = BitmapPrefixTags.prepare(@source, deadline())
    assert %{available: true} = entry = source_entry(BitmapPrefixTags.descriptor())
    refute Map.has_key?(entry, :reason)

    assert {:ok, %{labels: ["synthetic"], cursor: nil}} =
             BitmapPrefixTags.page(%{"source" => @source}, @authority, deadline())

    assert [] = BitmapPrefixTags.release([@source])
  end

  defp source_entry(descriptor), do: Enum.find(descriptor.sources, &(&1.source == @source))

  defp deadline, do: System.monotonic_time(:millisecond) + 1_000
end

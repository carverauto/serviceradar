defmodule ServiceRadarWebNG.Topology.AtlasStoreTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.Atlas
  alias ServiceRadarWebNG.Topology.AtlasStore

  @moduletag :db_free

  setup do
    store = start_supervised!(%{id: AtlasStore, start: {AtlasStore, :start_link, [[]]}})
    %{store: store}
  end

  test "startup is unavailable until a complete index is published", %{store: store} do
    assert {:error, :not_ready} = AtlasStore.fetch("global", store)
    assert {:error, :not_ready} = AtlasStore.fetch_many(["global"], store)

    {:ok, atlas} = Atlas.build([], [])
    assert :ok = AtlasStore.publish(atlas, store)
    assert {:ok, %{nodes: [], edges: [], kind: "global"}} = AtlasStore.fetch("global", store)
  end

  test "publication exposes bounded levels and reports removed cached children", %{store: store} do
    nodes = [%{id: "host01.example.com"}, %{id: "host02.example.com"}]

    edges = [
      %{source: "host01.example.com", target: "host02.example.com", evidence_class: "direct"}
    ]

    {:ok, atlas} = Atlas.build(nodes, edges)
    :ok = AtlasStore.publish(atlas, store)

    assert {:ok, %{nodes: [%{child_level_id: child}], revision: revision, canonical_revision: canonical}} =
             AtlasStore.fetch("global", store)

    assert canonical == atlas.revision

    assert {:ok, %{canonical_revision: ^canonical, levels: selected}} =
             AtlasStore.fetch_many(["global", "global:00:0", child], store)

    assert Enum.sort(Map.keys(selected)) == Enum.sort(["global", child])
    assert Enum.all?(selected, fn {_id, level} -> level.canonical_revision == canonical end)
    assert Enum.map(selected[child].nodes, & &1.id) == Enum.map(nodes, & &1.id)

    {:ok, empty} = Atlas.build([], [])
    :ok = AtlasStore.publish(empty, store)

    assert {:ok, %{canonical_revision: empty_canonical, levels: empty_selection}} =
             AtlasStore.fetch_many(["global:0:0", child], store)

    assert empty_canonical == empty.revision
    assert empty_selection["global"].canonical_revision == empty_canonical
    assert empty_selection["global"].nodes == []
    refute empty_selection["global"].revision == revision
    assert Map.fetch!(empty_selection, child) == nil
    assert {:ok, %{canonical_revision: ^empty_canonical, levels: %{}}} = AtlasStore.fetch_many([], store)
  end

  test "watch and identifier limits reject oversized requests before querying the index", %{
    store: store
  } do
    assert {:error, :invalid_level} = AtlasStore.fetch(String.duplicate("a", 2_049), store)
    assert {:error, :invalid_level} = AtlasStore.fetch("", store)

    for ids <- [List.duplicate("global:0:0", 65), [nil], ["global:+1:0"], ["members::0:0"], "global"] do
      assert {:error, :invalid_levels} = AtlasStore.fetch_many(ids, store)
    end
  end
end

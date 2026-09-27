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
    assert {:error, :not_ready} = AtlasStore.fetch("global", nil, store)
    assert {:error, :not_ready} = AtlasStore.revisions(["global"], store)

    {:ok, atlas} = Atlas.build([], [])
    assert :ok = AtlasStore.publish(atlas, store)
    assert {:ok, %{nodes: [], edges: [], kind: "global"}} = AtlasStore.fetch("global", nil, store)
  end

  test "publication exposes bounded levels and reports removed cached children", %{store: store} do
    nodes = [%{id: "host01.example.com"}, %{id: "host02.example.com"}]

    edges = [
      %{source: "host01.example.com", target: "host02.example.com", evidence_class: "direct"}
    ]

    {:ok, atlas} = Atlas.build(nodes, edges)
    :ok = AtlasStore.publish(atlas, store)

    assert {:ok, %{nodes: [%{child_level_id: child}], revision: revision}} =
             AtlasStore.fetch("global", nil, store)

    assert {:ok, %{levels: %{"global" => %{revision: ^revision}} = revisions}} =
             AtlasStore.revisions(["global", child], store)

    assert %{revision: child_revision} = Map.fetch!(revisions, child)
    assert {:ok, %{revision: ^child_revision}} = AtlasStore.fetch(child, child_revision, store)

    {:ok, empty} = Atlas.build([], [])
    :ok = AtlasStore.publish(empty, store)
    assert {:ok, %{levels: levels}} = AtlasStore.revisions(["global", child], store)
    assert Map.fetch!(levels, child) == nil
    assert levels["global"].revision != revision
    assert {:error, {:stale_revision, _current}} = AtlasStore.fetch("global", revision, store)
  end

  test "watch and identifier limits reject oversized requests before querying the index", %{
    store: store
  } do
    assert {:error, :invalid_levels} = AtlasStore.revisions(List.duplicate("global", 65), store)
    assert {:error, :invalid_levels} = AtlasStore.revisions([nil], store)
    assert {:error, :invalid_level} = AtlasStore.fetch(String.duplicate("a", 2_049), nil, store)
    assert {:error, :invalid_level} = AtlasStore.fetch("", nil, store)
  end
end

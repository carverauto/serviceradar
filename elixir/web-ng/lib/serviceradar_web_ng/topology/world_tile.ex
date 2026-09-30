defmodule ServiceRadarWebNG.Topology.WorldTile do
  @moduledoc """
  Builds bounded schema-3 geometry while retaining its exact native selection.

  Revisions hash the deterministic Arrow encoding before the tile_revision
  metadata entry is added. Telemetry and publication generation are excluded,
  so unchanged geometry keeps its ETag across publications.
  """

  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.TileKey

  # Compact identities bound bytes without changing the publication's shared
  # routing grade. Reducing per-tile portal budgets would break adjacency.
  @profiles [
    %{profile: :standard, nodes: 128, edges: 512},
    %{profile: :aggregate_only, nodes: 128, edges: 512}
  ]

  def build(world, %TileKey{} = key) do
    with {:ok, %{layout_version: version}} <- TopologyAtlas.world_info(world),
         true <- version == key.layout_version do
      build(world, key, @profiles)
    else
      false -> {:error, :layout_changed}
      error -> error
    end
  end

  defp build(_world, _key, []), do: {:error, :payload_too_large}

  defp build(world, key, [budget | rest]) do
    with {:ok, tile} <- TopologyAtlas.tile(world, key.z, key.x, key.y, budget),
         {:ok, encoded} <- encode(tile, key, budget) do
      {:ok, encoded}
    else
      {:error, "scene_budget_exceeded"} -> build(world, key, rest)
      {:error, :selection_budget_exceeded} -> build(world, key, rest)
      error -> error
    end
  end

  defp encode(tile, key, budget) do
    transform = TileKey.transform(key)
    payload = payload(tile, transform)
    metadata = metadata(tile, key, budget, transform)

    with {:ok, canonical} <- Native.encode_scene(payload, metadata),
         revision = :sha256 |> :crypto.hash(canonical) |> Base.encode16(case: :lower),
         {:ok, bytes} <- Native.encode_scene(payload, Map.put(metadata, "tile_revision", revision)) do
      {:ok,
       %{
         payload: bytes,
         revision: revision,
         selection: tile.selection,
         selection_bytes: tile.selection_bytes,
         flow_edges:
           tile.edges
           |> Enum.reject(&(&1.stale == true))
           |> Enum.map(&Map.take(&1, [:id, :count]))
       }}
    end
  end

  defp payload(tile, transform) do
    %{
      schema_version: 3,
      revision: 0,
      nodes: Enum.map(tile.glyphs, &node(&1, transform)),
      edges: Enum.map(tile.edges, &{&1.source, &1.target, 0, 0, 0, "", 0}),
      edge_meta: Enum.map(tile.edges, &{&1.topology_class, "", ""}),
      edge_directional: [],
      edge_details: Enum.map(tile.edges, &edge_details/1),
      root_bitmap_bytes: 0,
      affected_bitmap_bytes: 0,
      healthy_bitmap_bytes: 0,
      unknown_bitmap_bytes: 0
    }
  end

  defp node(glyph, transform) do
    details = Jason.encode!(%{id: glyph.id, type: glyph.kind, cluster_member_count: glyph.count})

    {quantize(glyph.x, transform.origin_x, transform.scale), quantize(glyph.y, transform.origin_y, transform.scale), 3,
     glyph.label, 0, 0, details}
  end

  defp quantize(value, origin, scale),
    do: value |> Kernel.-(origin) |> Kernel./(scale) |> round() |> max(0) |> min(65_535)

  defp edge_details(edge) do
    Jason.encode!(%{
      id: edge.id,
      represented_count: edge.count,
      phase_start: edge.start,
      phase_end: edge.end,
      stale: edge.stale == true
    })
  end

  defp metadata(tile, key, budget, transform) do
    Map.new(
      %{
        payload_kind: "tile",
        layout_version: key.layout_version,
        z: key.z,
        x: key.x,
        y: key.y,
        coordinate_space: "tile-local-u16",
        world_extent: 16_777_216,
        origin_x: transform.origin_x,
        origin_y: transform.origin_y,
        coordinate_scale: transform.scale,
        profile: budget.profile,
        max_nodes: budget.nodes,
        max_edges: budget.edges,
        max_encoded_bytes: 262_144,
        device_count: tile.device_count,
        internal_relations: tile.internal_relations
      },
      fn {name, value} -> {Atom.to_string(name), to_string(value)} end
    )
  end
end

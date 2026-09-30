defmodule WorldBrowserFixture do
  @moduledoc false
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldScene
  alias ServiceRadarWebNG.Topology.WorldTile

  @version "00000000-0000-4000-8000-000000004774"

  def run(input, output) do
    {:ok, _} = Application.ensure_all_started(:crypto)
    {:ok, builder} = TopologyAtlas.new_builder(@version, 16)
    started = System.monotonic_time(:millisecond)

    input
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&(&1 |> String.trim_trailing("\n") |> String.split("\t")))
    |> Stream.chunk_every(500)
    |> Enum.each(fn rows ->
      for {kind, batch} <- Enum.group_by(rows, &hd/1) do
        case kind do
          "p" -> :ok = TopologyAtlas.add_positions(builder, Enum.map(batch, &position/1))
          "r" -> :ok = TopologyAtlas.add_relations(builder, Enum.map(batch, &relation/1))
        end
      end
    end)

    {:ok, world} = TopologyAtlas.finish_world(builder)
    {:ok, %{node_count: 1_000_000, relation_count: 2_000_000, bounds: bounds}} = TopologyAtlas.world_info(world)
    import_ms = System.monotonic_time(:millisecond) - started
    samples = Enum.map(["sr:node-0000011.example.test", "sr:node-0500011.example.test"], &sample(world, &1))
    {:ok, health} = TopologyAtlas.new_health(world, 1)
    started = System.monotonic_time(:millisecond)

    tiles =
      samples
      |> keys(bounds)
      |> Map.new(fn key ->
        {:ok, tile} = WorldTile.build(world, key)
        true = byte_size(tile.payload) <= 262_144
        {:ok, rollup} = TopologyAtlas.tile_health(world, health, tile.selection)
        id = "#{key.z}/#{key.x}/#{key.y}"

        {id,
         %{
           bytes: Base.encode64(tile.payload),
           revision: tile.revision,
           health: rollup,
           flow: %{edges: Enum.map(tile.flow_edges, &flow/1)}
         }}
      end)

    # Every low-zoom tile is included, so independently sum actual native
    # rollups over each complete partition, including empty tiles.
    for z <- 0..3 do
      total =
        tiles
        |> Enum.filter(fn {key, _} -> String.starts_with?(key, "#{z}/") end)
        |> Enum.flat_map(fn {_, tile} -> tile.health.glyphs end)
        |> Enum.map(& &1.counts.total)
        |> Enum.sum()

      1_000_000 = total
    end

    [_, layout_ms] = input |> File.stream!() |> Enum.take(1) |> hd() |> String.trim() |> String.split("\t")

    result = %{
      manifest: %{
        layout_version: @version,
        generation: 1,
        zmax: 16,
        extent: 16_777_216,
        node_count: 1_000_000,
        relation_count: 2_000_000,
        bounds: bounds
      },
      samples: samples,
      tiles: tiles,
      measurements: %{
        layout_ms: String.to_integer(layout_ms),
        import_ms: import_ms,
        tile_encode_ms: System.monotonic_time(:millisecond) - started
      }
    }

    File.write!(output, Jason.encode!(result))
    IO.puts("million-device browser fixture: #{map_size(tiles)} encoded tiles; #{inspect(result.measurements)}")
  end

  defp position(["p", id, label, x, y, zoom, parent, component, z, cx, cy, depth]) do
    %{
      device_id: id,
      label: label,
      x: String.to_integer(x),
      y: String.to_integer(y),
      min_zoom: String.to_integer(zoom),
      parent_id: if(parent == "", do: nil, else: parent),
      component_id: component,
      component_z: String.to_integer(z),
      component_x: String.to_integer(cx),
      component_y: String.to_integer(cy),
      placement_depth: String.to_integer(depth),
      active: true
    }
  end

  defp relation(["r", id, source, target]), do: %{relation_id: id, source_id: source, target_id: target}

  defp sample(world, id) do
    {:ok, position} = TopologyAtlas.search(world, id)
    {:ok, detail} = TopologyAtlas.detail(world, {:neighborhood, id})

    nodes =
      Enum.map(
        detail.nodes,
        &%{id: &1.device_id, label: &1.label, health_signal: :unknown, details: %{id: &1.device_id, type: "device"}}
      )

    edges =
      Enum.map(
        detail.relations,
        &%{
          id: &1.id,
          source: Enum.at(detail.nodes, &1.source).device_id,
          target: Enum.at(detail.nodes, &1.target).device_id,
          evidence_class: :direct_physical,
          role: :unknown
        }
      )

    level = %{
      nodes: nodes,
      edges: edges,
      level_id: id,
      parent_level_id: "world",
      revision: 1,
      structure_revision: "invented",
      layout_version: @version,
      generation: 1,
      next_cursor: nil,
      kind: :neighborhood
    }

    {:ok, scene} = WorldScene.encode(level)
    %{device_id: id, x: position.x, y: position.y, zoom: position.min_zoom, scene: Base.encode64(scene.payload)}
  end

  defp keys(samples, bounds) do
    low = for z <- 0..3, x <- 0..(2 ** z - 1), y <- 0..(2 ** z - 1), do: {z, x, y}

    high =
      for sample <- samples,
          z <- 4..16,
          dx <- -4..4,
          dy <- -4..4,
          x = div(sample.x, 2 ** (24 - z)) + dx,
          y = div(sample.y, 2 ** (24 - z)) + dy,
          x >= 0 and y >= 0 and x < 2 ** z and y < 2 ** z,
          do: {z, x, y}

    # Include the continuous search flights, not just their destinations.
    # The renderer may adopt the destination zoom before the target finishes
    # interpolation, so cover that zoom over the whole invented route too.
    [[left, top], [right, bottom]] = bounds
    origin = %{x: (left + right) / 2, y: (top + bottom) / 2, zoom: 0}

    flights =
      for [from, to] <- Enum.chunk_every([origin | samples], 2, 1, :discard),
          step <- 0..256,
          fraction = step / 256,
          z <- Enum.uniq([to.zoom, floor(from.zoom + (to.zoom - from.zoom) * fraction)]),
          dx <- -4..4,
          dy <- -4..4,
          x = floor((from.x + (to.x - from.x) * fraction) / 2 ** (24 - z)) + dx,
          y = floor((from.y + (to.y - from.y) * fraction) / 2 ** (24 - z)) + dy,
          x >= 0 and y >= 0 and x < 2 ** z and y < 2 ** z,
          do: {z, x, y}

    (low ++ high ++ flights)
    |> Enum.uniq()
    |> Enum.map(fn {z, x, y} ->
      {:ok, key} = TileKey.new(@version, z, x, y)
      key
    end)
  end

  defp flow(%{id: id, count: count}) do
    %{
      id: id,
      total_relations: count,
      selected_relations: count,
      forward: %{status: "measured", animate: true, packets_per_second: 120, octets_per_second: 12_000},
      reverse: %{status: "measured", animate: true, packets_per_second: 75, octets_per_second: 7500}
    }
  end
end

[input, output] = System.argv()
WorldBrowserFixture.run(input, output)

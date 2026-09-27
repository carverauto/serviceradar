defmodule ServiceRadar.TopologyAtlas do
  @moduledoc """
  Native topology world construction and bounded reads.

  Import persisted positions (including inactive reservations), active relations,
  and projected inventory in batches of at most 500. Finish a cold world or
  reconcile with a canonical Dgraph snapshot, then publish bounded candidate
  pages through `NetworkDiscovery.World`. Builders and graph snapshots are
  consumed once; worlds and candidates are immutable process-local resources.

  Canonical IDs remain intact. Labels are limited to 256 UTF-8 bytes by the
  inventory projector. Tile budgets are at most 128 glyphs and 256 relations.
  Cursors start at zero, and `next_cursor: nil` ends a publication stream.
  Resources must never be serialized into jobs or persisted as database values.
  """

  alias ServiceRadar.Dgraph
  alias ServiceRadar.TopologyAtlas.Native

  @relation_defaults %{
    evidence_class: nil,
    role: nil,
    source_if_index: nil,
    source_if_name: nil,
    target_if_index: nil,
    target_if_name: nil,
    active: true
  }
  @operations [
    :insert_positions,
    :update_positions,
    :activate_device_ids,
    :deactivate_device_ids,
    :upsert_relations,
    :deactivate_relation_ids
  ]

  defguardp valid_page(cursor, limit)
            when is_integer(cursor) and cursor in 0..4_294_967_295 and is_integer(limit) and limit in 1..500

  def new_builder(layout_version, zmax) when is_binary(layout_version) and is_integer(zmax) and zmax in 0..24,
    do: Native.new_builder(layout_version, zmax)

  def new_builder(_layout_version, _zmax), do: {:error, :invalid_layout}

  def add_positions(builder, rows) when is_list(rows), do: Native.add_positions(builder, rows)
  def add_positions(_builder, _rows), do: {:error, :invalid_rows}

  def add_inventory(builder, rows) when is_list(rows), do: Native.add_inventory(builder, rows)
  def add_inventory(_builder, _rows), do: {:error, :invalid_rows}

  def add_relations(builder, rows) when is_list(rows) do
    # Bound the walk before normalizing optional fields on Ash resource rows.
    if length(Enum.take(rows, 501)) <= 500 and Enum.all?(rows, &is_map/1) do
      Native.add_relations(builder, Enum.map(rows, &Map.merge(@relation_defaults, &1)))
    else
      {:error, :invalid_rows}
    end
  end

  def add_relations(_builder, _rows), do: {:error, :invalid_rows}

  defdelegate finish_world(builder), to: Native
  defdelegate reconcile(builder, graph), to: Native
  defdelegate world_info(world), to: Native
  defdelegate candidate_info(candidate), to: Native

  @doc "Read the canonical graph directly into a native resource from one paged Dgraph snapshot."
  def read_graph do
    with {:ok, url} <- Dgraph.url(), do: Native.read_graph(url)
  end

  def tile(world, z, x, y, budget \\ %{nodes: 128, edges: 256})

  def tile(world, z, x, y, %{nodes: nodes, edges: edges} = budget)
      when is_integer(z) and z in 0..24 and is_integer(x) and x in 0..16_777_215 and is_integer(y) and y in 0..16_777_215 and
             is_integer(nodes) and nodes in 9..128 and is_integer(edges) and edges in 72..256,
      do: Native.tile(world, z, x, y, budget)

  def tile(_world, _z, _x, _y, _budget), do: {:error, :invalid_tile}

  def search(world, id) when is_binary(id), do: Native.search(world, id)
  def search(_world, _id), do: {:error, :invalid_identity}

  def positions_page(candidate, cursor, limit \\ 500)

  def positions_page(candidate, cursor, limit) when valid_page(cursor, limit),
    do: Native.positions_page(candidate, cursor, limit)

  def positions_page(_candidate, _cursor, _limit), do: {:error, :invalid_page}

  def relations_page(candidate, cursor, limit \\ 500)

  def relations_page(candidate, cursor, limit) when valid_page(cursor, limit),
    do: Native.relations_page(candidate, cursor, limit)

  def relations_page(_candidate, _cursor, _limit), do: {:error, :invalid_page}

  def delta_page(candidate, operation, cursor, limit \\ 500)

  def delta_page(candidate, operation, cursor, limit) when operation in @operations and valid_page(cursor, limit),
    do: Native.delta_page(candidate, operation, cursor, limit)

  def delta_page(_candidate, _operation, _cursor, _limit), do: {:error, :invalid_page}
end

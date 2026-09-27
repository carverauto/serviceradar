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

  Process-wide native admission returns `{:error, :busy}` without consuming
  builders or graph snapshots. Capacity remains occupied until native work
  returns, even if its BEAM caller terminates; callers should retry with backoff.
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
             is_integer(nodes) and nodes in 9..128 and is_integer(edges) and edges in 72..256 do
    case Map.get(budget, :profile, :standard) do
      profile when profile in [:standard, :aggregate_only] ->
        Native.tile(world, z, x, y, Map.put(budget, :profile, profile))

      _ ->
        {:error, :invalid_tile}
    end
  end

  def tile(_world, _z, _x, _y, _budget), do: {:error, :invalid_tile}

  def search(world, id) when is_binary(id), do: Native.search(world, id)
  def search(_world, _id), do: {:error, :invalid_identity}

  @doc "Select exact members of an aggregate from a server-owned tile descriptor."
  def aggregate_selection(world, selection, glyph_id) when is_binary(glyph_id),
    do: Native.aggregate_selection(world, selection, glyph_id)

  def aggregate_selection(_world, _selection, _glyph_id), do: {:error, :invalid_identity}

  @doc "Returns the exact member count and retained bytes without retaining or reading a world."
  def aggregate_info(aggregate), do: Native.aggregate_info(aggregate)

  @doc "Reads one canonical binding and its source/target positions in order, including both copies for a self-link."
  def relation(world, id) when is_binary(id) and byte_size(id) > 0, do: Native.relation(world, id)
  def relation(_world, _id), do: {:error, :invalid_identity}

  @doc "Read a bounded neighborhood or member page; cursors are tied to its immutable native source."
  def detail(world, scope, cursor \\ nil), do: Native.detail(world, scope, cursor)

  @doc "Reads a rendered edge's exact relation count and endpoint glyphs from the accepted tile selection."
  def bundle_info(world, selection, id) when is_binary(id) and byte_size(id) > 0,
    do: Native.bundle_info(world, selection, id)

  def bundle_info(_world, _selection, _id), do: {:error, :invalid_identity}

  @doc """
  Reads one exact rendered bundle in at most 4096 spatial candidates, returning
  at most 128 distinct devices and 256 relations. Cursors pin the native world,
  tile/profile and rendered bundle; the serving layer also pins publication.
  Empty pages may have an advancing cursor. Total relations are exact; a total
  distinct device count is deliberately absent because it would require a scan.
  """
  def bundle_detail(world, selection, id, cursor \\ nil)

  def bundle_detail(world, selection, id, cursor) when is_binary(id) and byte_size(id) > 0,
    do: Native.bundle_detail(world, selection, id, cursor)

  def bundle_detail(_world, _selection, _id, _cursor), do: {:error, :invalid_identity}

  @doc """
  Reads at most 256 canonical bindings with explicit total rendered coverage.
  Interface degrees count distinct active world relations across all pages and
  evidence classes; missing interface indices have degree zero.
  """
  def tile_relations(world, selection, cursor \\ nil, limit \\ 256)

  def tile_relations(world, selection, cursor, limit) when is_integer(limit) and limit in 1..256,
    do: Native.tile_relations(world, selection, cursor, limit)

  def tile_relations(_world, _selection, _cursor, _limit), do: {:error, :invalid_page}

  @doc "Create separate last-observed availability state; epochs are emitted as opaque hex identities."
  def new_health(world, epoch) when is_integer(epoch) and epoch in 1..0xFFFFFFFFFFFFFFFF,
    do: Native.new_health(world, epoch)

  def new_health(_world, _epoch), do: {:error, :invalid_epoch}

  def rebase_health(old_world, old_health, new_world, epoch) when is_integer(epoch) and epoch in 1..0xFFFFFFFFFFFFFFFF,
    do: Native.rebase_health(old_world, old_health, new_world, epoch)

  def rebase_health(_old_world, _old_health, _new_world, _epoch), do: {:error, :invalid_epoch}

  def device_ids_page(world, cursor \\ nil, limit \\ 500)

  def device_ids_page(world, cursor, limit) when is_integer(limit) and limit in 1..500,
    do: Native.device_ids_page(world, cursor, limit)

  def device_ids_page(_world, _cursor, _limit), do: {:error, :invalid_page}

  def apply_health(world, health, sequence, rows)
      when is_integer(sequence) and sequence in 1..0xFFFFFFFFFFFFFFFF and is_list(rows),
      do: Native.apply_health(world, health, sequence, rows)

  def apply_health(_world, _health, _sequence, _rows), do: {:error, :invalid_request}

  defdelegate tile_health(world, health, selection), to: Native
  defdelegate health_info(world, health), to: Native

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
